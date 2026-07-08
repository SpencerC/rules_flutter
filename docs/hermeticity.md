# Hermeticity contract

This document states exactly which parts of a `rules_flutter` build are
hermetic, which parts are declared non-hermetic, and why. Everything below is
grounded in the rule implementations (`flutter/repositories.bzl`,
`flutter/extensions.bzl`, `flutter/private/flutter_actions.bzl`,
`flutter/defs.bzl`) and enforced by the e2e test suite.

"Hermetic" here means: the action's behavior is a pure function of its declared
Bazel inputs — no network access, no reads from undeclared host state, and no
writes to shared state (in particular, never to the external SDK repository).

## What is fully hermetic

### SDK provisioning

The Flutter SDK is provisioned once, at repository fetch time, and is immutable
afterwards:

- **Pinned and verified.** `flutter.toolchain(flutter_version = "...")`
  downloads the official release archive with Bazel's integrity checking
  against the hashes recorded in `flutter/private/versions.bzl`.
- **Fetch-time launcher patch.** Stock Flutter's launcher rewrites
  `bin/cache/engine.stamp` and `bin/cache/engine.realm` on *every* invocation.
  At fetch time, `rules_flutter` patches
  `bin/internal/update_engine_version.sh` so those files are only written when
  their content is actually wrong — which never happens for a sealed,
  version-pinned SDK. If a Flutter release changes this script's content so
  the patch no longer applies, the fetch fails loudly rather than shipping a
  mutating launcher. (If a release removes the script entirely, the patch is
  skipped; the sealed cache below still catches any resulting write at build
  time.)
- **Optional precache, also at fetch time.** `precache = ["web", "android",
  ...]` verifies sentinel paths under `bin/cache` and, only when an artifact
  group is genuinely missing from the archive, runs `flutter precache` during
  the repository fetch (where network access is normal for Bazel). SDK
  repositories for platforms other than the host skip the precache step and
  print a warning instead; builds needing those artifacts fail later. One
  caveat: precached artifacts are engine-revision-pinned but not
  integrity-checked the way the archive itself is.
- **Sealed read-only.** As the last step of the fetch, `bin/cache` is made
  read-only (`chmod -R a-w`), so any residual write attempt fails the build
  loudly instead of silently mutating shared state. (The chmod-based seal is
  skipped on Windows hosts.)
- **Actions never need to write there.** The `flutter` build and test
  invocations export `FLUTTER_ALREADY_LOCKED=true` (skips the
  `bin/cache/lockfile` file-lock), pass `--no-version-check` and
  `--suppress-analytics`, set `FLUTTER_SUPPRESS_ANALYTICS=true` and `CI=true`,
  and run with a scratch `HOME` (`mktemp -d`; tests use
  `$TEST_TMPDIR/flutter_home`) so Flutter's config and analytics writes land
  in action-local scratch space, never in the SDK repository or your real
  home directory. Other actions and the developer-loop run helpers rely on
  the fetch-time launcher patch plus the sealed (read-only) cache instead:
  any residual write attempt fails loudly, which is the enforced backstop.

### Pub dependencies: no network at build time

Hosted packages are fetched as individual Bazel repositories by the `pub`
module extension, which scans every `pub_deps.json` in the root module. Network
access happens only at repository fetch time. At build time, the
`FlutterPrepareDeps` action assembles a per-target pub cache purely by copying:
it merges the pub caches propagated by dependency targets into a fresh
`hosted/pub.dev/<name>-<version>` layout. It then writes
`.dart_tool/package_config.json` directly from the declared `pub_deps.json`
metadata and synthesizes a `pubspec.lock` when the package does not ship one.
Downstream build and test actions regenerate `package_config.json` (plus the
`package_graph.json` newer flutter_tools require) from the same metadata with
sandbox-correct paths. No `pub get` runs and no resolver touches the network
anywhere on this path.

`pub_deps.json` is maintained by the generated run helper — `bazel run
//your/pkg:app_lib.update`, then `bazel mod tidy` — which is the *only* place
networked dependency resolution happens. (Mobile builds later re-run an
offline solve against the assembled cache — see the table below — but never
touch the network for pub.)

### Code generation

Both one-shot `generator_commands` and action-backed `build_runner build`
(`build_runner_modes = ["build"]`) run inside the hermetic
`FlutterPrepareDeps` action. The generator's entrypoint
(`bin/<executable>.dart`) is resolved from `package_config.json` and invoked as
`dart --packages=... <entrypoint>` deliberately instead of `dart run`: `dart
run` first checks that the package resolution is up to date and would attempt
an implicit — networked — `pub get`, which must never happen inside a build
action. `--delete-conflicting-outputs` is appended to `build_runner build` by
default.

`dart_proto_library` is hermetic for the same reason: the protoc plugin
executes out of its own pub repository, whose fetch vendored the exact
dependency closure pinned by its `pub_deps.json`, with a package config
generated at runtime from that metadata.

### Web builds

`{name}.web` runs `flutter build web --no-pub` under Bazel's default
sandboxing with no special execution requirements. Inside the action,
`package_config.json` is regenerated from `pub_deps.json` with sandbox-correct
paths — again without invoking pub — and the sealed SDK plus the assembled pub
cache are the only toolchain state the build sees. The action performs no
network access — by construction (no step on this path is networked) rather
than enforced by a network-blocking execution requirement.

### Tests, analysis, and formatting

`flutter_test` and `flutter_analyze_test` run from a prepared workspace;
`dart_format_test` does not need one:

- For the first two, the prepared workspace, pub cache, and `.dart_tool` tree
  are copied into `$TEST_TMPDIR`, `package_config.json` is regenerated from
  `pub_deps.json`, and `HOME` is set to `$TEST_TMPDIR/flutter_home`.
  `ANDROID_HOME` / `ANDROID_SDK_ROOT` are explicitly cleared.
- `flutter_test` runs `flutter test --no-pub`; `flutter_analyze_test` runs
  `flutter analyze --no-pub`.
- `dart_format_test` runs the SDK's `dart format --output=none
  --set-exit-if-changed` directly against the runfiles copies of your sources.

None of these paths perform pub resolution or network access.

## The engine-framework exception

Sealing leaves exactly one carve-out: directories matching
`bin/cache/artifacts/engine/ios*` and `bin/cache/artifacts/engine/darwin*`
keep owner-write permission.

The reason is mechanical, not a hole in the guarantee: `flutter build ios`
copies the engine frameworks into the app's build directory with permissions
preserved, then codesigns *the copies* in place. If the source frameworks were
read-only, the permissions-preserved copies would be read-only too, and
codesigning them would fail. The Flutter tool never writes those framework
files in place inside the SDK — it only needs the copies to be writable — so
the no-mutation guarantee is unaffected. The rest of `bin/cache`, including
`lockfile` and the engine stamps, remains read-only, and the sealed-cache e2e
test (below) probes exactly that.

## Declared non-hermeticity, per target

Android and iOS builds are **declared non-hermetic** and carry explicit
execution requirements so Bazel schedules them accordingly. The exact tags set
in `flutter_actions.bzl`:

- `FlutterBuildAndroid` (apk/appbundle): `no-remote-exec`, `no-sandbox`,
  `requires-network`, plus `use_default_shell_env = True`.
- `FlutterBuildIos`: `no-remote-exec`, `no-sandbox`, `requires-darwin`,
  `requires-network`, plus `use_default_shell_env = True`.
- Everything else (`FlutterBuild` for web and desktop targets,
  `FlutterPrepareDeps`, `SetupFlutterWorkspace`, tests): no special execution
  requirements; they run under Bazel's default sandboxing.

| Target | What's hermetic | What's not | Why |
| --- | --- | --- | --- |
| `{name}.web` | Everything: sealed SDK, assembled pub cache, `--no-pub` build, package config regenerated in-action. | Nothing declared. | No host tools or network are needed for web output. |
| `{name}.apk` / `{name}.appbundle` | The Flutter SDK, all Dart dependencies (the plugin-registrant regeneration runs `flutter pub get --offline` against a *mutable copy* of the assembled cache — pub writes bookkeeping such as `active_roots` into `PUB_CACHE`, so the read-only input is copied first; still no network for pub), `dart_defines`/`build_args`, `JAVA_HOME` from Bazel's java runtime toolchain. | Gradle downloads its distribution and Maven dependencies (`requires-network`); the Android SDK is the host installation consumed through rules_android's `@androidsdk//:sdk_path` (discovered via `ANDROID_HOME`); the action runs `no-sandbox`, `no-remote-exec`, with the client shell environment. | rules_android wraps the host SDK in a symlink tree that omits directories AGP 8 needs (`ndk/<version>`, `licenses/`), so the action resolves the *real* host SDK behind the wrapper — a tree that cannot be staged into a sandbox. Gradle has no offline story for a cold `GRADLE_USER_HOME`. |
| `{name}.ios` | The Flutter SDK, all Dart dependencies (same offline `pub get` against a mutable cache copy), `dart_defines`/`build_args`. | Host Xcode (`xcodebuild`) and CocoaPods are declared prerequisites; `pod install` (driven by the Flutter tool) fetches pod specs and binary pods over the network; the action runs `requires-darwin`, `no-sandbox`, `no-remote-exec`, with the client shell environment. Under `--incompatible_strict_action_env` the action probes common CocoaPods install locations (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.gem/bin`, ruby gem bindirs) before failing. | Relying on host Xcode is standard practice for Bazel Apple builds; CocoaPods manages its own spec repo and caches under `HOME`. |
| `flutter_test` / `flutter_analyze_test` / `dart_format_test` | Everything: the first two copy the prepared workspace and pub cache into `$TEST_TMPDIR` with a scratch `HOME` and `--no-pub`; `dart_format_test` runs `dart format` directly over the runfiles copies of its `srcs`. No network in any of them. | Nothing declared. | Tests only consume already-prepared inputs. |
| `{name}.dev`, `{name}.update`, `build_runner` run helpers | The Flutter SDK they invoke (sealed and pinned; the `flutter`-driven `.dev`/`.update` helpers additionally set `FLUTTER_ALREADY_LOCKED` + `--no-version-check`, while the build_runner helpers invoke `dart` directly and rely on the seal). | These are `bazel run` helpers that operate on your **source** workspace by design: the dev server serves your live sources, and `.update` re-resolves dependencies (the whole point). `.update` works in a temporary copy of the workspace and writes back only `pub_deps.json`. | Developer-loop tooling, intentionally outside the build graph. |

Desktop targets (`macos`, `linux`, `windows`) run with the default sandboxed
configuration and no declared exceptions, but they depend on host platform
toolchains that Flutter discovers itself; they are not yet part of the
verified contract above.

## Cache opt-ins

The non-hermetic actions can reuse persistent host caches so warm builds skip
the network. Each opt-in is an environment variable. The mobile actions run
with the default shell environment, so without
`--incompatible_strict_action_env` a variable exported in your shell reaches
them directly; forwarding it with `--action_env=VAR` is the explicit,
recommended wiring, and is required once `--incompatible_strict_action_env`
is enabled.

### Android: persistent Gradle home

By default `GRADLE_USER_HOME` points into action-local scratch space, so every
cold build re-downloads the Gradle distribution and Maven dependencies. Opt
into persistence in `.bazelrc`:

```
build --action_env=RULES_FLUTTER_GRADLE_USER_HOME=/home/me/.cache/rules_flutter_gradle
build --sandbox_writable_path=/home/me/.cache/rules_flutter_gradle
```

The Android action itself runs `no-sandbox`, so the `--sandbox_writable_path`
line is there to keep the directory usable if you tighten sandboxing later; it
is harmless otherwise. Gradle daemons are disabled inside the action
(`-Dorg.gradle.daemon=false`).

### iOS: persistent CocoaPods caches

`flutter build ios` keeps the caller's `HOME` when the build passes it
through, so CocoaPods' spec repo and pod caches persist across builds:

```
build --action_env=HOME
```

Under `--incompatible_strict_action_env`, `HOME` is absent from the action
environment; the action then falls back to a scratch `HOME` rather than
aborting (correct, but every build re-fetches pod specs). To relocate
CocoaPods' home directory explicitly, set `CP_HOME_DIR` via the dedicated
variable:

```
build --action_env=RULES_FLUTTER_CP_HOME=/home/me/.cache/rules_flutter_cocoapods
```

The action creates the directory and exports it as `CP_HOME_DIR` before the
Flutter tool drives `pod install`.

### build_runner: persistent incremental state

The dependency-preparation action runs `build_runner build` from a fresh
workspace each time, so by default every source edit re-runs codegen cold.
Point `//flutter:build_runner_cache` at an absolute directory to persist
build_runner's incremental `.dart_tool/build` state across builds:

```
build --//flutter:build_runner_cache=/home/me/.cache/rules_flutter_build_runner
build --sandbox_writable_path=/home/me/.cache/rules_flutter_build_runner
```

The action restores the cache before build_runner and saves it after, keyed
by target label + Flutter version + `pub_deps.json` digest, under a portable
lock. Every step is best-effort: an unwritable cache directory, a lost lock,
or a failed copy all degrade to a cold build_runner run (a failed copy
removes its partial destination, so a torn tree is never reused), and
correctness then rests on build_runner's own content-digest invalidation —
the same mechanism `build_runner watch` relies on. Measured on a large app, a
single-file edit's preparation action dropped from ~68s to ~55s, and the
saving grows the more codegen a change would otherwise redo.

Unlike the hermetic default, this opt-in makes the preparation action inherit
the client shell environment (so the cache directory is reachable), a
documented, opt-in reduction in hermeticity of the same kind as the
Gradle/CocoaPods caches above. Leave the flag empty (the default) for fully
hermetic, byte-identical builds.

## Remote execution

Hermetic is not the same as remote-executor-friendly. The dependency
preparation/codegen action and the web/desktop `flutter build` actions run
multi-process Dart tooling that needs several CPUs and real memory; on
default-size remote executors they can be dramatically slower than on the
local machine (a preparation step that takes about a minute on an 8-CPU
worker has been observed taking 50+ minutes remotely).

The rules therefore default these actions — and the `flutter_test` /
`flutter_analyze_test` / `dart_format_test` runners — to
**local execution with remote caching**: they carry `no-remote-exec`, so
their results still populate and hit your remote cache, but the work happens
on the machine running Bazel. Android and iOS builds are additionally
`no-sandbox`/`requires-network` (see the per-target table above) and are not
affected by this section.

On a well-resourced RBE fleet you can opt back into remote execution:

```
build --//flutter:allow_remote_execution
```

Executor sizing is intentionally left to you: pass your vendor's sizing
through target-level `exec_properties` or platform properties (for example
BuildBuddy's `EstimatedCPU`/`EstimatedMemory`). Locally, the actions declare
a `resource_set` of several CPUs so Bazel's scheduler does not oversubscribe
the machine.

## CI caching: making no-change runs near-instant

The prepare/assemble/codegen actions and the test rules are deterministic and
remote-cacheable by default, so a rebuild with no source changes is all cache
hits (seconds), not a re-run. Getting that on CI depends on the *consumer's*
configuration:

- **Persist a cache across runs.** The heavy work (SDK provisioning, pub-cache
  assembly, codegen) is cacheable, but a repository fetch is not an action — a
  fresh/ephemeral runner re-downloads and re-extracts the SDK and re-resolves
  every pub repository unless you persist a `--repository_cache` on a durable
  volume (or bake the pinned SDK + assembled pub cache into a warm runner image).
  Pair it with a remote cache (`--remote_cache` + `--remote_upload_local_results`)
  so the locally-executed `no-remote-exec` action results populate it.
- **Do not put volatile values in the action environment.** `--action_env=HOME`
  (or any volatile `--action_env`/`--repo_env`) becomes part of *every* action's
  cache key, so runners (or a developer vs. CI) with a different `HOME` cannot
  share cache entries — verified: changing `HOME` re-runs the prepared-workspace
  actions. The hermetic actions set their own scratch `HOME`, so they do not need
  it; scope `--action_env=HOME` to the iOS config that actually wants it (for
  CocoaPods cache persistence) rather than applying it globally.
- **Keep regeneration off the verify path.** If a "lint" job regenerates sources
  in place (protobufs, `build_runner`/`intl_utils` output, formatting, goldens)
  and commits them, run that as a *separate* step from `bazel test`: those
  writes mutate the package sources, which invalidates the prepared-workspace
  cache and forces a full codegen + test re-run even when nothing else changed.
  A pure `bazel test` verify step stays cache-hittable; the hermetic build does
  its own codegen, so it does not need the in-tree regenerated copies.

## Troubleshooting

### Seeing what an action actually ran

Bazel hides action output on success. To diagnose a failing or suspicious
Flutter action:

- `--verbose_failures` prints the full failing command line and its stderr.
- `--subcommands` (or `-s`) prints every command Bazel runs, including the
  generated action script.
- `--sandbox_debug` leaves the sandbox tree in place and prints its path so you
  can inspect the exact inputs the action saw.

The dependency-preparation/codegen action tees its `flutter pub get` and
generator output to a `<target>_pub_prepare.log` file next to the target's
other outputs under `bazel-bin/`, so after a build you can read, e.g.,
`bazel-bin/my_app/lib_pub_prepare.log` to see what pub resolution and code
generation printed.

### Common failures

- **"no Flutter toolchain is registered"** — no toolchain was resolved. Add the
  `flutter` extension and `register_toolchains("@flutter_toolchains//:all")`
  (see the README "Register a Flutter toolchain" section).
- **"Flutter `<v>` is not in the built-in version table"** — the pinned
  `flutter_version` is not in `versions.bzl`. Run
  `bazel run //tools:update_flutter_versions`, or supply an `integrity` map for
  the version (README "Using a version not in the built-in table").
- **SDK download integrity mismatch** — the pinned version's recorded hash does
  not match the fetched archive (a stale table entry, a version that was never
  published for that platform, or a wrong hand-supplied `integrity`). Confirm
  the archive exists at the printed URL and regenerate/verify its hash.
- **A `pub_deps.json` is stale or a hosted package is missing** — after editing
  a `pubspec.yaml`, run `bazel run //my_app:lib.update` to refresh the pinned
  dependency report, then `bazel mod tidy` to rescan and update `use_repo`.
- **A write into `bin/cache` failed the build** — something invoked
  `flutter precache`/`flutter config` (or otherwise wrote into the SDK). The
  cache is sealed read-only on purpose; remove that step (see "The guarantee").
- **An action is dramatically slower on a remote executor** (minutes → tens of
  minutes) — the heavy Flutter actions default to local execution with remote
  caching. This is expected; see the "Remote execution" section to opt back in
  on a well-resourced fleet.
- **Embedding a generated pub-package target fails at analysis** — targets
  generated with `assemble_dep_caches = False` carry only their own payload and
  cannot be embedded; embed a `flutter_library`/`dart_library` that assembles
  its full cache (the default) instead.
- **`build_runner` output looks stale with the incremental cache enabled** —
  the opt-in cache (`RULES_FLUTTER_BUILD_RUNNER_CACHE`) is keyed by label + SDK
  version + `pub_deps` digest and degrades to a clean rebuild on mismatch, so a
  stale result is unexpected; clear the cache directory to force a rebuild and
  file an issue.

## The guarantee

**No build action and no run helper writes to the external Flutter SDK
repository.** The launcher is patched at fetch time, the `flutter` build and
test invocations run with `FLUTTER_ALREADY_LOCKED` and `--no-version-check`
under a scratch or test-local `HOME`, and `bin/cache` is sealed read-only —
so even on the paths that skip some of those measures (direct `dart`
invocations, developer-loop helpers running under your real `HOME`), a
violation cannot be silent: any residual write attempt fails the offending
action.

This is enforced continuously by the e2e workspace:
`e2e/smoke/sdk_cache_sealed_test.sh` (target
`//:sdk_cache_sealed_test` in `e2e/smoke`) resolves the real SDK path behind
the runfiles symlinks, attempts to create a file inside `bin/cache`, and
asserts both that the write fails and that `bin/cache/lockfile` is not
writable. Do not run `flutter precache` or `flutter config` against the
Bazel-provided SDK from your own scripts: it is unnecessary, and the sealed
cache will reject it.
