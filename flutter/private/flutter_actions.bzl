"""Flutter command execution actions for Bazel rules."""

def create_flutter_working_dir(ctx, pubspec_file, dart_files, other_files, data_files):
    """Create a working directory structure for Flutter commands.

    Args:
        ctx: The rule context
        pubspec_file: The pubspec.yaml file
        dart_files: List of .dart source files
        other_files: List of other source files declared in srcs
        data_files: List of additional data files that must be available in the workspace

    Returns:
        Tuple of (working_dir, input_files)
    """
    working_dir = ctx.actions.declare_directory(ctx.label.name + "_workspace_seed")

    # Build a manifest of files that should be available inside the workspace with
    # paths relative to the package root so code generation tools see the expected
    # project layout (e.g. lib/, test/, l10n/, web/).
    package = ctx.label.package
    package_prefix = package + "/" if package else ""

    workspace_entries = {}
    seen = {}

    def add_entry(file, rel_path = None):
        if file == None:
            return
        if file.path in seen:
            return
        seen[file.path] = True

        if rel_path == None:
            short_path = file.short_path
            if package_prefix and short_path.startswith(package_prefix):
                rel_path = short_path[len(package_prefix):]
            else:
                rel_path = file.basename

        workspace_entries[rel_path] = file

    add_entry(pubspec_file, "pubspec.yaml")

    for f in dart_files + other_files + data_files:
        add_entry(f)

    manifest = ctx.actions.declare_file(ctx.label.name + "_workspace_manifest.txt")
    manifest_content = []
    for rel_path in sorted(workspace_entries.keys()):
        file = workspace_entries[rel_path]
        manifest_content.append("{}|{}".format(rel_path, file.path))

    manifest_payload = "\n".join(manifest_content)
    if manifest_payload:
        manifest_payload += "\n"

    ctx.actions.write(
        output = manifest,
        content = manifest_payload,
    )

    workspace_script = ctx.actions.declare_file(ctx.label.name + "_setup_workspace.sh")
    ctx.actions.write(
        output = workspace_script,
        content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="$1"
MANIFEST_FILE="$2"

rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"

while IFS='|' read -r RELATIVE_PATH SOURCE_PATH; do
    if [ -z "$RELATIVE_PATH" ]; then
        continue
    fi
    DEST_PATH="$WORKSPACE_DIR/$RELATIVE_PATH"
    mkdir -p "$(dirname "$DEST_PATH")"
    cp -RL "$SOURCE_PATH" "$DEST_PATH"
done < "$MANIFEST_FILE"
""",
        is_executable = True,
    )

    # Collect unique input files for the action
    input_files = []
    seen_inputs = {}
    for f in [pubspec_file] + dart_files + other_files + data_files:
        if f == None:
            continue
        if f.path in seen_inputs:
            continue
        seen_inputs[f.path] = True
        input_files.append(f)

    # Run the workspace setup
    ctx.actions.run(
        inputs = input_files + [manifest],
        outputs = [working_dir],
        executable = workspace_script,
        arguments = [working_dir.path, manifest.path],
        mnemonic = "SetupFlutterWorkspace",
        progress_message = "Setting up Flutter workspace for %s" % ctx.label.name,
    )

    return working_dir, input_files

def flutter_pub_get_action(ctx, flutter_toolchain, working_dir, pubspec_file, dependency_pub_caches = [], codegen_commands = []):
    """Execute flutter pub get command and optional code generation.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        pubspec_file: The pubspec.yaml file
        dependency_pub_caches: List of pub_cache directories from dependencies (can contain Files or depsets)
        codegen_commands: List of code generation commands to run after pub get (e.g., ["intl_utils:generate"])

    Returns:
        Tuple of (pub_get_output, pub_cache_dir, pubspec_lock, dart_tool_dir)
    """

    # Get the actual Flutter binary file object (first tool file)
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    # Flatten dependency pub_caches: convert depsets to lists
    dep_pub_cache_files = []
    for item in dependency_pub_caches:
        if type(item) == "depset":
            dep_pub_cache_files.extend(item.to_list())
        else:
            dep_pub_cache_files.append(item)

    # Create output artifacts
    pub_get_output = ctx.actions.declare_file(ctx.label.name + "_pub_get.log")
    pub_cache_dir = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")
    pubspec_lock = ctx.actions.declare_file(ctx.label.name + "_pubspec.lock")
    dart_tool_dir = ctx.actions.declare_directory(ctx.label.name + "_dart_tool")
    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_prepared_flutter_workspace")

    # Build arguments for dependency pub_cache directories
    dep_pub_cache_args = []
    for dep_cache in dep_pub_cache_files:
        dep_pub_cache_args.append(dep_cache.path)

    # Enhanced script that properly executes flutter pub get and reports results
    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_SRC="{workspace_src}"
WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
FLUTTER_BIN="{flutter_bin}"
ORIGINAL_PWD="$PWD"
WORKSPACE_SRC_ABS="$ORIGINAL_PWD/$WORKSPACE_SRC"
WORKSPACE_DIR_ABS="$ORIGINAL_PWD/$WORKSPACE_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"

# Prepare the output workspace copy
rm -rf "$WORKSPACE_DIR_ABS"
mkdir -p "$WORKSPACE_DIR_ABS"
if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$WORKSPACE_SRC_ABS/" "$WORKSPACE_DIR_ABS/"
else
    cp -RL "$WORKSPACE_SRC_ABS/." "$WORKSPACE_DIR_ABS/"
fi
chmod -R u+rwX "$WORKSPACE_DIR_ABS"

# Set up pub cache directory from file path
export PUB_CACHE="$PUB_CACHE_DIR_ABS"
mkdir -p "$PUB_CACHE_DIR_ABS"

# Pre-populate pub cache from dependencies
echo "=== Pre-populating Pub Cache from Dependencies ==="
DEP_CACHES=({dep_caches})
if [ ${{#DEP_CACHES[@]}} -gt 0 ]; then
    for DEP_CACHE in "${{DEP_CACHES[@]}}"; do
        if [[ "$DEP_CACHE" != /* ]]; then
            DEP_CACHE="$ORIGINAL_PWD/$DEP_CACHE"
        fi
        if [ -d "$DEP_CACHE" ] && [ -n "$(ls -A "$DEP_CACHE" 2>/dev/null)" ]; then
            echo "Copying dependency pub_cache from: $DEP_CACHE"
            # Use rsync if available for better performance, otherwise use cp
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "$DEP_CACHE/" "$PUB_CACHE_DIR_ABS/"
            else
                cp -R "$DEP_CACHE/." "$PUB_CACHE_DIR_ABS/"
            fi
        fi
    done
else
    echo "No dependency pub_caches to pre-populate"
fi
echo "Pub cache pre-population complete"
echo ""

# Configure Flutter for sandbox environment  
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export FLUTTER_ROOT="$ORIGINAL_PWD/external/+flutter+flutter_macos/flutter"
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Change to the workspace directory from execroot
cd "$WORKSPACE_DIR_ABS"

echo "=== Flutter Pub Get Execution ==="
echo "Working directory: $(pwd)"
echo "Expected workspace dir: $WORKSPACE_DIR"
echo "Flutter binary: $FLUTTER_BIN"  
echo "Pub cache: $PUB_CACHE_DIR_ABS"
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
    if [ -n "$(ls -A "$PUB_CACHE_DIR_ABS" 2>/dev/null)" ]; then
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

# Run code generation if requested
CODEGEN_COMMANDS=({codegen_commands})
if [ ${{#CODEGEN_COMMANDS[@]}} -gt 0 ]; then
    echo ""
    echo "=== Running Code Generation ==="
    for CODEGEN_CMD in "${{CODEGEN_COMMANDS[@]}}"; do
        if [ -n "$CODEGEN_CMD" ]; then
            echo "Running: flutter pub run $CODEGEN_CMD"
            if "$FLUTTER_BIN_ABS" pub run "$CODEGEN_CMD"; then
                echo "✓ Code generation command '$CODEGEN_CMD' completed successfully"
            else
                echo "✗ FATAL ERROR: Code generation command '$CODEGEN_CMD' failed"
                exit 1
            fi
        fi
    done
    echo "✓ All code generation commands completed"
fi
""".format(
        workspace_src = working_dir.path,
        workspace_dir = prepared_workspace.path,
        pub_cache_dir = pub_cache_dir.path,
        flutter_bin = flutter_bin,
        dep_caches = " ".join(['"{}"'.format(path) for path in dep_pub_cache_args]),
        codegen_commands = " ".join(['"{}"'.format(cmd) for cmd in codegen_commands]),
        tool_files_count = len(flutter_toolchain.flutterinfo.tool_files),
        sdk_files_count = len(flutter_toolchain.flutterinfo.sdk_files),
        first_tool_file_path = flutter_bin_file.path if flutter_toolchain.flutterinfo.tool_files else "No tool files",
    )

    # Execute pub get and create all outputs in one action
    ctx.actions.run_shell(
        inputs = [working_dir, pubspec_file] + dep_pub_cache_files + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
        outputs = [pub_get_output, pubspec_lock, pub_cache_dir, dart_tool_dir, prepared_workspace],
        command = script_content + """

echo ""
echo "=== Creating Output Files ==="

# Go back to execution root
cd "$ORIGINAL_PWD"

# Create output directories
mkdir -p "$(dirname "{pub_get_output}")"
mkdir -p "$(dirname "{pubspec_lock}")"
mkdir -p "$PUB_CACHE_DIR_ABS"
mkdir -p "{dart_tool_dir}"

# Create the pub get log
echo "=== Flutter Pub Get Results ===" > "{pub_get_output}"
echo "Flutter binary: {flutter_bin}" >> "{pub_get_output}" 
echo "Working directory: $WORKSPACE_DIR" >> "{pub_get_output}"
echo "Execution time: $(date)" >> "{pub_get_output}"
echo "" >> "{pub_get_output}"

# Copy pubspec.lock from workspace (should always exist after successful pub get)
if [ -f "$WORKSPACE_DIR_ABS/pubspec.lock" ]; then
    echo "✓ Copying pubspec.lock from Flutter pub get" >> "{pub_get_output}"
    cp "$WORKSPACE_DIR_ABS/pubspec.lock" "{pubspec_lock}"
else
    echo "✗ FATAL ERROR: pubspec.lock not found after successful pub get" >> "{pub_get_output}"
    echo "This should never happen - Flutter pub get validation failed"
    exit 1
fi

# Copy entire .dart_tool directory
if [ -d "$WORKSPACE_DIR_ABS/.dart_tool" ]; then
    echo "✓ Copying .dart_tool directory from Flutter pub get" >> "{pub_get_output}"
    # Clean target dir first to avoid stale files
    rm -rf "{dart_tool_dir}"
    mkdir -p "{dart_tool_dir}"
    cp -R "$WORKSPACE_DIR_ABS/.dart_tool/." "{dart_tool_dir}/"
else
    echo "✗ FATAL ERROR: .dart_tool directory not found after successful pub get" >> "{pub_get_output}"
    echo "This should never happen - Flutter pub get validation failed"
    exit 1
fi

# Sync PUB_CACHE directory to declared output directory
if [ -d "$PUB_CACHE_DIR_ABS" ] && [ -n "$(ls -A "$PUB_CACHE_DIR_ABS" 2>/dev/null)" ]; then
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

    return prepared_workspace, pub_get_output, pub_cache_dir, pubspec_lock, dart_tool_dir

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

# Convert relative paths to absolute before changing directories
BUILD_ARTIFACTS_ABS="$ORIGINAL_PWD/$BUILD_ARTIFACTS"
DART_TOOL_DIR_ABS="$ORIGINAL_PWD/$DART_TOOL_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"

# Set up environment
export PUB_CACHE="$PUB_CACHE_DIR_ABS"

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
if [ -d "$DART_TOOL_DIR_ABS" ]; then
    mkdir -p .dart_tool
    cp -R "$DART_TOOL_DIR_ABS/." .dart_tool/
    chmod -R u+rwX .dart_tool
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

# Regenerate package_config.json with correct paths for this sandbox
# This ensures package imports resolve correctly in the build environment
echo ""
echo "Regenerating package_config.json for build environment..."
if "$FLUTTER_BIN_ABS" pub get --offline 2>&1 > /dev/null; then
    echo "✓ Package config regenerated successfully"
else
    # If offline fails, run normal pub get (packages should already be cached)
    echo "Offline pub get failed, running normal pub get..."
    if "$FLUTTER_BIN_ABS" pub get --suppress-analytics 2>&1 > /dev/null; then
        echo "✓ Package config regenerated successfully"
    else
        echo "Warning: Could not regenerate package_config.json"
    fi
fi
echo ""

echo "Running: $FLUTTER_BIN_ABS {build_command}"

if "$FLUTTER_BIN_ABS" --suppress-analytics {build_command}; then
    echo "✓ flutter {build_command} completed successfully"

    # Copy build artifacts to absolute path
    mkdir -p "$BUILD_ARTIFACTS_ABS"
    if [ -d "$BUILD_OUTPUT_DIR" ]; then
        echo "Copying from $BUILD_OUTPUT_DIR to $BUILD_ARTIFACTS_ABS"
        cp -r "$BUILD_OUTPUT_DIR"/* "$BUILD_ARTIFACTS_ABS/" 2>/dev/null || echo "No files to copy from $BUILD_OUTPUT_DIR"
        echo "Build artifacts copied from $BUILD_OUTPUT_DIR"
        echo "Artifacts directory contents:"
        ls -la "$BUILD_ARTIFACTS_ABS" | head -10
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
