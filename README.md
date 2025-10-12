# Bazel rules for Flutter

Build Flutter applications with Bazel! This repository provides Bazel rules for building, testing, and packaging Flutter applications across multiple platforms.

## Features

- ✅ **Hermetic Flutter builds/tests**: Run real `flutter build` and `flutter test` inside Bazel actions using registered toolchains.
- ✅ **Offline dependency assembly**: `flutter_library` prepares pub caches, `.dart_tool`, and `pub_deps.json` for downstream rules.
- ✅ **Multi-platform builds**: Target Web, Android, iOS, macOS, Windows, and Linux from a single Bazel workspace.
- ✅ **Automatic SDK management**: Download and verify Flutter SDK releases with baked-in integrity hashes.
- ✅ **Bzlmod + pub.dev integration**: Module extensions register Flutter toolchains and mirror hosted packages automatically.
- ✅ **Toolchain isolation**: Hermetic builds with reproducible inputs and sandbox-friendly workspace staging.

## Installation

**⚠️ Development Status**: This project is in active development. The Flutter rules (`flutter_app`, `flutter_test`, `flutter_library`, `dart_library`) execute real `flutter build`/`flutter test` commands after assembling hermetic pub caches. Expect sharp edges: platform builds still require the host SDKs (e.g. Android SDK, Xcode), artifacts focus on validating the pipeline, and we are hardening error reporting. Flutter SDK downloads use real integrity hashes from Flutter's official releases.

From the release you wish to use:
<https://github.com/spencerc/rules_flutter/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.

### Using Bzlmod with Bazel 6 or greater

1. (Bazel 6 only) Enable with `common --enable_bzlmod` in `.bazelrc`.
2. Update your `MODULE.bazel` file:

```starlark
bazel_dep(name = "com_github_spencerc_rules_flutter", version = "1.0.0")

flutter = use_extension("@com_github_spencerc_rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.29.0")
use_repo(
    flutter,
    "flutter_toolchains",
    "flutter_linux",
    "flutter_macos",
    "flutter_windows",
)
register_toolchains("@flutter_toolchains//:all")
```

The extension materializes one repository per supported SDK (`flutter_<platform>`) plus a `flutter_toolchains` alias repo. Registering the toolchains ensures Bazel can resolve Flutter for all actions.

#### Managing pub.dev dependencies

`rules_flutter` ships a `pub` module extension that scans every
`pub_deps.json` (generated with `flutter pub deps --json`) in the module graph and creates repositories for each hosted
dependency. Pair it with the Flutter extension:

```starlark
pub = use_extension("@com_github_spencerc_rules_flutter//flutter:extensions.bzl", "pub")

# Optional overrides pin versions or add extra packages.
pub.package(name = "pub_freezed", package = "freezed", version = "2.4.5")

# Repositories follow the pub_<package> naming convention and must be opt-in.
use_repo(pub, "pub_fixnum", "pub_freezed")
```

Auto-discovered repositories become available once `pub_deps.json` files exist (run `bazel run //:app_lib.update` after dependency changes). Explicit `pub.package(...)` declarations override or extend the generated repositories when you need custom names or mirrors.

### Using WORKSPACE

Paste this snippet into your `WORKSPACE.bazel` file:

```starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "com_github_spencerc_rules_flutter",
    sha256 = "<SHA256>",
    strip_prefix = "rules_flutter-<VERSION>",
    url = "https://github.com/spencerc/rules_flutter/releases/download/v<VERSION>/rules_flutter-v<VERSION>.tar.gz",
)

# Fetches the rules_flutter dependencies.
# If you want to have a different version of some dependency,
# you should fetch it *before* calling this.
load("@com_github_spencerc_rules_flutter//flutter:repositories.bzl", "rules_flutter_dependencies")

rules_flutter_dependencies()
```

## Quick Start

### 1. Basic Flutter App

Create a `BUILD` file in your Flutter project:

```starlark
load(
    "@com_github_spencerc_rules_flutter//flutter:defs.bzl",
    "flutter_app",
    "flutter_library",
    "flutter_test",
)

flutter_library(
    name = "app_lib",
    srcs = glob(["lib/**"]),
    pubspec = "pubspec.yaml",
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

`flutter_library` assembles a reusable pub cache, `pub_deps.json`, and
workspace snapshot without invoking `pub get`. Both `flutter_app` and
`flutter_test` reuse those outputs via the `embed` attribute and run
`flutter pub get --offline` using the prepared cache, keeping builds and tests
fast and hermetic.

Whenever dependencies change, run `bazel run //:app_lib.update` to copy the
fresh `pub_deps.json` (generated via `flutter pub deps --json`) into your workspace next to `pubspec.yaml`.

### 2. Build your app

```bash
# Build for web (aliased as //:my_app)
bazel build //:my_app.web

# Build for Android (requires Android SDK setup)
bazel build //:my_app.apk

# Run the web app locally (serves build artifacts over HTTP)
bazel run //:my_app.web

# Run tests
bazel test //:my_app_test
```

### 3. Multi-platform builds

```starlark
flutter_library(
    name = "app_lib",
    srcs = glob(["lib/**"]),
    pubspec = "pubspec.yaml",
)

flutter_app(
    name = "my_app",
    embed = [":app_lib"],
    web = glob(["web/**"]),
    apk = glob(["android/**"]),
    ios = glob(["ios/**"]),
)
```

## Rules

### flutter_library

Prepares a Flutter package by assembling its pub cache and dependency metadata
without running `pub get`. The generated workspace, pub cache, and pubspec
artifacts are reused by other rules.

**Attributes:**

| Name      | Description                       | Type         | Mandatory | Default |
| --------- | --------------------------------- | ------------ | --------- | ------- |
| `srcs`    | Flutter sources and resources     | `label_list` |           |         |
| `pubspec` | `pubspec.yaml` for the package    | `label`      | ✅        |         |
| `deps`    | Additional `flutter_library` deps | `label_list` |           |         |

### flutter_app

Generates runnable Flutter application targets for the platforms you opt into.

**Attributes:**

| Name      | Description                                                           | Type         | Mandatory | Default |
| --------- | --------------------------------------------------------------------- | ------------ | --------- | ------- |
| `embed`   | Prepared `flutter_library` targets to use                             | `label_list` | ✅        |         |
| `srcs`    | Files copied into every platform-specific Flutter workspace           | `label_list` |           |         |
| `web`     | Files specific to Flutter web builds; enables the `<name>.web` target | `label_list` |           |         |
| `apk`     | Files specific to Android builds; enables the `<name>.apk` target     | `label_list` |           |         |
| `ios`     | Files specific to iOS builds; enables the `<name>.ios` target         | `label_list` |           |         |
| `macos`   | Files specific to macOS builds; enables the `<name>.macos` target     | `label_list` |           |         |
| `linux`   | Files specific to Linux builds; enables the `<name>.linux` target     | `label_list` |           |         |
| `windows` | Files specific to Windows builds; enables the `<name>.windows` target | `label_list` |           |         |

Targets are created only for the platforms you specify. Each generated target is
named `<name>.<platform>` and is runnable (`bazel run` will execute a simple
launcher; for web it serves the built assets locally). The macro also emits an
alias named `<name>` that points at the first declared platform for convenience.

### flutter_test

Runs Flutter tests.

**Attributes:**

| Name         | Description                                 | Type          | Mandatory | Default     |
| ------------ | ------------------------------------------- | ------------- | --------- | ----------- |
| `embed`      | Prepared `flutter_library` targets to use   | `label_list`  | ✅        |             |
| `srcs`       | Test source files copied into the workspace | `label_list`  |           |             |
| `test_files` | Test files or directories to run            | `string_list` |           | `["test/"]` |

### dart_library

Defines a Dart library.

**Attributes:**

| Name   | Description               | Type         | Mandatory | Default |
| ------ | ------------------------- | ------------ | --------- | ------- |
| `srcs` | Dart source files         | `label_list` | ✅        |         |
| `deps` | Dart library dependencies | `label_list` |           |         |

## Configuration

### Flutter SDK Versions

Configure Flutter SDK version in your `MODULE.bazel`:

```starlark
flutter = use_extension("@com_github_spencerc_rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.24.0")  # or "3.27.0", "3.29.0"
use_repo(flutter, "flutter_toolchains")
```

### Supported Platforms

The following platforms are supported for Flutter SDK downloads:

- **macOS**: Both Intel and Apple Silicon
- **Linux**: x86_64
- **Windows**: x86_64

## Examples

Check out the [e2e smoke test](e2e/smoke/) for a complete working example of an external workspace using rules_flutter.

For comprehensive test examples, see:

- [Flutter App Integration](e2e/smoke/flutter_app/) - Basic Flutter app with widget tests
- [Multi-platform Integration](e2e/smoke/multiplatform/) - Building for multiple targets
- [Toolchain Tests](flutter/tests/toolchain/) - Dart library and toolchain integration

## Development

### Running Tests

```bash
# Run all tests
bazel test //...

# Run just Flutter tests
bazel test //flutter/tests:all_tests

# Run integration tests
cd e2e/smoke && bazel test //:integration_tests

# Run unit tests
bazel test //flutter/tests:versions_test

# Run smoke tests
cd e2e/smoke && bazel test //:smoke_test
```

### Updating Flutter SDK Versions

To update the supported Flutter SDK versions and their integrity hashes:

```bash
# Update Flutter SDK versions from official releases
bazel run //tools:update_flutter_versions

# Or run the script directly
./scripts/update_flutter_versions.sh
```

This script automatically fetches the latest release information from Flutter's official APIs and updates the integrity hashes in `flutter/private/versions.bzl`. The script supports Flutter versions 3.24.0, 3.27.0, and 3.29.0 across macOS, Linux, and Windows platforms.

### Prerequisites

- Bazel 6.0+
- For Android builds: Android SDK
- For iOS builds: Xcode (macOS only)

### Setup Development Environment

```bash
# Install pre-commit hooks
pre-commit install

# Run buildifier to format BUILD files
bazel run @buildifier_prebuilt//:buildifier
```

## Development Roadmap

`rules_flutter` is being delivered in three major stages—Alpha, Beta, and Production-readiness. This roadmap captures what is already in place and what remains to ship a dependable 1.0.

### ✅ Alpha foundations (complete)

- Established Bazel workspace layout, CI scaffolding, and contributor tooling (buildifier, pre-commit, update scripts).
- Implemented Flutter SDK toolchains with version pinning, integrity verification, and bzlmod module extensions.
- Landed core rules (`flutter_library`, `flutter_app`, `flutter_test`, `dart_library`) with providers, transitions, and pub cache management.
- Delivered hermetic execution scaffolding: offline pub caches, reproducible `flutter build/test` invocation, and staged workspace assets.
- Added verification suites: unit tests, smoke e2e workspace, and publishing of SDK metadata through automation.

### 🚢 Beta: Hermetic cross-platform builds (in progress)

- Harden failure surfacing with structured action logs, actionable diagnostics, and better toolchain validation.
- Normalize build outputs for APK/AAB/IPA/web bundles and document how to consume them from Bazel.
- Optimize incremental and remote builds by trimming redundant copies, exercising RBE, and benchmarking cache hit rates.
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
