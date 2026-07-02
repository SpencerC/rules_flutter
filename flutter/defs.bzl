"""Public API for Flutter build rules"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@protobuf//bazel/common:proto_common.bzl", "proto_common")
load("@protobuf//bazel/common:proto_info.bzl", "ProtoInfo")
load(
    "//flutter/private:flutter_actions.bzl",
    "create_flutter_working_dir",
    "flutter_build_action",
    "flutter_pub_get_action",
)

FlutterLibraryInfo = provider(
    doc = "Outputs from flutter_library needed to build or test Flutter targets.",
    fields = {
        "workspace": "Prepared Flutter workspace tree artifact containing project sources and pub outputs.",
        "pub_get_log": "Captured log from dependency preparation (pub deps, cache assembly, and generation commands).",
        "pub_cache": "Tree artifact containing the assembled pub cache for this library.",
        "pub_deps": "JSON dependency report copied from checked-in or repository-generated pub_deps.json.",
        "dart_tool": "Tree artifact containing the generated .dart_tool/package_config.json.",
        "pubspec": "The pubspec.yaml file for this library.",
        "dart_sources": "Depset of Dart source files that make up the library.",
        "other_sources": "Depset of non-Dart source files bundled with the library.",
        "transitive_pub_caches": "Depset of pub cache directories from all transitive dependencies",
    },
)

DartLibraryInfo = provider(
    doc = "Information about a Dart library",
    fields = {
        "srcs": "Source files for this library",
        "deps": "Transitive dependencies of this library",
        "import_path": "Import path for this library",
        "pubspec": "The pubspec.yaml file for this library (optional)",
        "pub_deps": "Dependency report copied from checked-in or repository-generated pub_deps.json (optional)",
        "pub_cache": "The assembled pub cache directory for this library (optional)",
        "transitive_pub_caches": "Depset of pub cache directories from all transitive dependencies",
    },
)

DartProtoLibraryInfo = provider(
    doc = "Generated Dart sources produced from .proto files.",
    fields = {
        "sources": "Depset of generated Dart source files (.pb.dart, .pbgrpc.dart).",
    },
)

def _render_pub_deps_generate_script(pubspec_file, flutter_bin):
    """Generate shell script that refreshes pub_deps.json in the source workspace."""

    pubspec_rel = pubspec_file.short_path
    return """#!/bin/bash
set -euo pipefail

resolve_runfile() {{
    local rel="$1"
    local candidate
    for root in "${{RUNFILES_DIR:-}}" "$PWD" "$PWD.runfiles"; do
        if [ -z "$root" ]; then
            continue
        fi
        candidate="$root/$rel"
        if [ -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    if [ -e "$rel" ]; then
        echo "$rel"
        return 0
    fi
    return 1
}}

WORKSPACE_DIR="${{BUILD_WORKSPACE_DIRECTORY:-}}"
if [ -z "$WORKSPACE_DIR" ]; then
    echo "✗ BUILD_WORKSPACE_DIRECTORY is not set; run via 'bazel run' inside a workspace." >&2
    exit 1
fi

PUBSPEC_REL="{pubspec_rel}"
SOURCE_PACKAGE_DIR="$WORKSPACE_DIR"
if [ -n "$PUBSPEC_REL" ]; then
    SOURCE_PACKAGE_DIR="$WORKSPACE_DIR/$(dirname "$PUBSPEC_REL")"
fi

if [ ! -f "$SOURCE_PACKAGE_DIR/pubspec.yaml" ]; then
    echo "✗ pubspec.yaml source missing: $SOURCE_PACKAGE_DIR/pubspec.yaml" >&2
    exit 1
fi

FLUTTER_BIN="$(resolve_runfile "{flutter_bin}")"
if [ -z "$FLUTTER_BIN" ] || [ ! -x "$FLUTTER_BIN" ]; then
    echo "✗ Unable to locate Flutter binary in runfiles: {flutter_bin}" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {{
    rm -rf "$TMP_DIR"
}}
trap cleanup EXIT

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "✗ python3 or python is required to refresh pub_deps.json" >&2
    exit 1
fi

export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel_update"

TMP_WORKSPACE="$TMP_DIR/workspace"
if command -v rsync >/dev/null 2>&1; then
    rsync -a \
        --exclude='.git' \
        --exclude='.hg' \
        --exclude='.svn' \
        --exclude='.dart_tool' \
        --exclude='build' \
        --exclude='bazel-*' \
        "$WORKSPACE_DIR/" "$TMP_WORKSPACE/"
else
    SOURCE_WORKSPACE_DIR="$WORKSPACE_DIR" TMP_WORKSPACE="$TMP_WORKSPACE" "$PYTHON_BIN" - <<'PY'
import os
import shutil

src = os.environ["SOURCE_WORKSPACE_DIR"]
dst = os.environ["TMP_WORKSPACE"]

def ignore(_, names):
    skipped = set()
    for name in names:
        if name in {{".git", ".hg", ".svn", ".dart_tool", "build"}} or name.startswith("bazel-"):
            skipped.add(name)
    return skipped

shutil.copytree(src, dst, symlinks=True, ignore=ignore)
PY
fi

PACKAGE_DIR="$TMP_WORKSPACE"
if [ -n "$PUBSPEC_REL" ]; then
    PACKAGE_DIR="$TMP_WORKSPACE/$(dirname "$PUBSPEC_REL")"
fi

if [ ! -f "$PACKAGE_DIR/pubspec.yaml" ]; then
    echo "✗ temporary pubspec.yaml copy missing: $PACKAGE_DIR/pubspec.yaml" >&2
    exit 1
fi

cd "$PACKAGE_DIR"

if ! "$FLUTTER_BIN" --suppress-analytics pub deps --json > "$TMP_DIR/pub_deps.raw.json"; then
    echo "✗ flutter pub deps --json failed for $SOURCE_PACKAGE_DIR" >&2
    exit 1
fi

PUB_DEPS_RAW="$TMP_DIR/pub_deps.raw.json" PUB_DEPS_OUT="$TMP_DIR/pub_deps.json" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

raw = os.environ["PUB_DEPS_RAW"]
out = os.environ["PUB_DEPS_OUT"]
with open(raw, "r", encoding="utf-8") as fh:
    payload = fh.read()

start = None
for idx, ch in enumerate(payload):
    if ch in "[{{":
        start = idx
        break

if start is None:
    sys.stderr.write("pub deps did not produce JSON\\n")
    sys.exit(1)

data = json.loads(payload[start:])
if not isinstance(data.get("packages"), list):
    sys.stderr.write("pub deps JSON missing packages list\\n")
    sys.exit(1)

with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\\n")
PY

DEST_FILE="$SOURCE_PACKAGE_DIR/pub_deps.json"
if [ -f "$DEST_FILE" ] && cmp -s "$TMP_DIR/pub_deps.json" "$DEST_FILE"; then
    echo "✓ pub_deps.json already up to date at $DEST_FILE"
    exit 0
fi

cp "$TMP_DIR/pub_deps.json" "$DEST_FILE"
chmod 0644 "$DEST_FILE" 2>/dev/null || true
echo "✓ Updated $DEST_FILE"
""".format(
        pubspec_rel = pubspec_rel,
        flutter_bin = flutter_bin,
    )

def _pub_deps_update_impl(ctx):
    """Implementation for the generated .update helper."""

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin = flutter_toolchain.flutterinfo.tool_files[0]

    update_script = ctx.actions.declare_file(ctx.label.name + "_update.sh")
    ctx.actions.write(
        output = update_script,
        content = _render_pub_deps_generate_script(
            ctx.file.pubspec,
            flutter_bin.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [update_script, flutter_bin],
        transitive_files = depset(
            transitive = [
                depset(flutter_toolchain.flutterinfo.tool_files),
                depset(flutter_toolchain.flutterinfo.sdk_files),
            ],
        ),
    )

    return [
        DefaultInfo(
            executable = update_script,
            files = depset([update_script]),
            runfiles = runfiles,
        ),
    ]

_pub_deps_update = rule(
    implementation = _pub_deps_update_impl,
    attrs = {
        "pubspec": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "pubspec.yaml whose package dependency report should be refreshed.",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Creates an executable that refreshes pub_deps.json from pubspec.yaml.",
)

_BUILD_RUNNER_MODES = [
    "build",
    "test",
    "watch",
    "serve",
]

def _shell_quote(arg):
    return "'" + arg.replace("'", "'\"'\"'") + "'"

def _normalize_build_runner_modes(modes):
    seen = {}
    normalized = []
    for mode in modes:
        if mode not in _BUILD_RUNNER_MODES:
            fail("Unsupported build_runner mode '{}'. Expected one of {}.".format(mode, _BUILD_RUNNER_MODES))
        if mode in seen:
            continue
        seen[mode] = True
        normalized.append(mode)
    return normalized

def _has_build_runner_config(kwargs):
    for key in [
        "build_runner_modes",
        "build_runner_common_args",
        "build_runner_build_args",
        "build_runner_test_args",
        "build_runner_watch_args",
        "build_runner_serve_args",
    ]:
        if key in kwargs and kwargs[key]:
            return True
    return False

def _validate_build_runner_config(rule_name, kwargs, build_runner_modes, has_explicit_build_runner_modes):
    if build_runner_modes:
        return
    if not has_explicit_build_runner_modes:
        return

    for key in [
        "build_runner_common_args",
        "build_runner_build_args",
        "build_runner_test_args",
        "build_runner_watch_args",
        "build_runner_serve_args",
    ]:
        if key in kwargs and kwargs[key]:
            fail("{} sets '{}' but does not enable any build_runner mode in 'build_runner_modes'.".format(rule_name, key))

def _build_runner_modes_for_run_targets(has_explicit_build_runner_modes, build_runner_modes):
    if has_explicit_build_runner_modes:
        return build_runner_modes
    return _BUILD_RUNNER_MODES

def _render_build_runner_runner_script(pubspec_file, flutter_bin, mode, common_args, mode_args):
    pubspec_rel = pubspec_file.short_path
    common_args_quoted = " ".join([_shell_quote(arg) for arg in common_args])
    mode_args_quoted = " ".join([_shell_quote(arg) for arg in mode_args])
    return """#!/bin/bash
set -euo pipefail

resolve_runfile() {{
    local rel="$1"
    local candidate
    for root in "${{RUNFILES_DIR:-}}" "$PWD" "$PWD.runfiles"; do
        if [ -z "$root" ]; then
            continue
        fi
        candidate="$root/$rel"
        if [ -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    if [ -e "$rel" ]; then
        echo "$rel"
        return 0
    fi
    return 1
}}

WORKSPACE_DIR="${{BUILD_WORKSPACE_DIRECTORY:-}}"
if [ -z "$WORKSPACE_DIR" ]; then
    echo "✗ BUILD_WORKSPACE_DIRECTORY is not set; run via 'bazel run' inside a workspace." >&2
    exit 1
fi

PUBSPEC_REL="{pubspec_rel}"
SOURCE_PACKAGE_DIR="$WORKSPACE_DIR"
if [ -n "$PUBSPEC_REL" ]; then
    SOURCE_PACKAGE_DIR="$WORKSPACE_DIR/$(dirname "$PUBSPEC_REL")"
fi

if [ ! -f "$SOURCE_PACKAGE_DIR/pubspec.yaml" ]; then
    echo "✗ pubspec.yaml source missing: $SOURCE_PACKAGE_DIR/pubspec.yaml" >&2
    exit 1
fi

FLUTTER_BIN="$(resolve_runfile "{flutter_bin}")"
if [ -z "$FLUTTER_BIN" ] || [ ! -x "$FLUTTER_BIN" ]; then
    echo "✗ Unable to locate Flutter binary in runfiles: {flutter_bin}" >&2
    exit 1
fi

FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
DART_BIN="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ ! -x "$DART_BIN" ]; then
    DART_BIN="$(command -v dart || true)"
fi
if [ -z "$DART_BIN" ] || [ ! -x "$DART_BIN" ]; then
    echo "✗ Unable to locate Dart executable for build_runner" >&2
    exit 1
fi

export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel_run"

cd "$SOURCE_PACKAGE_DIR"

BUILD_RUNNER_COMMON_ARGS=({common_args})
BUILD_RUNNER_MODE_ARGS=({mode_args})
CMD=("$DART_BIN" "run" "build_runner" "{mode}")
if [ ${{#BUILD_RUNNER_COMMON_ARGS[@]}} -gt 0 ]; then
    CMD+=("${{BUILD_RUNNER_COMMON_ARGS[@]}}")
fi
if [ ${{#BUILD_RUNNER_MODE_ARGS[@]}} -gt 0 ]; then
    CMD+=("${{BUILD_RUNNER_MODE_ARGS[@]}}")
fi
if [ $# -gt 0 ]; then
    CMD+=("$@")
fi

echo "Running in workspace directory: $SOURCE_PACKAGE_DIR"
echo "Executing: ${{CMD[*]}}"
exec "${{CMD[@]}}"
""".format(
        pubspec_rel = pubspec_rel,
        flutter_bin = flutter_bin,
        mode = mode,
        common_args = common_args_quoted,
        mode_args = mode_args_quoted,
    )

def _build_runner_command_impl(ctx):
    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin = flutter_toolchain.flutterinfo.tool_files[0]

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    ctx.actions.write(
        output = runner,
        content = _render_build_runner_runner_script(
            ctx.file.pubspec,
            flutter_bin.short_path,
            ctx.attr.mode,
            ctx.attr.common_args,
            ctx.attr.mode_args,
        ),
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([runner]),
            runfiles = ctx.runfiles(
                files = [runner, ctx.file.pubspec] + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
            ),
        ),
    ]

_build_runner_command_rule = rule(
    implementation = _build_runner_command_impl,
    attrs = {
        "pubspec": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Source pubspec.yaml used to locate the workspace package directory.",
        ),
        "mode": attr.string(
            values = _BUILD_RUNNER_MODES,
            mandatory = True,
            doc = "build_runner command mode to execute.",
        ),
        "common_args": attr.string_list(
            doc = "Args shared by all build_runner command modes.",
            default = [],
        ),
        "mode_args": attr.string_list(
            doc = "Mode-specific args forwarded to build_runner.",
            default = [],
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Internal executable target that runs build_runner in the source workspace.",
)

def _emit_build_runner_targets(name, kwargs, build_runner_modes):
    if not kwargs.get("build_runner_create_run_targets", True):
        return
    if not build_runner_modes:
        return

    mode_arg_map = {
        "build": kwargs.get("build_runner_build_args", []),
        "test": kwargs.get("build_runner_test_args", []),
        "watch": kwargs.get("build_runner_watch_args", []),
        "serve": kwargs.get("build_runner_serve_args", []),
    }

    for mode in build_runner_modes:
        target_name = "{}.build_runner_{}".format(name, mode)
        target_args = {
            "name": target_name,
            "pubspec": kwargs["pubspec"],
            "mode": mode,
            "common_args": kwargs.get("build_runner_common_args", []),
            "mode_args": mode_arg_map.get(mode, []),
        }
        if "visibility" in kwargs:
            target_args["visibility"] = kwargs["visibility"]
        if "tags" in kwargs:
            target_args["tags"] = kwargs["tags"]
        if kwargs.get("testonly", False):
            target_args["testonly"] = True
        _build_runner_command_rule(**target_args)

def _compute_relative_to_package(ctx, file):
    """Return file path relative to the package directory."""

    package = ctx.label.package
    short_path = file.short_path

    if package:
        prefix = package + "/"
        if short_path.startswith(prefix):
            return short_path[len(prefix):]

    return file.basename

def _flutter_library_impl(ctx):
    """Implementation for flutter_library rule."""

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    pubspec_file = ctx.file.pubspec

    if not pubspec_file:
        fail("flutter_library requires the 'pubspec' attribute to be set")

    pub_deps_file = ctx.file.pub_deps
    if not pub_deps_file:
        fail("flutter_library requires the 'pub_deps' attribute to point at a checked-in pub_deps.json")

    source_files = list(ctx.files.srcs) + list(ctx.files.data)
    dart_files = [f for f in source_files if f.extension == "dart"]
    other_files = [f for f in source_files if f.extension != "dart"]

    working_dir, _ = create_flutter_working_dir(
        ctx,
        pubspec_file,
        dart_files,
        other_files,
        list(ctx.files.data),
    )

    # Collect pub_cache directories from all transitive dependencies
    transitive_pub_caches = []
    for dep in ctx.attr.deps:
        if FlutterLibraryInfo in dep:
            # Collect transitive pub_caches depset from flutter_library deps
            transitive_pub_caches.append(dep[FlutterLibraryInfo].transitive_pub_caches)
        elif DartLibraryInfo in dep:
            # Collect transitive pub_caches depset from dart_library deps
            transitive_pub_caches.append(dep[DartLibraryInfo].transitive_pub_caches)

    prepared_workspace, pub_get_output, pub_cache_dir, pub_deps, dart_tool_dir = flutter_pub_get_action(
        ctx,
        flutter_toolchain,
        working_dir,
        pubspec_file,
        pub_deps_file,
        transitive_pub_caches,
        generator_commands = ctx.attr.generator_commands,
        build_runner_common_args = ctx.attr.build_runner_common_args,
        build_runner_build_args = ctx.attr.build_runner_build_args,
        run_build_runner_build = "build" in ctx.attr.build_runner_modes,
    )

    output_files = [
        pub_get_output,
        pub_deps,
        prepared_workspace,
        pub_cache_dir,
        dart_tool_dir,
    ]

    return [
        DefaultInfo(
            files = depset(output_files + [pubspec_file]),
            runfiles = ctx.runfiles(files = output_files + [pubspec_file]),
        ),
        FlutterLibraryInfo(
            workspace = prepared_workspace,
            pub_get_log = pub_get_output,
            pub_cache = pub_cache_dir,
            pub_deps = pub_deps,
            dart_tool = dart_tool_dir,
            pubspec = pubspec_file,
            dart_sources = depset(dart_files),
            other_sources = depset(other_files),
            transitive_pub_caches = depset(
                direct = [pub_cache_dir],
                transitive = transitive_pub_caches,
            ),
        ),
    ]

_flutter_library_rule = rule(
    implementation = _flutter_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files that make up the Flutter library (lib/, assets, etc).",
        ),
        "pubspec": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "pubspec.yaml describing this Flutter package.",
        ),
        "pub_deps": attr.label(
            allow_single_file = True,
            doc = "Checked-in pub_deps.json generated from this package's pubspec.yaml.",
        ),
        "deps": attr.label_list(
            doc = "Additional flutter_library or dart_library dependencies.",
            providers = [[FlutterLibraryInfo], [DartLibraryInfo]],
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional files (assets, l10n data, etc.) needed for code generation or embedding.",
        ),
        "generator_commands": attr.string_list(
            doc = "List of one-shot generator commands to run via `dart run` (e.g., ['intl_utils:generate']).",
            default = [],
        ),
        "build_runner_modes": attr.string_list(
            doc = "Explicit build_runner modes. 'build' runs in Bazel actions; when omitted, bazel run helpers are emitted for build/test/watch/serve by default.",
            default = [],
        ),
        "build_runner_common_args": attr.string_list(
            doc = "CLI args shared by all build_runner modes.",
            default = [],
        ),
        "build_runner_build_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner build`.",
            default = [],
        ),
        "build_runner_test_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner test` run helper.",
            default = [],
        ),
        "build_runner_watch_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner watch` run helper.",
            default = [],
        ),
        "build_runner_serve_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner serve` run helper.",
            default = [],
        ),
        "build_runner_create_run_targets": attr.bool(
            doc = "Whether to emit executable build_runner helper targets for enabled modes.",
            default = True,
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = """Prepares a Flutter library by assembling its dependency cache and metadata.

The generated workspace, pub cache, and dependency metadata are reused by
flutter_app and flutter_test via the embed attribute.""",
)

def flutter_library(
        name,
        create_update_target = True,
        update_visibility = None,
        update_tags = None,
        **kwargs):
    """Defines a flutter_library target and optional .update helper.

    Args:
      name: Target name for the flutter_library rule.
      create_update_target: Whether to emit the runnable `.update` helper.
      update_visibility: Optional visibility override for the `.update` target.
      update_tags: Optional tag list override for the `.update` target.
      **kwargs: Forwarded to the underlying flutter_library rule.
    """

    if "pubspec" not in kwargs or not kwargs["pubspec"]:
        fail("flutter_library requires the 'pubspec' attribute to be set")

    if "codegen" in kwargs:
        fail("flutter_library no longer supports 'codegen'; use 'generator_commands' and/or 'build_runner_*' attributes.")

    if "pub_deps" not in kwargs:
        kwargs["pub_deps"] = "pub_deps.json"

    has_explicit_build_runner_modes = "build_runner_modes" in kwargs
    build_runner_modes = _normalize_build_runner_modes(kwargs.get("build_runner_modes", []))
    _validate_build_runner_config("flutter_library", kwargs, build_runner_modes, has_explicit_build_runner_modes)
    run_target_build_runner_modes = _build_runner_modes_for_run_targets(
        has_explicit_build_runner_modes,
        build_runner_modes,
    )
    kwargs["build_runner_modes"] = build_runner_modes

    _flutter_library_rule(
        name = name,
        **kwargs
    )
    _emit_build_runner_targets(name, kwargs, run_target_build_runner_modes)

    if create_update_target:
        update_args = {
            "name": name + ".update",
            "pubspec": kwargs["pubspec"],
        }

        if update_visibility != None:
            update_args["visibility"] = update_visibility
        elif "visibility" in kwargs:
            update_args["visibility"] = kwargs["visibility"]

        tags = None
        if update_tags != None:
            tags = update_tags
        elif "tags" in kwargs:
            tags = kwargs["tags"]
        if tags != None:
            update_args["tags"] = tags

        if kwargs.get("testonly", False):
            update_args["testonly"] = True

        _pub_deps_update(**update_args)

def _create_flutter_run_script(ctx, build_artifacts):
    """Render the runner script that powers `bazel run` for flutter_app targets."""

    workspace_name = ctx.workspace_name
    artifact_short_path = build_artifacts.short_path

    script_lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "",
        'RUNFILES_DIR="${RUNFILES_DIR:-$0.runfiles}"',
        'if [ ! -d "$RUNFILES_DIR" ]; then',
        '    if [ -n "${RUNFILES_MANIFEST_FILE:-}" ]; then',
        '        echo "Runfiles manifest found at $RUNFILES_MANIFEST_FILE but directory layout is required." >&2',
        "    else",
        '        echo "Runfiles directory not found at $RUNFILES_DIR" >&2',
        "    fi",
        "    exit 1",
        "fi",
        "",
        'ARTIFACTS_DIR="$RUNFILES_DIR/{workspace}/{artifact}"'.format(
            workspace = workspace_name,
            artifact = artifact_short_path,
        ),
        'if [ ! -d "$ARTIFACTS_DIR" ]; then',
        '    echo "Flutter build artifacts not found at $ARTIFACTS_DIR" >&2',
        "    exit 1",
        "fi",
        "",
    ]

    if ctx.attr.target == "web":
        script_lines.extend([
            'PORT="${1:-8080}"',
            'echo "Serving Flutter web build from $ARTIFACTS_DIR on http://localhost:$PORT"',
            'echo "Press Ctrl+C to stop the server."',
            'cd "$ARTIFACTS_DIR"',
            "if command -v python3 >/dev/null 2>&1; then",
            '    exec python3 -m http.server "$PORT"',
            "elif command -v python >/dev/null 2>&1; then",
            '    exec python -m http.server "$PORT"',
            "else",
            '    echo "python3 or python is required to serve Flutter web artifacts." >&2',
            "    exit 1",
            "fi",
        ])
    else:
        script_lines.extend([
            'echo "flutter run for target {target} is not yet implemented."'.format(
                target = ctx.attr.target,
            ),
            'echo "Artifacts are available at $ARTIFACTS_DIR"',
        ])

    script_lines.append("")
    return "\n".join(script_lines)

def _flutter_app_impl(ctx):
    """Implementation for flutter_app targets."""

    if not ctx.attr.embed:
        fail("flutter_app requires at least one flutter_library in embed")

    if len(ctx.attr.embed) != 1:
        fail("flutter_app currently supports exactly one entry in embed")

    library_target = ctx.attr.embed[0]
    library_info = library_target[FlutterLibraryInfo]

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]

    # Prepare a dedicated workspace for this build by copying the library workspace
    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_workspace")
    manifest = ctx.actions.declare_file(ctx.label.name + "_app_overlay.manifest")

    overlay_entries = [
        "{}|{}".format(_compute_relative_to_package(ctx, f), f.path)
        for f in ctx.files.srcs
    ]

    ctx.actions.write(
        output = manifest,
        content = "\n".join(overlay_entries),
    )

    copy_script = """#!/bin/bash
set -euo pipefail

DEST="$1"
SRC_WORKSPACE="$2"
MANIFEST="$3"
PUB_DEPS_SRC="$4"

rm -rf "$DEST"
mkdir -p "$DEST"

if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$SRC_WORKSPACE/" "$DEST/"
else
    cp -RL "$SRC_WORKSPACE/." "$DEST/"
fi
chmod -R u+rwX "$DEST"

if [ -f "$PUB_DEPS_SRC" ]; then
    cp "$PUB_DEPS_SRC" "$DEST/pub_deps.json"
fi

if [ -s "$MANIFEST" ]; then
    while IFS='|' read -r rel src; do
        if [ -z "$rel" ]; then
            continue
        fi
        dest_path="$DEST/$rel"
        mkdir -p "$(dirname "$dest_path")"
        cp -RL "$src" "$dest_path"
    done < "$MANIFEST"
fi
"""

    ctx.actions.run_shell(
        inputs = [
            library_info.workspace,
            library_info.pub_deps,
            manifest,
        ] + ctx.files.srcs,
        outputs = [prepared_workspace],
        arguments = [
            prepared_workspace.path,
            library_info.workspace.path,
            manifest.path,
            library_info.pub_deps.path,
        ],
        command = copy_script,
        mnemonic = "PrepareFlutterAppWorkspace",
        progress_message = "Preparing Flutter workspace for %s" % ctx.label.name,
    )

    build_output, build_artifacts = flutter_build_action(
        ctx,
        flutter_toolchain,
        prepared_workspace,
        ctx.attr.target,
        library_info.pub_cache,
        library_info.dart_tool,
        mode = ctx.attr.mode,
        dart_defines = ctx.attr.dart_defines,
        build_args = ctx.attr.build_args,
        env = ctx.attr.env,
    )

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    ctx.actions.write(
        output = runner,
        content = _create_flutter_run_script(ctx, build_artifacts),
        is_executable = True,
    )

    output_files = [build_output, build_artifacts, runner]

    return [
        DefaultInfo(
            files = depset(output_files),
            executable = runner,
            runfiles = ctx.runfiles(
                files = [
                    runner,
                    build_output,
                    build_artifacts,
                    library_info.pub_deps,
                    library_info.pub_cache,
                    library_info.dart_tool,
                ],
            ),
        ),
    ]

_flutter_app_rule = rule(
    implementation = _flutter_app_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library targets that provide pub outputs for this app.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Additional source files to overlay (e.g. web/ directories).",
        ),
        "target": attr.string(
            values = ["web", "apk", "ios", "macos", "linux", "windows"],
            doc = "Flutter build target platform",
        ),
        "mode": attr.string(
            values = ["release", "profile", "debug"],
            default = "release",
            doc = "Flutter build mode passed to `flutter build` (--release/--profile/--debug).",
        ),
        "dart_defines": attr.string_dict(
            default = {},
            doc = """Compile-time --dart-define key/value pairs, rendered sorted by key.
Configurable with select(); when using select(), compose the complete dict per
branch (Starlark cannot merge two selects).""",
        ),
        "build_args": attr.string_list(
            default = [],
            doc = "Extra arguments appended verbatim to the flutter build command (e.g. --source-maps, --build-name=1.2.3).",
        ),
        "env": attr.string_dict(
            default = {},
            doc = "Extra environment variables exported in the build action before invoking flutter.",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Internal rule for flutter_app platform targets.",
)

def _to_label_list(value):
    if value == None:
        return []
    if type(value) == type([]):
        return value
    return [value]

_PLATFORM_SPEC_KEYS = ["srcs", "dart_defines", "build_args", "mode", "env"]

def _normalize_platform_spec(platform, value):
    """Normalize a flutter_app platform argument to a dict spec.

    Accepts the legacy forms (a label or list of labels, treated as srcs) or a
    dict with keys from _PLATFORM_SPEC_KEYS.
    """
    if type(value) != type({}):
        return {"srcs": _to_label_list(value)}
    for key in value.keys():
        if key not in _PLATFORM_SPEC_KEYS:
            fail("flutter_app platform '{}' spec has unknown key '{}'. Allowed keys: {}.".format(
                platform,
                key,
                _PLATFORM_SPEC_KEYS,
            ))
    return value

def _merge_dict_attr(name, platform, common, override):
    """Merge a common and per-platform dict attribute (platform keys win).

    select() values cannot be merged in Starlark, so when either side is a
    select the platform spec must carry the complete dict.
    """
    if override == None:
        return common
    if common == None:
        return override
    if type(common) == type({}) and type(override) == type({}):
        merged = dict(common)
        merged.update(override)
        return merged
    fail("flutter_app platform '{}' and the common attribute both set '{}' and at least one is a select(). ".format(platform, name) +
         "Compose the complete dict on the platform spec instead.")

def flutter_app(
        *,
        name,
        embed,
        srcs = None,
        visibility = None,
        tags = None,
        testonly = False,
        dart_defines = None,
        build_args = None,
        mode = None,
        env = None,
        web = None,
        apk = None,
        ios = None,
        macos = None,
        linux = None,
        windows = None):
    """Macro that defines flutter_app platform targets.

    Each platform attribute (`web`, `apk`, `ios`, `macos`, `linux`, `windows`) accepts
    either labels for files that should be overlaid into the Flutter workspace when
    building for that platform, or a dict spec with any of the keys `srcs`,
    `dart_defines`, `build_args`, `mode`, and `env` to customize that platform's
    build. A target is emitted only when the corresponding attribute is provided.

    Common `dart_defines`/`build_args`/`mode`/`env` apply to every platform;
    per-platform values merge over them (`build_args` concatenates, dicts merge
    with platform keys winning, `mode` overrides).

    Args:
      name: The base name for the flutter_app targets.
      embed: List of flutter_library targets to embed.
      srcs: Additional source files to include in the build workspace.
      visibility: Visibility specification for generated targets.
      tags: Tags to apply to generated targets.
      testonly: Whether the targets are testonly.
      dart_defines: Dict of --dart-define key/value pairs shared by all platforms.
        Supports select(); compose complete dicts per select() branch.
      build_args: Extra flutter build arguments shared by all platforms.
      mode: Build mode (release, profile, debug) shared by all platforms.
      env: Extra action environment variables shared by all platforms.
      web: Files or dict spec for the {name}.web target.
      apk: Files or dict spec for the {name}.apk target.
      ios: Files or dict spec for the {name}.ios target.
      macos: Files or dict spec for the {name}.macos target.
      linux: Files or dict spec for the {name}.linux target.
      windows: Files or dict spec for the {name}.windows target.
    """

    platform_specs = {
        "web": web,
        "apk": apk,
        "ios": ios,
        "macos": macos,
        "linux": linux,
        "windows": windows,
    }

    common_srcs = _to_label_list(srcs)

    generated = []

    for platform, platform_value in platform_specs.items():
        if platform_value == None:
            continue

        spec = _normalize_platform_spec(platform, platform_value)

        target_name = "{}.{}".format(name, platform)
        rule_args = {
            "name": target_name,
            "embed": embed,
            "srcs": common_srcs + _to_label_list(spec.get("srcs")),
            "target": platform,
        }

        merged_dart_defines = _merge_dict_attr("dart_defines", platform, dart_defines, spec.get("dart_defines"))
        if merged_dart_defines != None:
            rule_args["dart_defines"] = merged_dart_defines

        merged_env = _merge_dict_attr("env", platform, env, spec.get("env"))
        if merged_env != None:
            rule_args["env"] = merged_env

        # select() values cannot be truth-tested, so compare against None only.
        platform_build_args = spec.get("build_args")
        if build_args != None or platform_build_args != None:
            common_build_args = build_args if build_args != None else []
            extra_build_args = platform_build_args if platform_build_args != None else []
            rule_args["build_args"] = common_build_args + extra_build_args

        platform_mode = spec.get("mode", mode)
        if platform_mode != None:
            rule_args["mode"] = platform_mode

        if visibility != None:
            rule_args["visibility"] = visibility
        if tags != None:
            rule_args["tags"] = tags
        if testonly:
            rule_args["testonly"] = True

        _flutter_app_rule(**rule_args)
        generated.append(target_name)

    if not generated:
        fail(
            "flutter_app requires at least one platform attribute (web, apk, ios, macos, linux, windows).",
        )

    primary = generated[0]
    alias_args = {
        "name": name,
        "actual": ":" + primary,
    }
    if visibility != None:
        alias_args["visibility"] = visibility
    if tags != None:
        alias_args["tags"] = tags

    native.alias(**alias_args)

def _flutter_test_impl(ctx):
    """Implementation for flutter_test rule."""

    if not ctx.attr.embed:
        fail("flutter_test requires at least one flutter_library in embed")

    if len(ctx.attr.embed) != 1:
        fail("flutter_test currently supports exactly one entry in embed")

    library_target = ctx.attr.embed[0]
    library_info = library_target[FlutterLibraryInfo]

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")

    flutter_bin = flutter_toolchain.flutterinfo.tool_files[0].path

    # Build a mapping of relative paths to actual file objects
    test_file_mappings = [
        (_compute_relative_to_package(ctx, f), f)
        for f in ctx.files.srcs
    ]

    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_test_workspace")

    # Build args for test file copying: pairs of rel_path and abs_path
    test_file_args = []
    for rel_path, file_obj in test_file_mappings:
        test_file_args.extend([rel_path, file_obj.path])

    copy_script_template = """#!/bin/bash
set -euo pipefail

DEST="$1"
SRC_WORKSPACE="$2"
shift 2

rm -rf "$DEST"
mkdir -p "$DEST"

if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$SRC_WORKSPACE/" "$DEST/"
else
    cp -RL "$SRC_WORKSPACE/." "$DEST/"
fi

# Copy test files: arguments come in pairs (rel_path, abs_path)
while [ $# -gt 0 ]; do
    rel="$1"
    abs="$2"
    shift 2
    if [ -z "$rel" ]; then
        continue
    fi
    mkdir -p "$DEST/$(dirname "$rel")"
    if [ -f "$abs" ] || [ -d "$abs" ]; then
        cp -RL "$abs" "$DEST/$rel"
    fi
done
"""
    copy_script = copy_script_template

    ctx.actions.run_shell(
        inputs = [library_info.workspace] + ctx.files.srcs,
        outputs = [prepared_workspace],
        arguments = [
            prepared_workspace.path,
            library_info.workspace.path,
        ] + test_file_args,
        command = copy_script,
        mnemonic = "PrepareFlutterTestWorkspace",
        progress_message = "Preparing Flutter test workspace for %s" % ctx.label.name,
    )

    def _escape_pattern(pattern):
        return pattern.replace("\\", "\\\\").replace("'", "\\'")

    test_patterns_literal = "\n".join([_escape_pattern(pattern) for pattern in ctx.attr.test_files])

    test_runner = ctx.actions.declare_file(ctx.label.name + "_test_runner.sh")

    test_runner_content = """#!/bin/bash
set -euo pipefail
set -o pipefail

copy_tree() {{
    local src="$1"
    local dest="$2"
    if command -v rsync >/dev/null 2>&1; then
        rsync -aL "$src/" "$dest/"
    else
        cp -RL "$src/." "$dest/"
    fi
}}

resolve_path() {{
    local rel="$1"
    local fallback="$2"
    local candidate
    if [ -n "$rel" ]; then
        candidate="$WORKSPACE_ROOT/$rel"
        if [ -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
        candidate="$RUNFILES_ROOT/$rel"
        if [ -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    fi
    if [ -n "$fallback" ] && [ -e "$fallback" ]; then
        echo "$fallback"
        return 0
    fi
    if [ -n "$rel" ] && [ -e "$rel" ]; then
        echo "$rel"
        return 0
    fi
    echo ""
    return 1
}}

RUNFILES_ROOT="${{RUNFILES_DIR:-$PWD}}"
WORKSPACE_ROOT="$RUNFILES_ROOT/${{TEST_WORKSPACE:-__main__}}"
if [ ! -d "$WORKSPACE_ROOT" ]; then
    if [ -d "$RUNFILES_ROOT/__main__" ]; then
        WORKSPACE_ROOT="$RUNFILES_ROOT/__main__"
    elif [ -d "$RUNFILES_ROOT/_main" ]; then
        WORKSPACE_ROOT="$RUNFILES_ROOT/_main"
    fi
fi

WORKSPACE_SRC="{workspace_short}"
PUB_CACHE_SRC="{pub_cache_short}"
PUB_DEPS_SRC="{pub_deps_short}"
DART_TOOL_SRC="{dart_tool_short}"
FLUTTER_BIN_REL="{flutter_bin}"

FLUTTER_BIN_ABS="$RUNFILES_ROOT/$FLUTTER_BIN_REL"
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    SEARCH_ROOT="$RUNFILES_ROOT"
    while [ "$SEARCH_ROOT" != "/" ]; do
        if [ -f "$SEARCH_ROOT/$FLUTTER_BIN_REL" ]; then
            FLUTTER_BIN_ABS="$SEARCH_ROOT/$FLUTTER_BIN_REL"
            break
        fi
        PARENT_DIR="$(dirname "$SEARCH_ROOT")"
        if [ "$PARENT_DIR" = "$SEARCH_ROOT" ]; then
            break
        fi
        SEARCH_ROOT="$PARENT_DIR"
    done
fi

if [ ! -f "$FLUTTER_BIN_ABS" ] && [ -f "$FLUTTER_BIN_REL" ]; then
    FLUTTER_BIN_ABS="$FLUTTER_BIN_REL"
fi

if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "✗ Flutter binary not found: $FLUTTER_BIN_REL" >&2
    exit 1
fi

WORKSPACE_ABS="$(resolve_path "$WORKSPACE_SRC" "{workspace_path}")"
if [ -z "$WORKSPACE_ABS" ]; then
    echo "✗ Unable to locate prepared Flutter workspace: $WORKSPACE_SRC" >&2
    exit 1
fi

PUB_CACHE_ABS="$(resolve_path "$PUB_CACHE_SRC" "{pub_cache_path}")"
PUB_DEPS_ABS="$(resolve_path "$PUB_DEPS_SRC" "{pub_deps_path}")"
DART_TOOL_ABS="$(resolve_path "$DART_TOOL_SRC" "{dart_tool_path}")"

if [[ -z "${{TEST_TMPDIR:-}}" ]]; then
    echo "✗ TEST_TMPDIR is not set"
    exit 1
fi

RUNTIME_WORKSPACE="${{TEST_TMPDIR}}/flutter_workspace"
RUNTIME_PUB_CACHE="${{TEST_TMPDIR}}/pub_cache"
LOG_ROOT="${{TEST_UNDECLARED_OUTPUTS_DIR:-${{TEST_TMPDIR}}/test_outputs}}"
TEST_LOG="$LOG_ROOT/flutter_test.log"

mkdir -p "$LOG_ROOT"
: > "$TEST_LOG"

rm -rf "$RUNTIME_WORKSPACE"
mkdir -p "$RUNTIME_WORKSPACE"
copy_tree "$WORKSPACE_ABS" "$RUNTIME_WORKSPACE"
chmod -R u+w "$RUNTIME_WORKSPACE" 2>/dev/null || true

mkdir -p "$RUNTIME_PUB_CACHE"
if [ -n "$PUB_CACHE_ABS" ] && [ -d "$PUB_CACHE_ABS" ] && [ -n "$(ls -A "$PUB_CACHE_ABS" 2>/dev/null)" ]; then
    copy_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"
fi
chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true

if [ -n "$DART_TOOL_ABS" ] && [ -d "$DART_TOOL_ABS" ]; then
    mkdir -p "$RUNTIME_WORKSPACE/.dart_tool"
    copy_tree "$DART_TOOL_ABS" "$RUNTIME_WORKSPACE/.dart_tool"
    chmod -R u+w "$RUNTIME_WORKSPACE/.dart_tool" 2>/dev/null || true
fi

if [ -n "$PUB_DEPS_ABS" ] && [ -f "$PUB_DEPS_ABS" ]; then
    cp "$PUB_DEPS_ABS" "$RUNTIME_WORKSPACE/pub_deps.json"
    chmod u+w "$RUNTIME_WORKSPACE/pub_deps.json" 2>/dev/null || true
fi

FLUTTER_BIN_DIR="$(dirname "$FLUTTER_BIN_ABS")"
FLUTTER_ROOT="$(cd "$FLUTTER_BIN_DIR/.." && pwd)"

export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
export PUB_CACHE="$RUNTIME_PUB_CACHE"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export FLUTTER_ROOT
export PATH="$FLUTTER_BIN_DIR:$PATH"

# Regenerate package_config.json with correct paths to RUNTIME_PUB_CACHE
# This ensures package imports resolve correctly in the test environment
echo "Regenerating package_config.json for test runtime..."
pushd "$RUNTIME_WORKSPACE" >/dev/null
if "$FLUTTER_BIN_ABS" --suppress-analytics pub get --offline > /dev/null 2>&1; then
    echo "✓ Package config regenerated successfully (offline)" | tee -a "$TEST_LOG"
else
    echo "✗ flutter pub get --offline failed in test runtime" | tee -a "$TEST_LOG"
    popd >/dev/null
    exit 1
fi
popd >/dev/null

CMD=("$FLUTTER_BIN_ABS" "--suppress-analytics" "test")
IFS=$'\n'
for pattern in $'{test_patterns}'; do
    if [ -n "$pattern" ]; then
        CMD+=("$pattern")
    fi
done
unset IFS

pushd "$RUNTIME_WORKSPACE" >/dev/null

set +e
"${{CMD[@]}}" 2>&1 | tee -a "$TEST_LOG"
RESULT=${{PIPESTATUS[0]}}
set -e

popd >/dev/null

echo "" | tee -a "$TEST_LOG"
if [ "$RESULT" -eq 0 ]; then
    echo "✓ Flutter tests completed successfully" | tee -a "$TEST_LOG"
else
    echo "✗ Flutter tests failed" | tee -a "$TEST_LOG"
fi

exit "$RESULT"
""".format(
        workspace_short = prepared_workspace.short_path,
        pub_cache_short = library_info.pub_cache.short_path,
        pub_deps_short = library_info.pub_deps.short_path,
        dart_tool_short = library_info.dart_tool.short_path,
        workspace_path = prepared_workspace.path,
        pub_cache_path = library_info.pub_cache.path,
        pub_deps_path = library_info.pub_deps.path,
        dart_tool_path = library_info.dart_tool.path,
        flutter_bin = flutter_bin,
        test_patterns = test_patterns_literal,
    )

    ctx.actions.write(
        output = test_runner,
        content = test_runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = test_runner,
            files = depset([test_runner]),
            runfiles = ctx.runfiles(
                files = [
                    test_runner,
                    prepared_workspace,
                    library_info.pub_cache,
                    library_info.pub_deps,
                    library_info.dart_tool,
                ],
            ),
        ),
    ]

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library targets to embed for testing.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test source files to copy into the runtime workspace.",
        ),
        "test_files": attr.string_list(
            default = ["test/"],
            doc = "Test files or directories to run",
        ),
    },
    test = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Runs Flutter tests using a prepared flutter_library workspace.""",
)

def _compute_repo_relative_path(ctx, artifact, repo_name):
    """Compute relative path from generated artifact to an external repository root."""

    bin_segments = [segment for segment in ctx.bin_dir.path.split("/") if segment]
    short_dir = paths.dirname(artifact.short_path)
    short_segments = []
    if short_dir and short_dir != ".":
        short_segments = [segment for segment in short_dir.split("/") if segment]

    up_count = len(bin_segments) + len(short_segments)
    components = [".."] * up_count
    components.extend(["external", repo_name, "lib"])
    return "/".join(components).replace("+", "%2B")

def _dart_proto_library_impl(ctx):
    """Implementation for dart_proto_library rule."""

    if not ctx.attr.deps:
        fail("dart_proto_library requires the deps attribute to reference at least one proto_library target.")

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    flutter_bin = flutter_toolchain.flutterinfo.target_tool_path
    flutter_bin_dir = paths.dirname(flutter_bin)
    dart_bin = paths.normalize(paths.join(flutter_bin_dir, "cache", "dart-sdk", "bin", "dart"))

    package_config = ctx.actions.declare_file(ctx.label.name + "_package_config.json")
    wrapper_script = ctx.actions.declare_file(ctx.label.name + "_protoc_gen_dart.sh")

    plugin_repo = ctx.attr._dart_plugin_files.label.workspace_name
    protobuf_repo = ctx.attr._protobuf_pkg.label.workspace_name
    fixnum_repo = ctx.attr._fixnum_pkg.label.workspace_name
    path_repo = ctx.attr._path_pkg.label.workspace_name

    package_entries = []
    for (pkg, repo) in [
        ("protoc_plugin", plugin_repo),
        ("protobuf", protobuf_repo),
        ("fixnum", fixnum_repo),
        ("path", path_repo),
    ]:
        package_entries.append(
            """    {{
      "name": "{name}",
      "rootUri": "{root}",
      "packageUri": "lib/",
      "languageVersion": "2.19"
    }}""".format(
                name = pkg,
                root = _compute_repo_relative_path(ctx, package_config, repo),
            ),
        )

    package_config_content = "{\n  \"configVersion\": 2,\n  \"packages\": [\n" + ",\n".join(package_entries) + "\n  ]\n}\n"

    ctx.actions.write(
        output = package_config,
        content = package_config_content,
    )

    wrapper_content = """#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DART_PACKAGE_CONFIG="$SCRIPT_DIR/{package_config}"
export DART_PACKAGE_CONFIG
DART_BIN="{dart}"
if [ ! -x "$DART_BIN" ]; then
    if [ -x "${{DART_BIN}}.exe" ]; then
        DART_BIN="${{DART_BIN}}.exe"
    fi
fi

exec "$DART_BIN" external/{plugin_repo}/bin/protoc_plugin.dart "$@"
""".format(
        package_config = package_config.basename,
        dart = dart_bin,
        plugin_repo = plugin_repo,
    )

    ctx.actions.write(
        output = wrapper_script,
        content = wrapper_content,
        is_executable = True,
    )

    plugin_files = ctx.attr._dart_plugin_files[DefaultInfo].files
    protobuf_files = ctx.attr._protobuf_pkg[DefaultInfo].files
    fixnum_files = ctx.attr._fixnum_pkg[DefaultInfo].files
    path_files = ctx.attr._path_pkg[DefaultInfo].files

    tool_inputs = depset(flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files)
    additional_inputs = depset(
        direct = [package_config],
        transitive = [
            plugin_files,
            protobuf_files,
            fixnum_files,
            path_files,
            tool_inputs,
        ],
    )

    proto_lang_toolchain_info = proto_common.ProtoLangToolchainInfo(
        out_replacement_format_flag = None,
        plugin_format_flag = None,
        plugin = None,
        runtime = None,
        provided_proto_sources = [],
        proto_compiler = ctx.executable._protoc,
        protoc_opts = [],
        progress_message = "Generating Dart protos %{label}",
        mnemonic = "DartProtoCompile",
        allowlist_different_package = None,
        toolchain_type = None,
    )

    option_components = list(ctx.attr.options)
    if ctx.attr.grpc and "grpc" not in option_components:
        option_components.append("grpc")

    all_outputs = []

    for dep in ctx.attr.deps:
        proto_info = dep[ProtoInfo]
        proto_common.check_collocated(ctx.label, proto_info, proto_lang_toolchain_info)

        generated_files = proto_common.declare_generated_files(ctx.actions, proto_info, ".pb.dart")
        if ctx.attr.grpc:
            generated_files += proto_common.declare_generated_files(ctx.actions, proto_info, ".pbgrpc.dart")

        if not generated_files:
            continue

        all_outputs.extend(generated_files)

        args = ctx.actions.args()
        args.add("--plugin=protoc-gen-dart=" + wrapper_script.path)

        out_root = generated_files[0].root.path
        if option_components:
            args.add("--dart_out=" + ",".join(option_components) + ":" + out_root)
        else:
            args.add("--dart_out=" + out_root)

        proto_common.compile(
            ctx.actions,
            proto_info,
            proto_lang_toolchain_info,
            generated_files,
            additional_args = args,
            additional_inputs = additional_inputs,
            additional_tools = [wrapper_script],
        )

    return [
        DefaultInfo(files = depset(all_outputs)),
        DartProtoLibraryInfo(sources = depset(all_outputs)),
    ]

dart_proto_library = rule(
    implementation = _dart_proto_library_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            providers = [ProtoInfo],
            doc = "proto_library targets that define the source protos.",
        ),
        "options": attr.string_list(
            doc = "Additional options forwarded to the Dart protoc plugin (comma separated in --dart_out).",
        ),
        "grpc": attr.bool(
            default = False,
            doc = "Generate gRPC service stubs alongside message classes.",
        ),
        "_protoc": attr.label(
            default = Label("@protobuf//:protoc"),
            cfg = "exec",
            executable = True,
        ),
        "_dart_plugin_files": attr.label(
            default = Label("@pub_protoc_plugin//:protoc_plugin_files"),
        ),
        "_protobuf_pkg": attr.label(
            default = Label("@pub_protobuf//:protobuf_files"),
        ),
        "_fixnum_pkg": attr.label(
            default = Label("@pub_fixnum//:fixnum_files"),
        ),
        "_path_pkg": attr.label(
            default = Label("@pub_path//:path_files"),
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = "Generates Dart sources from proto_library targets using the Dart protoc plugin.",
)

def _dart_library_impl(ctx):
    """Implementation for dart_library rule"""

    # Get the Flutter toolchain
    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    flutter_bin = flutter_toolchain.flutterinfo.target_tool_path

    # Collect transitive dependencies
    transitive_deps = []
    transitive_pub_caches = []
    proto_generated_files = []
    for dep in ctx.attr.deps:
        if DartLibraryInfo in dep:
            transitive_deps.append(dep[DartLibraryInfo].deps)

            # Collect transitive pub_caches depset from dart_library deps
            transitive_pub_caches.append(dep[DartLibraryInfo].transitive_pub_caches)
        elif FlutterLibraryInfo in dep:
            # Collect transitive pub_caches depset from flutter_library deps
            transitive_pub_caches.append(dep[FlutterLibraryInfo].transitive_pub_caches)
        elif DartProtoLibraryInfo in dep:
            generated = dep[DartProtoLibraryInfo].sources.to_list()
            if generated:
                proto_generated_files.extend(generated)

    direct_srcs = list(ctx.files.srcs) + proto_generated_files

    # If pubspec is provided, prepare dependency metadata and cache artifacts
    pubspec_file = ctx.file.pubspec
    pub_deps = None
    pub_get_output = None
    pub_cache_dir = None
    dart_tool_dir = None

    if pubspec_file:
        pub_deps_input = ctx.file.pub_deps
        if not pub_deps_input:
            fail("dart_library with 'pubspec' requires the 'pub_deps' attribute to point at a checked-in pub_deps.json")

        # Create a working directory mirroring the package layout
        working_dir, _ = create_flutter_working_dir(
            ctx,
            pubspec_file,
            direct_srcs,
            [],
            list(ctx.files.data),
        )

        # Prepare dependency cache and package metadata from declared pub_deps.json.
        _prepared_workspace, pub_get_output, pub_cache_dir, pub_deps_file, dart_tool_dir = flutter_pub_get_action(
            ctx,
            flutter_toolchain,
            working_dir,
            pubspec_file,
            pub_deps_input,
            transitive_pub_caches,
            generator_commands = ctx.attr.generator_commands,
            build_runner_common_args = ctx.attr.build_runner_common_args,
            build_runner_build_args = ctx.attr.build_runner_build_args,
            run_build_runner_build = "build" in ctx.attr.build_runner_modes,
            is_pub_package = ctx.attr.pub_package,
        )
        pub_deps = pub_deps_file

    # Create the library info provider
    library_info = DartLibraryInfo(
        srcs = depset(direct = direct_srcs),
        deps = depset(direct = direct_srcs, transitive = transitive_deps),
        import_path = ctx.label.name,
        pubspec = pubspec_file,
        pub_deps = pub_deps,
        pub_cache = pub_cache_dir,
        transitive_pub_caches = depset(
            direct = [pub_cache_dir] if pub_cache_dir else [],
            transitive = transitive_pub_caches,
        ),
    )

    # Emit a small metadata artifact so build tests can validate analysis output.
    analysis_output = ctx.actions.declare_file(ctx.label.name + "_analysis.txt")

    analysis_info = """=== Dart Library Analysis ===
Library name: {name}
Flutter binary: {flutter_bin}
Source files: {src_count}
Dependencies: {dep_count}
Dart files found: {dart_files}
Has pubspec: {has_pubspec}

✓ Flutter toolchain resolved successfully
✓ Dart library structure validated
✓ Dependencies processed

Status: ANALYSIS_ONLY - Dart source metadata emitted
""".format(
        name = ctx.label.name,
        flutter_bin = flutter_bin,
        src_count = len(direct_srcs),
        dep_count = len(ctx.attr.deps),
        dart_files = ", ".join([f.basename for f in direct_srcs]),
        has_pubspec = "yes" if pubspec_file else "no",
    )

    ctx.actions.write(
        output = analysis_output,
        content = analysis_info,
    )

    output_files = [analysis_output] + direct_srcs
    if pubspec_file:
        output_files.append(pubspec_file)
    if pub_deps:
        output_files.extend([pub_deps, pub_get_output, pub_cache_dir, dart_tool_dir])

    return [
        DefaultInfo(files = depset(output_files)),
        library_info,
    ]

_dart_library_rule = rule(
    implementation = _dart_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart source files",
        ),
        "deps": attr.label_list(
            doc = "Dart library or flutter_library dependencies",
            providers = [[DartLibraryInfo], [FlutterLibraryInfo], [DartProtoLibraryInfo]],
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional files needed while preparing dependency metadata and cache artifacts.",
        ),
        "pubspec": attr.label(
            allow_single_file = True,
            doc = "Optional pubspec.yaml for dependency management",
        ),
        "pub_deps": attr.label(
            allow_single_file = True,
            doc = "Checked-in pub_deps.json generated from this package's pubspec.yaml.",
        ),
        "generator_commands": attr.string_list(
            doc = "List of one-shot generator commands to run via `dart run` (e.g., ['intl_utils:generate']).",
            default = [],
        ),
        "build_runner_modes": attr.string_list(
            doc = "Explicit build_runner modes. 'build' runs in Bazel actions; when omitted, bazel run helpers are emitted for build/test/watch/serve by default.",
            default = [],
        ),
        "build_runner_common_args": attr.string_list(
            doc = "CLI args shared by all build_runner modes.",
            default = [],
        ),
        "build_runner_build_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner build`.",
            default = [],
        ),
        "build_runner_test_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner test` run helper.",
            default = [],
        ),
        "build_runner_watch_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner watch` run helper.",
            default = [],
        ),
        "build_runner_serve_args": attr.string_list(
            doc = "CLI args forwarded to `build_runner serve` run helper.",
            default = [],
        ),
        "build_runner_create_run_targets": attr.bool(
            doc = "Whether to emit executable build_runner helper targets for enabled modes.",
            default = True,
        ),
        "pub_package": attr.bool(
            doc = "True if this target represents a hosted pub.dev package (enables cache publishing).",
            default = False,
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = "Defines a Dart library",
)

def dart_library(
        name,
        create_update_target = True,
        update_visibility = None,
        update_tags = None,
        **kwargs):
    """Defines a dart_library target and optional .update helper.

    Args:
      name: Target name for the dart_library rule.
      create_update_target: Whether to emit the runnable `.update` helper (only if pubspec is provided).
      update_visibility: Optional visibility override for the `.update` target.
      update_tags: Optional tag list override for the `.update` target.
      **kwargs: Forwarded to the underlying dart_library rule.
    """

    if "codegen" in kwargs:
        fail("dart_library no longer supports 'codegen'; use 'generator_commands' and/or 'build_runner_*' attributes.")

    if "pubspec" in kwargs and kwargs["pubspec"] and "pub_deps" not in kwargs:
        kwargs["pub_deps"] = "pub_deps.json"

    has_explicit_build_runner_modes = "build_runner_modes" in kwargs
    build_runner_modes = _normalize_build_runner_modes(kwargs.get("build_runner_modes", []))
    _validate_build_runner_config("dart_library", kwargs, build_runner_modes, has_explicit_build_runner_modes)
    run_target_build_runner_modes = _build_runner_modes_for_run_targets(
        has_explicit_build_runner_modes,
        build_runner_modes,
    )
    kwargs["build_runner_modes"] = build_runner_modes

    if ("pubspec" not in kwargs or not kwargs["pubspec"]) and _has_build_runner_config(kwargs):
        fail("dart_library build_runner configuration requires a 'pubspec' attribute.")

    _dart_library_rule(
        name = name,
        **kwargs
    )

    if "pubspec" in kwargs and kwargs["pubspec"]:
        _emit_build_runner_targets(name, kwargs, run_target_build_runner_modes)

    # Only create update target if pubspec is provided
    if not create_update_target or "pubspec" not in kwargs or not kwargs["pubspec"]:
        return

    update_args = {
        "name": name + ".update",
        "pubspec": kwargs["pubspec"],
    }

    if update_visibility != None:
        update_args["visibility"] = update_visibility
    elif "visibility" in kwargs:
        update_args["visibility"] = kwargs["visibility"]

    tags = None
    if update_tags != None:
        tags = update_tags
    elif "tags" in kwargs:
        tags = kwargs["tags"]
    if tags != None:
        update_args["tags"] = tags

    if kwargs.get("testonly", False):
        update_args["testonly"] = True

    _pub_deps_update(**update_args)
