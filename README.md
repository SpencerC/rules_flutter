# Bazel rules for Flutter

Build Flutter applications with Bazel. `rules_flutter` supplies hermetic Flutter
toolchains, module extensions for pub.dev dependencies, Gazelle language
support, and first-class protobuf generation so teams can ship Flutter code from
CI with confidence.

## Highlights

- Flutter SDK toolchains with integrity verification and multi-platform support.
- Hermetic Flutter builds/tests that reuse prepared pub caches.
- Protobuf to Dart workflows powered by `dart_proto_library`.
- Gazelle plugins that keep Flutter, Dart, and proto BUILD files in sync.

## Getting Started

> **Development status:** These rules are evolving quickly. Expect some sharp
> edges while the APIs stabilize.

### Bzlmod setup (Bazel 6+)

Add the module snippet below to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_flutter", version = "1.0.0")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.29.0")
use_repo(
    flutter,
    "flutter_toolchains",
    "flutter_sdk",
)
register_toolchains("@flutter_toolchains//:all")
```

The Flutter extension resolves a platform-appropriate SDK and registers
toolchains so every action can locate Flutter binaries without relying on host
installs.

#### SDK hermeticity guarantees

The SDK repository is immutable after fetch:

- The release archive is downloaded with integrity verification, and the
  launcher's engine-version refresh is patched at fetch time so `flutter`
  invocations never write into the repository.
- `bin/cache` is sealed read-only; any residual write attempt fails the build
  loudly instead of silently mutating shared state.
- Build actions run with `FLUTTER_ALREADY_LOCKED`, `--no-version-check`, and a
  scratch `HOME`, so no lockfiles, stamps, or analytics/config writes escape
  the sandbox.

Stable release archives already ship the engine artifacts for web, Android,
and the host desktop platform (plus iOS on macOS). If you rely on artifacts a
particular archive does not include, declare them and they will be verified —
or fetched via `flutter precache` — at repository fetch time:

```starlark
flutter.toolchain(
    flutter_version = "3.38.4",
    precache = ["web", "android", "ios"],
)
```

Do not run `flutter precache` or `flutter config` against the Bazel-provided
SDK from scripts: it is unnecessary and the sealed cache will reject it.

#### Managing pub.dev dependencies

`rules_flutter` ships a `pub` module extension that scans every `pub_deps.json`
and creates Bazel repositories for hosted packages. Pair it with the Flutter
extension:

```starlark
pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")

# Optional overrides pin versions or add extra packages.
pub.package(name = "pub_freezed", package = "freezed", version = "2.4.5")

# Repositories follow the pub_<package> naming convention.
use_repo(pub, "pub_fixnum", "pub_freezed")
```

Generate each `pub_deps.json` alongside its `pubspec.yaml` by running the `*.update` helper target (for example
`bazel run //:app_lib.update`) whenever dependencies change.

### Workspace best practices

The external workspace under `e2e/smoke` is the canonical reference for how to
structure a Flutter+Bazel project. Key takeaways:

- **Register toolchains up front:** Mirror `e2e/smoke/MODULE.bazel` so Bazel
  always knows which Flutter SDK to use.
- **Keep pubspec assets colocated:** Place `pubspec.yaml`, `pub_deps.json`, and
  `flutter_library` targets in the same package. Declare generator commands in
  `generator_commands = [...]` (see `e2e/smoke/flutter_app/BUILD.bazel`).
- **Regenerate BUILD files with Gazelle:** The workspace defines a custom
  `gazelle_binary` that understands Flutter, proto, and Starlark sources.

### Build runner workflows

`flutter_library` and `dart_library` support one-shot generators plus
`build_runner` helpers:

- `generator_commands = [...]` runs `dart run <package>:<script>` during
  dependency preparation.
- Omitting `build_runner_modes` emits runnable helper targets for all modes:
  `:<name>.build_runner_build`, `:<name>.build_runner_test`,
  `:<name>.build_runner_watch`, and `:<name>.build_runner_serve`.
- Setting `build_runner_modes` narrows both the emitted helper targets and the
  action-backed `build_runner build` behavior.

These helper targets are normal executables, so they compose directly with
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

Run with:

```bash
bazel run //:app_dev
```

## Protobuf generation

`dart_proto_library` wraps the Dart protoc plugin so you can pair protobuf
schemas with generated Dart libraries. The smoke workspace demonstrates the
pattern:

```starlark
# protos/api/v1/BUILD.bazel
load("@protobuf//bazel:proto_library.bzl", "proto_library")
load("@rules_flutter//flutter:defs.bzl", "dart_proto_library")

proto_library(
    name = "services_api_v1_proto",
    srcs = ["service.proto"],
    visibility = ["//visibility:public"],
)

dart_proto_library(
    name = "services_api_v1_proto_dart",
    visibility = ["//visibility:public"],
    deps = [":services_api_v1_proto"],
)
```

Downstream targets depend on the generated Dart package just like any other
dependency:

```starlark
# proto_service/BUILD.bazel
load("@rules_flutter//flutter:defs.bzl", "dart_library")

dart_library(
    name = "proto_client",
    srcs = ["lib/client.dart"],
    deps = ["//protos/api/v1:services_api_v1_proto_dart"],
)
```

## Gazelle automation

`rules_flutter` ships Gazelle plugins to keep BUILD files in sync with your
Flutter sources and proto schemas. Enable them by composing a custom binary, for example:

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
bazel run //:gazelle            # from the root workspace
```

## Quick start: build a Flutter app

Create a `BUILD.bazel` file next to your Flutter sources:

```starlark
load(
    "@rules_flutter//flutter:defs.bzl",
    "flutter_app",
    "flutter_library",
    "flutter_test",
)

flutter_library(
    name = "app_lib",
    srcs = glob(["lib/**"]),
    pubspec = "pubspec.yaml",
    pub_deps = "pub_deps.json",
)

flutter_app(
    name = "my_app",
    embed = [":app_lib"],
    web = glob(["web/**"]),
)

flutter_test(
    name = "my_app_test",
    srcs = glob(["test/**"]),
    embed = [":app_lib"],
)
```

Build and test targets just like any other Bazel rule:

```bash
bazel build //:my_app.web
bazel test //:my_app_test
```

### Customizing builds: dart_defines, build_args, and mode

`flutter_app` supports compile-time configuration shared across platforms or
scoped per platform. Each platform attribute accepts either overlay files (as
above) or a dict spec with `srcs`, `dart_defines`, `build_args`, `mode`, and
`env` keys:

```starlark
flutter_app(
    name = "my_app",
    embed = [":app_lib"],
    # Shared by all platforms; select() is supported for per-environment
    # config keyed off a string_flag.
    dart_defines = select({
        "//:prod": {"API_ENDPOINT": "api.example.com", "ENV_NAME": "prod"},
        "//conditions:default": {"API_ENDPOINT": "api.dev.example.com", "ENV_NAME": "dev"},
    }),
    build_args = ["--no-tree-shake-icons"],
    web = {
        "srcs": glob(["web/**"]),
        "build_args": ["--source-maps"],  # appended after the shared args
        "mode": "release",                # or "profile" / "debug"
    },
)
```

Values read via `String.fromEnvironment` in Dart receive the configured
`--dart-define` pairs. Per-platform `build_args` concatenate after the shared
list; `dart_defines`/`env` dicts merge with platform keys winning. One
Starlark limitation to know about: two `select()`s cannot be merged, so when
using `select()` compose the complete dict per branch.

When dependencies change, rerun the generated helper to refresh your pub cache
snapshot:

```bash
bazel run //:app_lib.update
```

## Development workflows

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
- Added verification suites: unit tests, smoke e2e workspace, and publishing of SDK metadata through automation.

### 🚢 Beta: Hermetic cross-platform builds (in progress)

- Native support for `build_runner`.
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
- Introduce extensibility: plugin federation, native interop helpers, and code generation entry points (`build_runner`, `json_serializable`, etc.).

### 🔧 Enabling workstreams

- Documentation: restructure `docs/` into scenario-based guides, API reference, migration playbooks, and host environment setup guides.
- Samples: maintain a gallery of minimal apps (mobile, desktop, web) exercising each rule and kept green in CI.
- Release process: define versioning policy, changelog automation, and artifact verification prior to cutting tagged releases.
- Community health: triage rotations, RFC template, contribution workshops, and public roadmap updates.
- Quality gates: enforce `bazel test //flutter/tests:all_tests` and `cd e2e/smoke && bazel test //:integration_tests` in CI along with lint/buildifier checks.

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
