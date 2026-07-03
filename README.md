# Bazel rules for Flutter

Build Flutter applications with Bazel. `rules_flutter` supplies hermetic Flutter
toolchains, module extensions for pub.dev dependencies, protobuf-to-Dart
generation, `build_runner` integration, Gazelle language support, and packaging
for web and mobile so teams can ship Flutter code from CI with confidence.

> **Development status:** These rules are evolving quickly. Expect some sharp
> edges while the APIs stabilize.

- [Installation](#installation)
- [Managing pub.dev dependencies](#managing-pubdev-dependencies)
- [Defining libraries: flutter_library](#defining-libraries-flutter_library)
- [Code generation](#code-generation)
- [Protobuf: dart_proto_library](#protobuf-dart_proto_library)
- [Building apps: flutter_app](#building-apps-flutter_app)
- [Mobile builds](#mobile-builds)
- [Testing](#testing)
- [Gazelle automation](#gazelle-automation)
- [Documentation and examples](#documentation-and-examples)

The external workspace under [`e2e/smoke`](e2e/smoke) is the canonical,
CI-tested reference for everything below: a Flutter web app with localization
codegen and protos ([`flutter_app/`](e2e/smoke/flutter_app)), a `build_runner`
app ([`codegen_app/`](e2e/smoke/codegen_app)), proto packages
([`protos/`](e2e/smoke/protos), [`proto_service/`](e2e/smoke/proto_service)),
and a plain Dart package ([`dart_package/`](e2e/smoke/dart_package)).

## Installation

`rules_flutter` uses bzlmod and requires Bazel 7.1 or newer (the repo is
tested with Bazel 8). Until a release lands in the Bazel Central Registry,
depend on it with a `git_override` in your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_flutter", version = "0.0.0")
git_override(
    module_name = "rules_flutter",
    remote = "https://github.com/SpencerC/rules_flutter.git",
    commit = "<pin a commit from main>",
)
```

The examples later in this README also assume `bazel_dep` entries for
`protobuf`, `bazel_skylib`, and `rules_multirun` where those repositories
appear (and the Gazelle section additionally needs `gazelle` and
`bazel_skylib_gazelle_plugin`). See
[`e2e/smoke/MODULE.bazel`](e2e/smoke/MODULE.bazel) for a complete working
example.

### Register a Flutter toolchain

The `flutter` extension downloads a platform-appropriate SDK and registers
toolchains, so no host Flutter install is needed:

```starlark
flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(
    flutter_version = "3.38.4",
    # Artifact groups that must be present in the SDK cache after fetch.
    # Stable archives already ship web, Android, and the host desktop
    # platform (plus iOS on macOS); anything missing is fetched via
    # `flutter precache` at repository fetch time.
    precache = ["web", "android", "ios"],
)
use_repo(
    flutter,
    "flutter_sdk",
    "flutter_toolchains",
)
register_toolchains("@flutter_toolchains//:all")
```

#### SDK hermeticity guarantees

The SDK repository is immutable after fetch:

- The release archive is downloaded with integrity verification, and the
  launcher's engine-version refresh is patched at fetch time so `flutter`
  invocations never write into the repository.
- `bin/cache` is sealed read-only; any residual write attempt fails the build
  loudly instead of silently mutating shared state. (The one exception: the
  iOS/macOS engine framework directories keep owner-write, because
  `flutter build ios` copies them permissions-preserved into the app's build
  directory and codesigns the copies in place — the tool never writes the
  originals.)
- Build actions run with `FLUTTER_ALREADY_LOCKED`, `--no-version-check`, and a
  scratch `HOME`, so no lockfiles, stamps, or analytics/config writes escape
  the sandbox.

Do not run `flutter precache` or `flutter config` against the Bazel-provided
SDK from scripts: it is unnecessary and the sealed cache will reject it. See
[docs/hermeticity.md](docs/hermeticity.md) for the full per-platform contract.

## Managing pub.dev dependencies

`rules_flutter` ships a `pub` module extension that scans every checked-in
`pub_deps.json` in the root module and creates one Bazel repository per hosted
package. Add it next to the Flutter extension:

```starlark
pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")

# Repositories follow the pub_<package> naming convention; each exposes a
# target named after the package (e.g. @pub_fixnum//:fixnum).
use_repo(pub, "pub_fixnum", "pub_intl_utils", "pub_protobuf")
```

Each Flutter/Dart package in your workspace keeps a `pub_deps.json` (the pinned
dependency report from `flutter pub deps --json`) next to its `pubspec.yaml`.
The `flutter_library` and `dart_library` macros emit a runnable `{name}.update`
helper that regenerates it (`dart_library` only when a `pubspec` is set), so
the maintenance loop when dependencies change is:

```bash
# 1. Edit pubspec.yaml.
# 2. Refresh the pinned dependency report (also creates it the first time):
bazel run //my_app:lib.update
# 3. Let the pub extension rescan pub_deps.json files and update use_repo:
bazel mod tidy
# 4. Commit pubspec.yaml, pub_deps.json, and MODULE.bazel together.
```

Optional `pub.package` tags pin versions or add packages that no
`pub_deps.json` references:

```starlark
pub.package(name = "pub_freezed", package = "freezed", version = "2.4.5")
```

Root-module registrations take precedence: if a dependency ruleset pins a
package version that conflicts with your `pub_deps.json`, the root module's pin
wins. The extension also prunes genuine dependency cycles in the pub universe
(e.g. `dio <-> dio_web_adapter`) so the generated target graph stays a DAG.

## Defining libraries: flutter_library

`flutter_library` prepares a Flutter package for hermetic builds and tests: it
assembles the package workspace, an offline pub cache, and package metadata
that `flutter_app`, `flutter_test`, and `flutter_analyze_test` reuse via
`embed`. Adapted (abridged) from
[`e2e/smoke/flutter_app/BUILD.bazel`](e2e/smoke/flutter_app/BUILD.bazel):

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "lib",
    srcs = ["lib/main.dart"],
    data = glob(["l10n/**"]),                     # assets/l10n inputs for codegen
    pubspec = "pubspec.yaml",
    # pub_deps defaults to the sibling "pub_deps.json".
    generator_commands = ["intl_utils:generate"],  # one-shot codegen (see below)
    generated_srcs = {
        # dart_proto_library outputs mounted under lib/generated (see below).
        "//protos/api/v1:services_api_v1_proto_dart": "lib/generated",
    },
    deps = [
        "@flutter_sdk//flutter/packages/flutter",
        "@flutter_sdk//flutter/packages/flutter_localizations",
        "@flutter_sdk//flutter/packages/flutter_test",
        "@pub_intl_utils//:intl_utils",
        "@pub_protobuf//:protobuf",
    ],
)
```

- **`srcs`** are the package sources (`lib/`, etc.); **`data`** carries
  additional files (assets, l10n ARB files) needed for code generation or
  embedding.
- **`pubspec`** is required; **`pub_deps`** defaults to `pub_deps.json` in the
  same package and must be checked in (see the dependency loop above).
- **`deps`** accepts other `flutter_library`/`dart_library` targets, pub
  repositories (`@pub_*//:*`), and the SDK-vendored packages under
  `@flutter_sdk//flutter/packages/...`.
- The macro also emits the `{name}.update` helper described above
  (`create_update_target = False` opts out).

Plain Dart packages use `dart_library` the same way; `pubspec`/`pub_deps` are
optional there (see [`e2e/smoke/dart_package`](e2e/smoke/dart_package)).

## Code generation

### One-shot generators

`generator_commands` runs each `<package>:<script>` generator while the
library's dependencies are prepared (the entrypoint is resolved from the
package config and invoked directly rather than via `dart run`, which would
attempt an implicit `pub get`), so generated sources exist inside the
Bazel-prepared workspace without being checked in. For example,
`generator_commands = ["intl_utils:generate"]` produces the localization
bindings for the smoke app.

### build_runner

`flutter_library` and `dart_library` have first-class `build_runner` support:

- `build_runner_modes = ["build"]` runs `build_runner build` **inside the
  Bazel action**, fully offline: the entrypoint is resolved from the prepared
  package config (no implicit `pub get`), a `pubspec.lock` is synthesized from
  `pub_deps.json` for the package graph when the package does not ship one,
  and `--delete-conflicting-outputs` is applied by default. Generated sources
  (e.g. `*.g.dart`, `assets.gen.dart`)
  therefore never need to be checked in — see
  [`e2e/smoke/codegen_app`](e2e/smoke/codegen_app) for a working example
  combining `copy_with_extension_gen` and `flutter_gen_runner`.
- Omitting `build_runner_modes` emits runnable helper targets for all modes:
  `:<name>.build_runner_build`, `:<name>.build_runner_test`,
  `:<name>.build_runner_watch`, and `:<name>.build_runner_serve`. Setting
  `build_runner_modes` narrows both the emitted helpers and the action-backed
  behavior.
- `build_runner_common_args` applies to every mode;
  `build_runner_build_args`/`build_runner_test_args`/`build_runner_watch_args`/
  `build_runner_serve_args` are per-mode. `build_runner_create_run_targets =
False` suppresses the helpers.

```starlark
flutter_library(
    name = "lib",
    srcs = glob(["lib/**"]),
    build_runner_modes = ["build"],
    data = glob(["assets/**"]),
    pubspec = "pubspec.yaml",
    deps = [
        "@flutter_sdk//flutter/packages/flutter",
        "@pub_build_runner//:build_runner",
        "@pub_copy_with_extension//:copy_with_extension",
        "@pub_copy_with_extension_gen//:copy_with_extension_gen",
        "@pub_flutter_gen_runner//:flutter_gen_runner",
    ],
)
```

The helper targets are normal executables, so they compose directly with
`rules_multirun`:

```starlark
load("@rules_multirun//:defs.bzl", "command", "multirun")

command(
    name = "app_watch",
    command = "//flutter_app:lib.build_runner_watch",
)

command(
    name = "app_serve",
    command = "//flutter_app:lib.build_runner_serve",
)

multirun(
    name = "app_dev",
    commands = [
        ":app_watch",
        ":app_serve",
    ],
    jobs = 0,
)
```

### Mounting generated sources: generated_srcs

Generated Dart produced by _other Bazel targets_ — most commonly
`dart_proto_library` output — is mounted at an explicit directory inside the
package workspace with `generated_srcs`, so imports resolve during codegen,
builds, and tests without checking generated files in:

```starlark
flutter_library(
    name = "app_lib",
    srcs = glob(["lib/**"], exclude = ["lib/generated/**"]),
    generated_srcs = {
        "//protos/api/v1:services_api_v1_proto_dart": "lib/generated",
    },
    pubspec = "pubspec.yaml",
    deps = ["@pub_protobuf//:protobuf"],
)
```

`dart_proto_library` targets mount each file at its proto-import-relative path
under the destination directory (so `api/v1/service.proto` becomes
`lib/generated/api/v1/service.pb.dart`, imported as
`package:my_app/generated/api/v1/service.pb.dart`); other targets mount flat by
basename.

## Protobuf: dart_proto_library

`dart_proto_library` wraps the Dart protoc plugin (run from its own pinned pub
repository) behind an aspect that walks the `proto_library` dependency
closure: generation covers every proto in the transitive closure, including
well-known types such as `google/protobuf/timestamp`, matching what generated
imports expect. gRPC stubs are always generated for protos that declare
services (the `grpc` attribute is deprecated and ignored).

The convention — like `go_proto_library` — is one collocated
`dart_proto_library` per `proto_library`, in the same package:

```starlark
# protos/api/v1/BUILD.bazel
load("@protobuf//bazel:proto_library.bzl", "proto_library")
load("@rules_flutter//flutter:defs.bzl", "dart_proto_library")

proto_library(
    name = "services_api_v1_proto",
    srcs = ["service.proto"],
    # Import path becomes api/v1/service.proto.
    strip_import_prefix = "/protos/",
    visibility = ["//visibility:public"],
    deps = ["@protobuf//:timestamp_proto"],
)

dart_proto_library(
    name = "services_api_v1_proto_dart",
    visibility = ["//visibility:public"],
    deps = [":services_api_v1_proto"],
)
```

There are two ways to consume the generated Dart:

```starlark
# 1. dart_library: depend on it directly; the generated sources join the
#    library's sources.
dart_library(
    name = "proto_client",
    srcs = ["lib/client.dart"],
    deps = ["//protos/api/v1:services_api_v1_proto_dart"],
)

# 2. flutter_library: mount it at a package path with generated_srcs so app
#    code imports package:my_app/generated/api/v1/service.pb.dart.
flutter_library(
    name = "lib",
    generated_srcs = {
        "//protos/api/v1:services_api_v1_proto_dart": "lib/generated",
    },
    ...
)
```

## Building apps: flutter_app

`flutter_app` is a macro that emits one target per configured platform —
`{name}.web`, `{name}.apk`, `{name}.appbundle`, `{name}.ios`, `{name}.macos`,
`{name}.linux`, `{name}.windows` — plus an alias `{name}` pointing at the first
configured platform in that fixed order (web, apk, appbundle, ios, macos,
linux, windows):

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_app")

flutter_app(
    name = "app",
    embed = [":lib"],
    web = {
        "srcs": glob(["web/**"]),
        "build_args": ["--source-maps"],
    },
)
```

```bash
bazel build //my_app:app.web        # build the web bundle
bazel run //my_app:app.web -- 9000  # serve the built bundle locally
```

### Platform dict specs

Each platform attribute accepts either overlay files (a label or list of
labels, treated as `srcs`) or a dict spec with any of these keys:

| Key            | Meaning                                                                                                                                                                    |
| :------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `srcs`         | Files overlaid into the build workspace for this platform (e.g. `web/`, `android/`, `ios/` directories).                                                                   |
| `dart_defines` | Dict of `--dart-define` key/value pairs, read in Dart via `String.fromEnvironment`.                                                                                        |
| `build_args`   | Extra arguments appended verbatim to `flutter build`.                                                                                                                      |
| `mode`         | Build mode: `release` (default), `profile`, or `debug`.                                                                                                                    |
| `env`          | Extra environment variables exported in the build action.                                                                                                                  |
| `android_sdk`  | Android SDK directory for `apk`/`appbundle`, typically rules_android's `@androidsdk//:sdk_path`.                                                                           |
| `android_ndk`  | Optional Android NDK directory.                                                                                                                                            |
| `android_test` | `apk` only: additionally build the instrumentation APK (see [Mobile builds](#mobile-builds)).                                                                              |
| `build_name`   | Overrides the pubspec version name (`--build-name`).                                                                                                                       |
| `build_number` | Label of a `string_flag`; its value (when non-empty) is passed as `--build-number`.                                                                                        |
| `tags`         | Extra tags for this platform's target, added to the macro-level `tags` (e.g. `["manual"]` to keep mobile targets out of wildcard builds on machines without the host SDK). |

`dart_defines`, `build_args`, `mode`, `env`, `android_sdk`, and `android_ndk`
can also be set at the macro level, shared by all platforms. Per-platform
values merge over the shared ones: `build_args` concatenates after the shared
list, dicts merge with platform keys winning, and `mode` overrides.

### Per-environment configuration

`dart_defines` and `mode` are configurable with `select()`, so a single
`string_flag` can key dev/staging/prod builds. One Starlark limitation to know
about: two `select()`s cannot be merged, so when using `select()` compose the
complete dict per branch (and put it on either the shared attribute or the
platform spec, not both).

```starlark
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

string_flag(
    name = "env",
    build_setting_default = "dev",
    values = ["dev", "staging", "prod"],
)

config_setting(
    name = "staging",
    flag_values = {":env": "staging"},
)

config_setting(
    name = "prod",
    flag_values = {":env": "prod"},
)

flutter_app(
    name = "app",
    embed = [":lib"],
    dart_defines = select({
        ":prod": {"API_ENDPOINT": "api.example.com", "ENV_NAME": "prod"},
        ":staging": {"API_ENDPOINT": "api.staging.example.com", "ENV_NAME": "staging"},
        "//conditions:default": {"API_ENDPOINT": "api.dev.example.com", "ENV_NAME": "dev"},
    }),
    mode = select({
        ":prod": "release",
        "//conditions:default": "debug",
    }),
    web = {"srcs": glob(["web/**"])},
)
```

```bash
bazel build //my_app:app.web --//my_app:env=prod
```

### Development server

Apps with a `web` platform also emit a `{name}.dev` helper that runs
`flutter run -d web-server` in your **source** workspace using the hermetic
SDK — hot reload included, no host Flutter install required. It inherits the
web platform's `dart_defines`, so per-environment config flows through:

```bash
bazel run //my_app:app.dev --//my_app:env=dev -- --web-port=8080
```

Opt out with `create_dev_target = False`; pass fixed args via
`dev_run_args = [...]`.

## Mobile builds

Web builds and tests are fully hermetic (package configs are regenerated from
`pub_deps.json` with no pub resolution and no network). Mobile builds are
different: they drive Gradle/Xcode, so the actions are **declared
non-hermetic** (`no-sandbox`, `requires-network`, `no-remote-exec`; mnemonics
`FlutterBuildAndroid` and `FlutterBuildIos`, the latter also
`requires-darwin`). Pub dependencies still never touch the network: mobile
targets run `flutter pub get --offline` against a mutable copy of the
assembled pub cache to regenerate Flutter's plugin registrants. See
[docs/hermeticity.md](docs/hermeticity.md) for the exact contract per target.

A runnable example lives at
[`e2e/smoke/flutter_app`](e2e/smoke/flutter_app/BUILD.bazel): the
`//flutter_app:mobile.apk` and `//flutter_app:mobile.ios` targets are tagged
`manual` (they need the host prerequisites below) and build a debug APK and an
unsigned `Runner.app` from the same `flutter_library` as the web app.

### Android (apk / appbundle)

`{name}.apk` and `{name}.appbundle` consume the Android SDK through
rules_android's `@androidsdk` repository, which wraps the host installation
discovered via `ANDROID_HOME`. `JAVA_HOME` comes from Bazel's hermetic java
runtime toolchain.

```starlark
# MODULE.bazel
bazel_dep(name = "rules_android", version = "0.6.6")

android_sdk_repo = use_extension("@rules_android//rules/android_sdk_repository:rule.bzl", "android_sdk_repository_extension")
use_repo(android_sdk_repo, "androidsdk")
```

```
# .bazelrc — pass discovery through to repository fetches
common --repo_env=ANDROID_HOME
```

```starlark
# BUILD.bazel
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

string_flag(
    name = "android_build_number",
    build_setting_default = "",
)

flutter_app(
    name = "app",
    embed = [":lib"],
    apk = {
        "srcs": glob(["android/**"]),
        "android_sdk": "@androidsdk//:sdk_path",
        "build_number": ":android_build_number",
        "android_test": True,
    },
    appbundle = {
        "srcs": glob(["android/**"]),
        "android_sdk": "@androidsdk//:sdk_path",
        "build_number": ":android_build_number",
    },
)
```

```bash
# Release wrappers inject the next Play Store version code:
bazel build //my_app:app.appbundle --//my_app:android_build_number=42
```

Notes:

- **NDK:** AGP 8 dropped `ndk.dir` support, so native code requires the NDK
  _inside_ the SDK at `ndk/<version>` (install it via `sdkmanager`). Do **not**
  `register_toolchains` from rules_android_ndk — that forces an `@androidndk`
  fetch for every build, including non-Android ones.
- **Gradle caching:** `GRADLE_USER_HOME` defaults to per-action scratch, so
  Gradle re-downloads its distribution and Maven dependencies on cold builds.
  Opt into a persistent cache so warm builds skip the downloads:

  ```
  build --action_env=RULES_FLUTTER_GRADLE_USER_HOME=/path/to/gradle-cache
  ```

- **Firebase Test Lab:** `android_test = True` (apk only) additionally runs
  Gradle's `app:assembleAndroidTest` after the Flutter build and copies the
  instrumentation APK under `androidTest/` in the build artifacts — the
  two-APK layout Firebase Test Lab's instrumentation testing expects.

### iOS

`{name}.ios` requires a host Xcode installation (`xcodebuild`) and CocoaPods —
the standard declared prerequisites for Bazel Apple builds; Flutter drives
`pod install` itself. Under `--incompatible_strict_action_env` the action
probes the common CocoaPods install locations (Homebrew, `/usr/local/bin`,
gem paths) before giving up.

```starlark
flutter_app(
    name = "app",
    embed = [":lib"],
    ios = {
        "srcs": glob(["ios/**"]),
        "mode": "release",
    },
)
```

Tips:

- The iOS action keeps the caller's `HOME` when the build passes it through,
  so CocoaPods spec/pod caches persist across builds; otherwise it falls back
  to a scratch dir. To opt in:

  ```
  build --action_env=HOME
  ```

- `RULES_FLUTTER_CP_HOME` (via `--action_env`) sets CocoaPods' `CP_HOME_DIR`
  explicitly.

## Testing

All three test rules run hermetically — no host Flutter, no network.
`flutter_test` and `flutter_analyze_test` run from the prepared
`flutter_library` workspace; `dart_format_test` simply runs the toolchain's
`dart format --output=none --set-exit-if-changed` over its `srcs`:

```starlark
load(
    "@rules_flutter//flutter:defs.bzl",
    "dart_format_test",
    "flutter_analyze_test",
    "flutter_test",
)

# flutter test --no-pub against the prepared workspace.
flutter_test(
    name = "lib_test",
    srcs = glob(["test/**"]),
    embed = [":lib"],
    # test_files = ["test/"],  # patterns forwarded to flutter test
)

# flutter analyze --no-pub; overlay analysis_options.yaml / test sources.
flutter_analyze_test(
    name = "lib_analyze",
    srcs = glob(["test/**"]),
    embed = [":lib"],
    # fatal_infos = True, fatal_warnings = False, extra_args = [...]
)

# Fails when sources are not `dart format` clean.
dart_format_test(
    name = "lib_format",
    srcs = glob(["lib/**/*.dart", "test/**/*.dart"]),
)
```

```bash
bazel test //my_app:all
```

## Gazelle automation

`rules_flutter` ships Gazelle plugins to keep BUILD files in sync with your
Flutter sources and proto schemas. Enable them by composing a custom binary:

```starlark
# BUILD.bazel
load("@bazel_gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = [
        "@bazel_skylib_gazelle_plugin//bzl",
        "@bazel_gazelle//language/proto",
        "@rules_flutter//gazelle/flutter",
        "@rules_flutter//gazelle/dartproto",
    ],
)

gazelle(
    name = "gazelle",
    gazelle = "gazelle_bin",
)
```

Run Gazelle whenever files move or dependencies change:

```bash
bazel run //:gazelle
```

## Documentation and examples

- [docs/rules.md](docs/rules.md) — generated API reference for every rule and
  attribute.
- [docs/hermeticity.md](docs/hermeticity.md) — the hermeticity contract: what
  is sealed, what is declared non-hermetic, and why.
- [docs/migrating.md](docs/migrating.md) — migrating an existing Flutter app
  to Bazel.
- [e2e/smoke](e2e/smoke) — the runnable example workspace exercised in CI
  (`cd e2e/smoke && bazel test //:integration_tests`).

## Working on rules_flutter

- **Run all tests:** `bazel test //...`
- **Core rule coverage:** `bazel test //flutter/tests:all_tests`
- **External smoke tests:** `cd e2e/smoke && bazel test //:integration_tests`
- **Regenerate BUILD files:** `bazel run //:gazelle` (and the smoke workspace equivalent)
- **Format BUILD/Starlark:** `bazel run @buildifier_prebuilt//:buildifier`
- **Update Flutter SDK metadata:** `bazel run //tools:update_flutter_versions`
- **Install hooks:** `pre-commit install`

## Roadmap

`rules_flutter` is being delivered in three major stages—Alpha, Beta, and Production-readiness. This roadmap captures what is already in place and what remains to ship a dependable 1.0.

### ✅ Alpha foundations (complete)

- Established Bazel workspace layout, CI scaffolding, and contributor tooling (buildifier, pre-commit, update scripts).
- Implemented Flutter SDK toolchains with version pinning, integrity verification, and bzlmod module extensions.
- Landed core rules (`dart_library`, `flutter_library`, `flutter_app`, `flutter_test`) with providers, transitions, and pub cache management.
- Delivered hermetic execution scaffolding: offline pub caches, reproducible `flutter build/test` invocation.
- Implemented `dart_proto_library`.
- Implemented Gazelle plugins.
- Native support for `build_runner` (in-action `build` plus run helpers).
- Added verification suites: unit tests, smoke e2e workspace, and publishing of SDK metadata through automation.

### 🚢 Beta: Hermetic cross-platform builds (in progress)

- Normalize build outputs for APK/AAB/IPA/web bundles and document how to consume them from Bazel.
- Optimize incremental and remote builds by trimming redundant copies, exercising RBE, and benchmarking cache hit rates.
- Harden failure surfacing with structured action logs, actionable diagnostics, and better toolchain validation.
- Expand automated coverage: multi-platform e2e matrix (Linux/macOS/Windows), release build assertions, and remote execution smoke tests.
- Produce task-oriented docs: quickstarts, troubleshooting, and upgrade guides covering common Flutter/Bazel workflows.

### 🛫 Production readiness (planned)

- Ship CI-backed Android packaging (APK/AAB) with managed SDKs, signing hooks, and release build examples.
- Complete iOS/macOS pipelines with codesign-aware actions, xcframework integration, and Apple toolchain configuration rules.
- Deliver Windows and Linux desktop bundling, including runtime discovery, asset staging, and exe/appimage installers.
- Support advanced Flutter UX: declarative asset rules, localization packaging, configurable build flavors, and web performance tuning.
- Introduce extensibility: plugin federation, native interop helpers, and more code generation entry points.

### 🎯 Release checkpoints

- ✅ Alpha: Hermetic builds proven with web/mobile smoke apps and documented setup.
- 🎯 Beta: Android & iOS packaging validated on CI runners with reference apps and published consumption docs.
- 🏁 1.0: Multi-platform builds, plugin support, asset workflows, and production-ready docs/tests all green on continuous CI and remote execution.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on the [Bazel rules template](https://github.com/bazel-contrib/rules-template)
- Inspired by the Flutter community and [rules_dart](https://github.com/dart-lang/rules_dart)
