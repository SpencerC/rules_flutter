# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Essential Commands

### Building and Testing

```bash
# Run all tests (primary development command)
bazel test //...

# Run specific test suites
bazel test //flutter/tests:all_tests          # All Flutter tests
bazel test //flutter/tests:integration_tests   # Integration tests only
bazel test //flutter/tests:versions_test       # Unit tests for versions
bazel test //e2e/smoke:smoke_test             # Smoke tests

# Build specific targets
bazel build //:update_flutter_versions        # Build update script target
bazel build //flutter/tests/flutter_app:hello_world_app

# Update Flutter SDK versions with real integrity hashes
bazel run //tools:update_flutter_versions
# Or run directly: ./scripts/update_flutter_versions.sh
```

### Code Quality

```bash
# Format Starlark files (required before commits)
bazel run @buildifier_prebuilt//:buildifier

# Update generated BUILD file targets
bazel run //:gazelle

# Install pre-commit hooks (recommended for development)
pre-commit install
```

### Development Setup

```bash
# Override rules_flutter to use local development version
OVERRIDE="--override_repository=rules_flutter=$(pwd)/rules_flutter"
echo "common $OVERRIDE" >> ~/.bazelrc
```

## Architecture Overview

### Core Structure

**rules_flutter** is a Bazel ruleset for building Flutter applications. The current implementation is in **Phase 1** with placeholder rules that validate toolchain resolution but don't perform actual Flutter builds yet.

### Key Components

1. **Flutter SDK Management** (`flutter/repositories.bzl`, `flutter/private/versions.bzl`)

   - Downloads Flutter SDK from Google Cloud Storage with integrity verification
   - Supports versions 3.24.0, 3.27.0, 3.29.0 across macOS/Linux/Windows
   - Real SHA-256 hashes fetched from Flutter's official release APIs

2. **Toolchain System** (`flutter/toolchain.bzl`, `flutter/private/toolchains_repo.bzl`)

   - `FlutterInfo` provider exposes `target_tool_path` and `tool_files`
   - Multi-platform toolchain registration via `flutter_register_toolchains()`
   - Platform mapping handled in `PLATFORMS` constant

3. **Build Rules** (`flutter/defs.bzl`)

   - `flutter_app`: Placeholder that creates dummy output files, supports targets: web, apk, ios, macos, linux, windows
   - `flutter_test`: Placeholder test rule that always passes
   - `dart_library`: Pass-through rule for Dart source files
   - All rules use toolchain resolution but don't invoke Flutter SDK yet

4. **Version Management** (`scripts/update_flutter_versions.sh`)
   - Automated script fetching from `storage.googleapis.com/flutter_infra_release/releases/`
   - Converts Flutter's SHA-256 hashes to SRI format for Bazel integrity checking
   - Updates `flutter/private/versions.bzl` with current release data

### Test Organization

- **Unit tests**: `flutter/tests/versions_test.bzl` - validates version dictionary structure
- **Integration tests**: `flutter/tests/` - tests for build rules, toolchain resolution, multiplatform
- **Smoke tests**: `e2e/smoke/` - standalone example workspace (ignored by main build)

### Important Implementation Details

- **Placeholder Status**: Current Flutter rules create dummy outputs and don't execute actual Flutter commands
- **Integrity Checking**: Enabled with real SHA-256 hashes from Flutter's official APIs
- **Toolchain Resolution**: Rules properly resolve toolchains but don't use them for builds yet
- **Provider Fields**: Use `flutter_toolchain.flutterinfo.target_tool_path` (not `target_tool`)

### Development Workflow

The project follows conventional commit messages for automated releases. Development priorities:

1. Replace placeholder implementations with real Flutter command execution
2. Implement pub dependency resolution
3. Add platform-specific build capabilities
4. Extend testing and documentation

### Extension Points

- Add new Flutter versions in `scripts/update_flutter_versions.sh` SUPPORTED_VERSIONS array
- Platform support defined in `flutter/private/toolchains_repo.bzl` PLATFORMS
- Build targets configured in `flutter_app` rule's `target` attribute values
