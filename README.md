# Bazel rules for Flutter

Build Flutter applications with Bazel! This repository provides Bazel rules for building, testing, and packaging Flutter applications across multiple platforms.

## Features

- ✅ **Multi-platform builds**: Build Flutter apps for Web, Android, iOS, macOS, Windows, and Linux
- ✅ **Automatic SDK management**: Download and manage Flutter SDK versions declaratively
- ✅ **Testing support**: Run Flutter tests within Bazel's build system
- ✅ **Dart libraries**: Support for standalone Dart libraries and packages
- ✅ **Incremental builds**: Leverage Bazel's caching for fast incremental builds
- ✅ **Toolchain integration**: Hermetic builds with proper toolchain isolation

## Installation

**⚠️ Development Status**: This project is currently in active development. The Flutter build rules (`flutter_app`, `flutter_test`, `dart_library`) are enhanced implementations that validate toolchain resolution, project structure, and create structured outputs demonstrating build readiness. While not yet executing actual Flutter commands, they provide a solid foundation for real Flutter builds. Flutter SDK downloads use real integrity hashes from Flutter's official releases.

From the release you wish to use:
<https://github.com/spencerc/rules_flutter/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.

### Using Bzlmod with Bazel 6 or greater

1. (Bazel 6 only) Enable with `common --enable_bzlmod` in `.bazelrc`.
2. Add to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "com_github_spencerc_rules_flutter", version = "1.0.0")
```

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
    target = "web",  # Options: web, apk, ios, macos, linux, windows
)

flutter_test(
    name = "my_app_test",
    srcs = glob(["test/**"]),
    embed = [":app_lib"],
)
```

`flutter_library` runs `flutter pub get` once and exposes the generated
workspace, pub cache, and `pubspec.lock`. Both `flutter_app` and `flutter_test`
reuse those outputs via the `embed` attribute, keeping builds and tests fast and
hermetic.

### 2. Build your app

```bash
# Build for web
bazel build //:my_app

# Build for Android (requires Android SDK setup)
bazel build //:my_app --define target=apk

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
    name = "my_app_web",
    embed = [":app_lib"],
    srcs = glob(["web/**"]),
    target = "web",
)

flutter_app(
    name = "my_app_android",
    embed = [":app_lib"],
    srcs = glob(["android/**"]),
    target = "apk",
)

flutter_app(
    name = "my_app_ios",
    embed = [":app_lib"],
    srcs = glob(["ios/**"]),
    target = "ios",
)
```

## Rules

### flutter_library

Prepares a Flutter package by running `flutter pub get` once and exposing the
workspace, pub cache, and pubspec outputs to other rules.

**Attributes:**

| Name      | Description                       | Type         | Mandatory | Default |
| --------- | --------------------------------- | ------------ | --------- | ------- |
| `srcs`    | Flutter sources and resources     | `label_list` |           |         |
| `pubspec` | `pubspec.yaml` for the package    | `label`      | ✅        |         |
| `deps`    | Additional `flutter_library` deps | `label_list` |           |         |

### flutter_app

Builds a Flutter application for the specified target platform.

**Attributes:**

| Name     | Description                                | Type         | Mandatory | Default |
| -------- | ------------------------------------------ | ------------ | --------- | ------- |
| `embed`  | Prepared `flutter_library` targets to use  | `label_list` | ✅        |         |
| `srcs`   | Additional source files to overlay per app | `label_list` |           |         |
| `target` | Flutter build target platform              | `string`     |           | `"web"` |

**Supported targets:** `web`, `apk`, `ios`, `macos`, `linux`, `windows`

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

This section outlines the planned development phases and features for rules_flutter:

### ✅ Phase 1: Foundation (Complete)

- ✅ **Complete**: Basic project structure and toolchain setup
- ✅ **Complete**: Flutter SDK version management and download URLs
- ✅ **Complete**: Enhanced build rules with toolchain validation (`flutter_app`, `flutter_test`, `dart_library`)
- ✅ **Complete**: Comprehensive testing framework
- ✅ **Complete**: Real Flutter SDK integrity hashes
- ✅ **Complete**: Project structure validation and build readiness verification

### 🚧 Phase 2: Core Functionality (Current)

- ✅ **Complete**: Execute actual Flutter commands (`pub get`, `flutter build`, `flutter test`)
- 🔄 **In Progress**: **Pub dependency management**: Integration with pub.dev packages and dependency caching
- 🔄 **In Progress**: **Build caching**: Leverage Bazel's incremental builds for Flutter projects
- 🔲 **Error handling**: Comprehensive error messages and build diagnostics
- 🔲 **Hot reload support**: Development workflow improvements

### 🚀 Phase 3: Platform Support (Future)

- 🔲 **Android builds**: Full APK/AAB generation with SDK integration
- 🔲 **iOS builds**: IPA generation with Xcode integration
- 🔲 **Desktop platforms**: Native Windows, macOS, Linux builds
- 🔲 **Web optimization**: Advanced web build configurations
- 🔲 **CI/CD templates**: GitHub Actions and other CI integrations

### 🌟 Phase 4: Advanced Features (Long-term)

- 🔲 **Code generation**: Build-time code gen (JSON serialization, etc.)
- 🔲 **Asset management**: Images, fonts, and localization
- 🔲 **Testing enhancements**: Widget testing, integration testing
- 🔲 **Performance profiling**: Build-time Flutter performance analysis
- 🔲 **Plugin ecosystem**: Support for Flutter plugins and native modules

### 💡 Contributing Priorities

We welcome contributions in these areas (in order of priority):

1. **Real build implementations** - Replace placeholder rules with actual Flutter commands
2. **Pub dependency resolution** - Integrate with Flutter's package ecosystem
3. **Platform-specific builds** - Android SDK and iOS build chain integration
4. **Documentation and examples** - More comprehensive usage examples

### 📊 Success Metrics

- ✅ **Basic functionality**: All tests passing
- 🎯 **Alpha release**: Real Flutter web builds working
- 🎯 **Beta release**: Android/iOS builds functional
- 🎯 **1.0 release**: Production-ready with full platform support

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on the [Bazel rules template](https://github.com/bazel-contrib/rules-template)
- Inspired by the Flutter community and [rules_dart](https://github.com/dart-lang/rules_dart)
