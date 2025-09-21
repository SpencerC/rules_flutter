"""Flutter command execution actions for Bazel rules."""

def create_flutter_working_dir(ctx, pubspec_file, dart_files, other_files):
    """Create a working directory structure for Flutter commands.

    Args:
        ctx: The rule context
        pubspec_file: The pubspec.yaml file
        dart_files: List of .dart source files
        other_files: List of other source files

    Returns:
        Tuple of (working_dir, all_input_files)
    """
    working_dir = ctx.actions.declare_directory(ctx.label.name + "_flutter_workspace")
    all_input_files = [pubspec_file] + dart_files + other_files

    # Create the workspace directory structure
    workspace_script = ctx.actions.declare_file(ctx.label.name + "_setup_workspace.sh")

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="$1"
mkdir -p "$WORKSPACE_DIR"

# Copy pubspec.yaml to root
cp "{pubspec}" "$WORKSPACE_DIR/pubspec.yaml"

# Create lib directory and copy Dart files
mkdir -p "$WORKSPACE_DIR/lib"
mkdir -p "$WORKSPACE_DIR/test"

# Copy source files maintaining directory structure
""".format(pubspec = pubspec_file.path)

    # Add commands to copy dart files maintaining their relative paths
    for dart_file in dart_files:
        # Extract relative path from the source file
        if "/lib/" in dart_file.path:
            relative_path = dart_file.path[dart_file.path.find("/lib/") + 1:]
            script_content += 'mkdir -p "$WORKSPACE_DIR/$(dirname "{}")" && cp "{}" "$WORKSPACE_DIR/{}"\n'.format(
                relative_path,
                dart_file.path,
                relative_path,
            )
        elif "/test/" in dart_file.path:
            relative_path = dart_file.path[dart_file.path.find("/test/") + 1:]
            script_content += 'mkdir -p "$WORKSPACE_DIR/$(dirname "{}")" && cp "{}" "$WORKSPACE_DIR/{}"\n'.format(
                relative_path,
                dart_file.path,
                relative_path,
            )
        else:
            # Default to lib directory
            script_content += 'cp "{}" "$WORKSPACE_DIR/lib/$(basename "{}")"\n'.format(
                dart_file.path,
                dart_file.path,
            )

    # Copy other files
    for other_file in other_files:
        if other_file.basename != "pubspec.yaml":  # Already copied
            # Preserve directory structure for web files
            if "/web/" in other_file.path:
                relative_path = other_file.path[other_file.path.find("/web/") + 1:]
                script_content += 'mkdir -p "$WORKSPACE_DIR/$(dirname "{}")" && cp "{}" "$WORKSPACE_DIR/{}"\n'.format(
                    relative_path,
                    other_file.path,
                    relative_path,
                )
            else:
                script_content += 'cp "{}" "$WORKSPACE_DIR/$(basename "{}")"\n'.format(
                    other_file.path,
                    other_file.path,
                )

    ctx.actions.write(
        output = workspace_script,
        content = script_content,
        is_executable = True,
    )

    # Run the workspace setup
    ctx.actions.run(
        inputs = all_input_files,
        outputs = [working_dir],
        executable = workspace_script,
        arguments = [working_dir.path],
        mnemonic = "SetupFlutterWorkspace",
        progress_message = "Setting up Flutter workspace for %s" % ctx.label.name,
    )

    return working_dir, all_input_files

def flutter_pub_get_action(ctx, flutter_toolchain, working_dir, pubspec_file):
    """Execute flutter pub get command.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        pubspec_file: The pubspec.yaml file

    Returns:
        Tuple of (pub_get_output, pub_cache_dir, pubspec_lock, dart_tool_dir)
    """

    # Get the actual Flutter binary file object (first tool file)
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    # Create output artifacts
    pub_get_output = ctx.actions.declare_file(ctx.label.name + "_pub_get.log")
    pub_cache_dir = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")
    pubspec_lock = ctx.actions.declare_file(ctx.label.name + "_pubspec.lock")
    dart_tool_dir = ctx.actions.declare_directory(ctx.label.name + "_dart_tool")

    # Enhanced script that properly executes flutter pub get and reports results
    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
FLUTTER_BIN="{flutter_bin}"
ORIGINAL_PWD="$PWD"

# Set up pub cache directory from file path
export PUB_CACHE="$PUB_CACHE_DIR"
mkdir -p "$PUB_CACHE_DIR"

# Configure Flutter for sandbox environment  
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export FLUTTER_ROOT="$ORIGINAL_PWD/external/+flutter+flutter_macos/flutter"
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Change to the workspace directory from execroot
cd "$ORIGINAL_PWD/$WORKSPACE_DIR"

echo "=== Flutter Pub Get Execution ==="
echo "Working directory: $(pwd)"
echo "Expected workspace dir: $WORKSPACE_DIR"
echo "Flutter binary: $FLUTTER_BIN"  
echo "Pub cache: $PUB_CACHE_DIR"
echo "Contents of workspace:"
ls -la
echo ""

# Check if pubspec.yaml symlink is valid
if [ -L "pubspec.yaml" ]; then
    echo "pubspec.yaml is a symlink pointing to: $(readlink pubspec.yaml)"
    if [ ! -f "$(readlink pubspec.yaml)" ]; then
        echo "✗ ERROR: pubspec.yaml symlink target doesn't exist"
        exit 1
    fi
fi

# Validate pubspec.yaml exists and is valid
if [ ! -f "pubspec.yaml" ]; then
    echo "✗ ERROR: pubspec.yaml not found in workspace"
    echo "Files in workspace:"
    ls -la
    exit 1
fi

echo "pubspec.yaml found:"
head -10 pubspec.yaml
echo ""

echo "Debug: Confirming Flutter SDK access from execroot"
# Set absolute path to Flutter binary from execroot  
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"
echo "Flutter binary absolute path: $FLUTTER_BIN_ABS"
echo "Toolchain info: {tool_files_count} tool files, {sdk_files_count} SDK files"

# Validate Flutter binary exists and is executable
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at: $FLUTTER_BIN_ABS"
    echo "Expected Flutter SDK to be available via toolchain"
    echo "Check your MODULE.bazel flutter.toolchain() configuration"
    echo "Available files in $(dirname "$FLUTTER_BIN_ABS"):"
    ls -la "$(dirname "$FLUTTER_BIN_ABS")" 2>/dev/null || echo "Directory not found"
    exit 1
fi

if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not executable at: $FLUTTER_BIN_ABS"
    ls -la "$FLUTTER_BIN_ABS"
    echo "Check Flutter SDK permissions and installation"
    exit 1
fi

echo "Flutter binary verified at: $FLUTTER_BIN_ABS"
echo "Flutter version:"
"$FLUTTER_BIN_ABS" --version --suppress-analytics || {{
    echo "✗ FATAL ERROR: Could not get Flutter version"
    echo "Flutter SDK may be corrupted or incompatible"
    exit 1
}}
echo ""

echo "Trying dart pub get first:"
DART_BIN="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ -f "$DART_BIN" ]; then
    echo "Using Dart SDK directly: $DART_BIN"
    if "$DART_BIN" pub get; then
        echo "✓ dart pub get completed successfully"
        echo ""
    else
        echo "Dart pub get failed, falling back to Flutter"
    fi
else
    echo "Dart SDK not found, using Flutter directly"
fi

echo "Running: $FLUTTER_BIN_ABS pub get"
if "$FLUTTER_BIN_ABS" pub get --suppress-analytics; then
    echo "✓ flutter pub get completed successfully"
    
    # Validate and report outputs
    echo ""
    echo "=== Post-execution Analysis ==="
    if [ -f "pubspec.lock" ]; then
        echo "✓ pubspec.lock generated ($(wc -l < pubspec.lock) lines)"
        echo "Sample dependencies:"
        head -20 pubspec.lock | grep -E "(name:|version:)" | head -10 || echo "No dependencies found in pubspec.lock"
    else
        echo "✗ FATAL ERROR: pubspec.lock not generated by Flutter"
        echo "This indicates a serious issue with Flutter pub get execution"
        exit 1
    fi
    
    if [ -d ".dart_tool" ]; then
        echo "✓ .dart_tool directory created"
        if [ -f ".dart_tool/package_config.json" ]; then
            echo "✓ package_config.json generated"
            # Optional: jq may not be available; fallback to unknown
            echo "Packages configured: $( (command -v jq >/dev/null 2>&1 && jq '.packages | length' .dart_tool/package_config.json) || echo 'unknown')"
        else
            echo "✗ FATAL ERROR: package_config.json not generated by Flutter"
            echo "This indicates a serious issue with Flutter pub get execution"
            exit 1
        fi
    else
        echo "✗ FATAL ERROR: .dart_tool directory not created by Flutter"
        echo "This indicates a serious issue with Flutter pub get execution"
        exit 1
    fi
    
    # Check pub cache
    if [ -n "$(ls -A "$PUB_CACHE_DIR" 2>/dev/null)" ]; then
        echo "✓ Pub cache populated with dependencies"
    else
        echo "⚠ Warning: Pub cache appears empty (may be expected for projects with no dependencies)"
    fi
    
    echo ""
    echo "=== Final Status ==="
    echo "✓ Flutter pub get execution completed successfully"
    
else
    echo "✗ FATAL ERROR: flutter pub get failed"
    echo "This could be due to:"
    echo "  - Network connectivity issues" 
    echo "  - Invalid pubspec.yaml dependencies"
    echo "  - Flutter SDK compatibility issues"
    echo "  - Insufficient permissions"
    echo ""
    echo "Check your pubspec.yaml and network connection"
    exit 1
fi
""".format(
        workspace_dir = working_dir.path,
        pub_cache_dir = pub_cache_dir.path,
        flutter_bin = flutter_bin,
        tool_files_count = len(flutter_toolchain.flutterinfo.tool_files),
        sdk_files_count = len(flutter_toolchain.flutterinfo.sdk_files),
        first_tool_file_path = flutter_bin_file.path if flutter_toolchain.flutterinfo.tool_files else "No tool files",
    )

    # Execute pub get and create all outputs in one action
    ctx.actions.run_shell(
        inputs = [working_dir, pubspec_file] + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
        outputs = [pub_get_output, pubspec_lock, pub_cache_dir, dart_tool_dir],
        command = script_content + """

echo ""
echo "=== Creating Output Files ==="

# Go back to execution root
cd "$ORIGINAL_PWD"

# Create output directories
mkdir -p "$(dirname "{pub_get_output}")"
mkdir -p "$(dirname "{pubspec_lock}")"
mkdir -p "{pub_cache_dir}"
mkdir -p "{dart_tool_dir}"

# Create the pub get log
echo "=== Flutter Pub Get Results ===" > "{pub_get_output}"
echo "Flutter binary: {flutter_bin}" >> "{pub_get_output}" 
echo "Working directory: $WORKSPACE_DIR" >> "{pub_get_output}"
echo "Execution time: $(date)" >> "{pub_get_output}"
echo "" >> "{pub_get_output}"

# Copy pubspec.lock from workspace (should always exist after successful pub get)
if [ -f "$WORKSPACE_DIR/pubspec.lock" ]; then
    echo "✓ Copying pubspec.lock from Flutter pub get" >> "{pub_get_output}"
    cp "$WORKSPACE_DIR/pubspec.lock" "{pubspec_lock}"
else
    echo "✗ FATAL ERROR: pubspec.lock not found after successful pub get" >> "{pub_get_output}"
    echo "This should never happen - Flutter pub get validation failed"
    exit 1
fi

# Copy entire .dart_tool directory
if [ -d "$WORKSPACE_DIR/.dart_tool" ]; then
    echo "✓ Copying .dart_tool directory from Flutter pub get" >> "{pub_get_output}"
    # Clean target dir first to avoid stale files
    rm -rf "{dart_tool_dir}"
    mkdir -p "{dart_tool_dir}"
    cp -R "$WORKSPACE_DIR/.dart_tool/." "{dart_tool_dir}/"
else
    echo "✗ FATAL ERROR: .dart_tool directory not found after successful pub get" >> "{pub_get_output}"
    echo "This should never happen - Flutter pub get validation failed"
    exit 1
fi

# Sync PUB_CACHE directory to declared output directory
if [ -d "$PUB_CACHE_DIR" ] && [ -n "$(ls -A "$PUB_CACHE_DIR" 2>/dev/null)" ]; then
    echo "✓ Pub cache populated with dependencies" >> "{pub_get_output}"
else
    echo "⚠ Pub cache directory empty or not found" >> "{pub_get_output}"
    # Ensure directory exists and has a placeholder for Bazel tree artifact determinism
    mkdir -p "{pub_cache_dir}"
    echo '{{}}' > "{pub_cache_dir}/.cache_info.json"
fi

echo "" >> "{pub_get_output}"
echo "Status: Real Flutter pub get execution completed" >> "{pub_get_output}"
echo "All output files created successfully"
""".format(
            pub_get_output = pub_get_output.path,
            pubspec_lock = pubspec_lock.path,
            pub_cache_dir = pub_cache_dir.path,
            dart_tool_dir = dart_tool_dir.path,
            flutter_bin = flutter_bin,
        ),
        mnemonic = "FlutterPubGet",
        progress_message = "Running flutter pub get for %s" % ctx.label.name,
    )

    return pub_get_output, pub_cache_dir, pubspec_lock, dart_tool_dir

def flutter_build_action(ctx, flutter_toolchain, working_dir, target, pub_cache_dir, dart_tool_dir):
    """Execute flutter build command for the specified target.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        target: Build target (web, apk, ios, etc.)
        pub_cache_dir: Pub cache directory from pub get
        dart_tool_dir: Dart tool directory from pub get

    Returns:
        Tuple of (build_output, build_artifacts_dir)
    """

    # Get the actual Flutter binary file object (first tool file)
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    # Create output files
    build_output = ctx.actions.declare_file(ctx.label.name + "_build.log")
    build_artifacts = ctx.actions.declare_directory(ctx.label.name + "_build_artifacts")

    # Map targets to Flutter build commands and output paths
    target_configs = {
        "web": {
            "command": "build web --release",
            "output_dir": "build/web",
        },
        "apk": {
            "command": "build apk --release",
            "output_dir": "build/app/outputs/flutter-apk",
        },
        "ios": {
            "command": "build ios --release --no-codesign",
            "output_dir": "build/ios/iphoneos",
        },
        "macos": {
            "command": "build macos --release",
            "output_dir": "build/macos/Build/Products/Release",
        },
        "linux": {
            "command": "build linux --release",
            "output_dir": "build/linux/x64/release/bundle",
        },
        "windows": {
            "command": "build windows --release",
            "output_dir": "build/windows/x64/runner/Release",
        },
    }

    config = target_configs.get(target, target_configs["web"])

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
DART_TOOL_DIR="{dart_tool_dir}"
FLUTTER_BIN="{flutter_bin}"
OUTPUT_LOG="{output_log}"
BUILD_ARTIFACTS="{build_artifacts}"
BUILD_COMMAND="{build_command}"
BUILD_OUTPUT_DIR="{build_output_dir}"
ORIGINAL_PWD="$PWD"

# Set up environment
export PUB_CACHE="$PUB_CACHE_DIR"

# Configure Flutter for sandbox environment
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export FLUTTER_ROOT="$ORIGINAL_PWD/external/+flutter+flutter_macos/flutter"
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Change to the workspace directory from execroot
cd "$ORIGINAL_PWD/$WORKSPACE_DIR"

# Copy .dart_tool tree to workspace
if [ -d "$DART_TOOL_DIR" ]; then
    mkdir -p .dart_tool
    cp -R "$DART_TOOL_DIR/." .dart_tool/
fi

# Run flutter build
echo "=== Flutter Build {target} ==="
echo "Working directory: $(pwd)"
echo "Flutter binary: $FLUTTER_BIN"
echo "Target: {target}"
echo ""

# Set absolute path to Flutter binary from execroot
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"

# Validate Flutter binary exists and is executable
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at: $FLUTTER_BIN_ABS"
    echo "Expected Flutter SDK to be available via toolchain"
    exit 1
fi

if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not executable at: $FLUTTER_BIN_ABS"
    echo "Check Flutter SDK permissions and installation"
    exit 1
fi

echo "Flutter binary verified at: $FLUTTER_BIN_ABS"
echo "Running: $FLUTTER_BIN_ABS {build_command}"

if "$FLUTTER_BIN_ABS" --suppress-analytics {build_command}; then
    echo "✓ flutter {build_command} completed successfully"
    
    # Copy build artifacts
    mkdir -p "$BUILD_ARTIFACTS"
    if [ -d "$BUILD_OUTPUT_DIR" ]; then
        cp -r "$BUILD_OUTPUT_DIR"/* "$BUILD_ARTIFACTS/" 2>/dev/null || echo "No files to copy from $BUILD_OUTPUT_DIR"
        echo "Build artifacts copied from $BUILD_OUTPUT_DIR"
        echo "Artifacts directory contents:"
        ls -la "$BUILD_ARTIFACTS" | head -10
    else
        echo "✗ FATAL ERROR: Expected build output directory $BUILD_OUTPUT_DIR not found"
        echo "Flutter build completed but did not create expected output directory"
        echo "This indicates a serious issue with Flutter build execution"
        exit 1
    fi
    
    echo "✓ Flutter build completed successfully"
else
    echo "✗ FATAL ERROR: flutter {build_command} failed"
    echo "Check your Flutter project configuration and dependencies"
    echo "Ensure all required dependencies are resolved via 'flutter pub get'"
    exit 1
fi
""".format(
        workspace_dir = working_dir.path,
        pub_cache_dir = pub_cache_dir.path,
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        output_log = build_output.path,
        build_artifacts = build_artifacts.path,
        build_command = config["command"],
        build_output_dir = config["output_dir"],
        target = target,
    )

    # Execute build
    ctx.actions.run_shell(
        inputs = [working_dir, pub_cache_dir, dart_tool_dir] + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
        outputs = [build_artifacts],
        command = script_content,
        mnemonic = "FlutterBuild",
        progress_message = "Running flutter build %s for %s" % (target, ctx.label.name),
    )

    # Create the log file separately using Bazel's write action
    ctx.actions.write(
        output = build_output,
        content = """Flutter build execution log
Target: {target}
Command: {build_command}
Status: Mock flutter build completed (toolchain integration in progress)
Artifacts: Build artifacts directory created
""".format(
            target = target,
            build_command = config["command"],
        ),
    )

    return build_output, build_artifacts

def flutter_test_action(ctx, flutter_toolchain, working_dir, test_files, pub_cache_dir, dart_tool_dir):
    """Execute flutter test command.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        test_files: List of test file patterns
        pub_cache_dir: Pub cache directory from pub get
        dart_tool_dir: Dart tool directory from pub get

    Returns:
        test_output: Test output file
    """

    # Get the actual Flutter binary file object (first tool file)
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    # Create output files
    test_output = ctx.actions.declare_file(ctx.label.name + "_test_results.log")

    # Prepare test file arguments
    test_args = ""
    if test_files and test_files != ["test/"]:
        test_args = " " + " ".join(test_files)

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="{workspace_dir}"
FLUTTER_BIN="{flutter_bin}"
OUTPUT_LOG="{output_log}"
TEST_ARGS="{test_args}"
ORIGINAL_PWD="$PWD"

# Set up environment from file paths
export PUB_CACHE="{pub_cache_dir}"

# Configure Flutter for sandbox environment
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export FLUTTER_ROOT="$ORIGINAL_PWD/external/+flutter+flutter_macos/flutter"
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Change to the workspace directory from execroot
cd "$ORIGINAL_PWD/$WORKSPACE_DIR"

# Copy .dart_tool tree to workspace
if [ -d "{dart_tool_dir}" ]; then
    mkdir -p .dart_tool
    cp -R "{dart_tool_dir}/." .dart_tool/
fi

# Run flutter test
echo "=== Flutter Test ==="
echo "Working directory: $(pwd)"
echo "Flutter binary: $FLUTTER_BIN"
echo "Test files/patterns: {test_patterns}"
echo ""

# Check if test directory exists
if [ ! -d "test" ]; then
    echo "Warning: No test directory found"
    echo "Available directories:"
    ls -la || true
    echo ""
fi

# Set absolute path to Flutter binary from execroot
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"

# Validate Flutter binary exists and is executable
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at: $FLUTTER_BIN_ABS"
    echo "Expected Flutter SDK to be available via toolchain"
    exit 1
fi

if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not executable at: $FLUTTER_BIN_ABS"
    echo "Check Flutter SDK permissions and installation"
    exit 1
fi

echo "Flutter binary verified at: $FLUTTER_BIN_ABS"
echo "Running: $FLUTTER_BIN_ABS test --suppress-analytics{test_args}"

if "$FLUTTER_BIN_ABS" test --suppress-analytics{test_args}; then
    echo "✓ flutter test completed successfully"
    echo "All tests passed"
else
    echo "✗ FATAL ERROR: flutter test failed"
    echo "One or more tests failed or Flutter test execution encountered an error"
    echo "Check your test files and dependencies"
    exit 1
fi
""".format(
        workspace_dir = working_dir.path,
        pub_cache_dir = pub_cache_dir.path,
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        output_log = test_output.path,
        test_args = test_args,
        test_patterns = ", ".join(test_files) if test_files else "all tests",
    )

    # Execute test and create output in one action
    ctx.actions.run_shell(
        inputs = [working_dir, pub_cache_dir, dart_tool_dir] + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
        outputs = [test_output],
        command = script_content + """

echo ""
echo "=== Creating Test Output Log ==="

# Go back to execution root to create test output
cd "$ORIGINAL_PWD"

# Create test output directory
mkdir -p "$(dirname "{test_output}")"

# Create comprehensive test execution log
echo "=== Flutter Test Results ===" > "{test_output}"
echo "Flutter binary: {flutter_bin}" >> "{test_output}"
echo "Working directory: $WORKSPACE_DIR" >> "{test_output}"
echo "Test patterns: {test_patterns}" >> "{test_output}"
echo "Execution time: $(date)" >> "{test_output}"
echo "" >> "{test_output}"
echo "✓ Real Flutter test execution completed successfully" >> "{test_output}"
echo "All tests passed via Flutter test framework" >> "{test_output}"
echo "" >> "{test_output}"
echo "Status: Real Flutter test execution completed" >> "{test_output}"

echo "Test output log created successfully"
""".format(
            test_output = test_output.path,
            flutter_bin = flutter_bin,
            test_patterns = ", ".join(test_files) if test_files else "all tests",
        ),
        mnemonic = "FlutterTest",
        progress_message = "Running flutter test for %s" % ctx.label.name,
    )

    return test_output
