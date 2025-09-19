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

# Build specific targets
bazel build //:update_flutter_versions        # Build update script target
bazel build //flutter/tests/flutter_app:hello_world_app

# Update Flutter SDK versions with real integrity hashes
bazel run //tools:update_flutter_versions
# Or run directly: ./scripts/update_flutter_versions.sh
```

### End-to-End Integration Testing

The `e2e/` directory contains separate Bazel projects that test rules_flutter end-to-end as external consumers would use it.

**IMPORTANT**: Always `cd` into the e2e subdirectory before running integration tests:

```bash
# Navigate to e2e directory for integration testing
cd e2e/smoke

# Run integration tests from within e2e directory
bazel test //...                              # All integration tests
bazel build //...                             # All integration targets
bazel run //:example_app                      # Run example application

# Test pub.dev dependency integration
bazel test //:pub_integration_test            # Test pub package usage
bazel build //:flutter_app_with_deps          # Build app with dependencies

# Return to root for main development
cd ../..
```

**Integration Test Structure**:

- Each `e2e/` subdirectory is a standalone Bazel workspace
- Uses `local_repository` to reference the rules_flutter under development
- Tests real-world usage scenarios as external consumers would experience
- Validates the public API and user experience

### Code Quality

```bash
# Format Starlark files (required before commits)
bazel run @buildifier_prebuilt//:buildifier

# Update generated BUILD file targets
bazel run //:gazelle

# Install pre-commit hooks (recommended for development)
pre-commit install

# Run all pre-commit hooks manually (required before completing tasks)
pre-commit run --all-files --verbose
```

### Task Completion Requirements

**CRITICAL**: Before completing any task, you MUST run the following commands and fix any problems:

```bash
# 1. Run all pre-commit hooks and fix any issues
pre-commit run --all-files --verbose

# 2. Run all tests to ensure nothing is broken
bazel test //...

# 3. Run buildifier to ensure code formatting
bazel run @buildifier_prebuilt//:buildifier

# 4. Update BUILD targets if needed
bazel run //:gazelle
```

If any of these commands fail, you MUST fix the issues before considering the task complete. This ensures code quality and prevents breaking changes from being introduced.

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

- **Unit tests**: `flutter/tests/versions_test.bzl` - validates version dictionary structure and internal logic
- **Integration tests**: `flutter/tests/` - tests build rules, toolchain resolution, etc.
- **End-to-end tests**: `e2e/smoke/` - standalone Bazel workspace testing rules_flutter as external users would consume it
  - **CRITICAL**: Always `cd e2e/smoke` before running e2e tests
  - Tests complete workflows: Flutter app creation, pub dependencies, multi-platform builds
  - Validates public API usability and real-world scenarios

### Important Implementation Details

- **Enhanced Implementation Status**: Flutter rules now properly resolve toolchains, validate project structure, and create structured outputs demonstrating real build readiness
- **Integrity Checking**: Enabled with real SHA-256 hashes from Flutter's official APIs
- **Toolchain Resolution**: Rules properly resolve toolchains and validate Flutter SDK access
- **Provider Fields**: Use `flutter_toolchain.flutterinfo.target_tool_path` (not `target_tool`)
- **Build Validation**: All rules validate pubspec.yaml presence, organize Dart files properly, and demonstrate platform-specific targeting

### Development Workflow

The project follows conventional commit messages for automated releases. Development priorities:

1. **✅ COMPLETED**: Enhanced Flutter rules with toolchain validation and structured outputs
2. Implement actual Flutter command execution (pub get, flutter build, flutter test)
3. Add pub dependency resolution and caching
4. Implement platform-specific build capabilities
5. Add hot reload support and development workflow improvements

### Extension Points

- Add new Flutter versions in `scripts/update_flutter_versions.sh` SUPPORTED_VERSIONS array
- Platform support defined in `flutter/private/toolchains_repo.bzl` PLATFORMS
- Build targets configured in `flutter_app` rule's `target` attribute values
