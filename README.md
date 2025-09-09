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

**⚠️ Development Status**: This project is currently in active development. The Flutter build rules (`flutter_app`, `flutter_test`) are placeholder implementations that validate toolchain resolution but do not yet perform actual Flutter builds. Flutter SDK downloads require valid integrity hashes which are not yet configured. For development/testing purposes, integrity checking is disabled.

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
load("@com_github_spencerc_rules_flutter//flutter:defs.bzl", "flutter_app", "flutter_test")

flutter_app(
    name = "my_app",
    srcs = glob(["lib/**/*.dart", "pubspec.yaml", "web/**/*"]),
    target = "web",  # Options: web, apk, ios, macos, linux, windows
)

flutter_test(
    name = "my_app_test",
    srcs = glob(["lib/**/*.dart", "pubspec.yaml", "test/**/*.dart"]),
)
```

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
flutter_app(
    name = "my_app_web",
    srcs = glob(["lib/**/*.dart", "pubspec.yaml", "web/**/*"]),
    target = "web",
)

flutter_app(
    name = "my_app_android",
    srcs = glob(["lib/**/*.dart", "pubspec.yaml", "android/**/*"]),
    target = "apk",
)

flutter_app(
    name = "my_app_ios",
    srcs = glob(["lib/**/*.dart", "pubspec.yaml", "ios/**/*"]),
    target = "ios",
)
```

## Rules

### flutter_app

Builds a Flutter application for the specified target platform.

**Attributes:**

| Name     | Description                   | Type         | Mandatory | Default |
| -------- | ----------------------------- | ------------ | --------- | ------- |
| `srcs`   | Flutter project source files  | `label_list` | ✅        |         |
| `target` | Flutter build target platform | `string`     |           | `"web"` |

**Supported targets:** `web`, `apk`, `ios`, `macos`, `linux`, `windows`

### flutter_test

Runs Flutter tests.

**Attributes:**

| Name         | Description                      | Type          | Mandatory | Default     |
| ------------ | -------------------------------- | ------------- | --------- | ----------- |
| `srcs`       | Flutter project source files     | `label_list`  | ✅        |             |
| `test_files` | Test files or directories to run | `string_list` |           | `["test/"]` |

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

For comprehensive test examples, see the [Flutter tests](flutter/tests/) directory:

- [Flutter App Test](flutter/tests/flutter_app_test/) - Basic Flutter app with widget tests
- [Multi-platform Test](flutter/tests/multiplatform_test/) - Building for multiple targets
- [Toolchain Test](flutter/tests/toolchain_test/) - Dart library and toolchain integration

## Development

### Running Tests

```bash
# Run all tests
bazel test //...

# Run just Flutter tests
bazel test //flutter/tests:all_tests

# Run integration tests
bazel test //flutter/tests:integration_tests

# Run unit tests
bazel test //flutter/tests:versions_test

# Run smoke tests
bazel test //e2e/smoke:smoke_test
```

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on the [Bazel rules template](https://github.com/bazel-contrib/rules-template)
- Inspired by the Flutter community and [rules_dart](https://github.com/dart-lang/rules_dart)
