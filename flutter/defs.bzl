"""Public API for Flutter build rules"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo", "string_flag")
load("@protobuf//bazel/common:proto_common.bzl", "proto_common")
load("@protobuf//bazel/common:proto_info.bzl", "ProtoInfo")
load(
    "//flutter/private:flutter_actions.bzl",
    "PACKAGE_CONFIG_FROM_PUB_DEPS_PY",
    "create_flutter_working_dir",
    "flutter_assemble_pub_cache_action",
    "flutter_build_action",
    "flutter_pub_get_action",
    "flutter_stage_pub_package_action",
    "tree_output_execution_requirements",
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
        "assembled_cache": "Whether pub_cache contains the full merged dependency closure (assemble_dep_caches). Only such libraries can be embedded.",
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
        "assembled_cache": "Whether pub_cache contains the full merged dependency closure (assemble_dep_caches). Only such libraries can be embedded.",
    },
)

# Hidden attrs giving rules access to the ruleset build settings:
# //flutter:allow_remote_execution (see heavy_action_execution_requirements),
# //flutter:remote_cache_trees (see tree_output_execution_requirements),
# and //flutter:build_runner_cache (opt-in build_runner incremental cache).
ALLOW_REMOTE_EXECUTION_ATTR = {
    "_allow_remote_execution": attr.label(
        default = Label("//flutter:allow_remote_execution"),
        providers = [BuildSettingInfo],
    ),
    "_build_runner_cache": attr.label(
        default = Label("//flutter:build_runner_cache"),
        providers = [BuildSettingInfo],
    ),
    "_remote_cache_trees": attr.label(
        default = Label("//flutter:remote_cache_trees"),
        providers = [BuildSettingInfo],
    ),
}

def _allow_remote_exec(ctx):
    return ctx.attr._allow_remote_execution[BuildSettingInfo].value

def _build_runner_cache(ctx):
    return ctx.attr._build_runner_cache[BuildSettingInfo].value

def _remote_cache_trees(ctx):
    return ctx.attr._remote_cache_trees[BuildSettingInfo].value

def _resolve_flutter_toolchain(ctx):
    """Return (toolchain, flutter_bin File) for the resolved Flutter toolchain.

    Fails with an actionable message when no toolchain is registered (or it
    carries no tool files), replacing the identical guard that was copied
    across every rule implementation.

    Args:
        ctx: the rule context.

    Returns:
        A tuple of (toolchain info, the flutter launcher File).
    """
    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("rules_flutter: no Flutter toolchain is registered (the resolved " +
             "toolchain has no tool files). Register one via the `flutter` module " +
             "extension and register_toolchains(\"@flutter_toolchains//:all\"). " +
             "See the README \"Registering a Flutter toolchain\" section.")
    return flutter_toolchain, flutter_toolchain.flutterinfo.tool_files[0]

def _test_execution_info(ctx):
    """ExecutionInfo for the flutter test rules (see allow_remote_execution).

    Rules exposing a `cpu` attr (flutter_test, flutter_analyze_test) can
    declare a local CPU reservation ("cpu:N") so Bazel's scheduler doesn't
    co-locate more internally-parallel flutter runs than the worker has cores
    for. 0 (default) declares nothing — the suites already overlap under the
    default 1-CPU estimate, and reserving cores where none are spare would
    only serialize them.
    """
    reqs = {} if _allow_remote_exec(ctx) else {"no-remote-exec": "1"}
    cpu = getattr(ctx.attr, "cpu", 0)
    if cpu > 0:
        reqs["cpu:%d" % cpu] = ""
    if not reqs:
        return []
    return [testing.ExecutionInfo(reqs)]

def _check_embeddable(ctx, library_target, library_info):
    """Fail at analysis when embedding a library without an assembled cache.

    Generated package targets set assemble_dep_caches = False, so their
    pub_cache carries only their own payload; embedding one would silently
    produce a runtime package config that drops every hosted dependency.
    """
    if not getattr(library_info, "assembled_cache", True):
        fail(
            "{}: embedded library '{}' sets assemble_dep_caches = False, so its pub cache ".format(ctx.label, library_target.label) +
            "does not contain its dependency closure. Embed a flutter_library/dart_library " +
            "that assembles its cache (the default) instead of a generated package target.",
        )

DartProtoLibraryInfo = provider(
    doc = "Generated Dart sources produced from .proto files.",
    fields = {
        "sources": """Depset of tree artifacts, one per proto_library in the
transitive closure, each laid out by proto import path (e.g.
`api/v1/service.pb.dart`). Mount them into a package workspace with the
`generated_srcs` attribute of flutter_library/dart_library.""",
    },
)

DartProtoAspectInfo = provider(
    doc = "Internal: per-proto_library Dart generation results, propagated along deps.",
    fields = {
        "trees": "Depset of tree artifacts laid out by proto import path.",
    },
)

def _maybe_stage_pub_package(ctx):
    """Stage a hosted pub package directly, bypassing the full prepare path.

    Returns the staged pub cache tree when this target is a hosted pub package
    that only needs its own payload made available (no dependency-cache
    assembly, no codegen) — collapsing its three near-identical per-package
    trees to one. Returns None otherwise (the target keeps the full path).
    """
    if (ctx.attr.pub_package and
        not ctx.attr.assemble_dep_caches and
        not ctx.attr.generator_commands and
        not ctx.attr.build_runner_modes and
        not ctx.attr.generated_srcs and
        ctx.attr.pub_payload):
        return flutter_stage_pub_package_action(
            ctx,
            ctx.files.pub_payload,
            allow_remote_exec = _allow_remote_exec(ctx),
        )
    return None

def _prepare_library_deps(ctx, flutter_toolchain, working_dir, pubspec_file, pub_deps_file, transitive_pub_caches):
    """Assemble the pub cache and prepare the workspace for a library target.

    When the library assembles a full dependency cache (and is not itself a
    republished pub package), the multi-tree merge runs in a separate
    FlutterAssemblePubCache action keyed only on the dependency caches, and the
    prepare/codegen action consumes it read-only — so a Dart edit re-runs
    codegen without re-merging hundreds of dependency trees. Pub-package
    targets and the (unusual) assemble+pub_package combination keep the
    single-action path.
    """
    allow_remote = _allow_remote_exec(ctx)
    cache_trees = _remote_cache_trees(ctx)
    use_preassembled = ctx.attr.assemble_dep_caches and not ctx.attr.pub_package

    preassembled_cache = None
    dep_caches = []
    if use_preassembled:
        preassembled_cache = flutter_assemble_pub_cache_action(
            ctx,
            transitive_pub_caches,
            allow_remote_exec = allow_remote,
            remote_cache_trees = cache_trees,
        )
    elif ctx.attr.assemble_dep_caches:
        dep_caches = transitive_pub_caches

    return flutter_pub_get_action(
        ctx,
        flutter_toolchain,
        working_dir,
        pubspec_file,
        pub_deps_file,
        dep_caches,
        generator_commands = ctx.attr.generator_commands,
        build_runner_common_args = ctx.attr.build_runner_common_args,
        build_runner_build_args = ctx.attr.build_runner_build_args,
        run_build_runner_build = "build" in ctx.attr.build_runner_modes,
        is_pub_package = ctx.attr.pub_package,
        allow_remote_exec = allow_remote,
        remote_cache_trees = cache_trees,
        preassembled_cache = preassembled_cache,
        build_runner_cache = _build_runner_cache(ctx),
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
# bash 3.2 (macOS /bin/bash) runs the EXIT trap with $?=0 after a `set -u`
# expansion error; the sentinel keeps such aborts from reporting success.
SCRIPT_COMPLETED=0
cleanup() {{
    rc=$?
    rm -rf "$TMP_DIR" || true
    if [ "$SCRIPT_COMPLETED" != 1 ] && [ "$rc" = 0 ]; then
        rc=1
    fi
    exit "$rc"
}}
trap cleanup EXIT

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "✗ python3 or python is required to refresh pub_deps.json" >&2
    exit 1
fi

export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
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

if ! "$FLUTTER_BIN" --suppress-analytics --no-version-check pub deps --json > "$TMP_DIR/pub_deps.raw.json"; then
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
    SCRIPT_COMPLETED=1
    exit 0
fi

cp "$TMP_DIR/pub_deps.json" "$DEST_FILE"
chmod 0644 "$DEST_FILE" 2>/dev/null || true
echo "✓ Updated $DEST_FILE"
SCRIPT_COMPLETED=1
""".format(
        pubspec_rel = pubspec_rel,
        flutter_bin = flutter_bin,
    )

def _pub_deps_update_impl(ctx):
    """Implementation for the generated .update helper."""

    flutter_toolchain, flutter_bin = _resolve_flutter_toolchain(ctx)

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

# Shared prologue for `bazel run` write-back helpers that operate on the
# source tree (format, goldens, sync). After it runs, the current directory is
# the package's source directory ($SOURCE_PACKAGE_DIR), and $FLUTTER_BIN,
# $DART_BIN, and $FLUTTER_ROOT point at the toolchain SDK.
_SOURCE_WORKSPACE_PROLOGUE = """#!/bin/bash
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

FLUTTER_BIN="$(resolve_runfile "{flutter_bin}")"
if [ -z "$FLUTTER_BIN" ] || [ ! -x "$FLUTTER_BIN" ]; then
    echo "✗ Unable to locate Flutter binary in runfiles: {flutter_bin}" >&2
    exit 1
fi
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
DART_BIN="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"

export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel_run"

cd "$SOURCE_PACKAGE_DIR"
"""

def _render_format_script(pubspec_file, flutter_bin):
    return _SOURCE_WORKSPACE_PROLOGUE.format(
        pubspec_rel = pubspec_file.short_path,
        flutter_bin = flutter_bin,
    ) + """
if [ $# -gt 0 ]; then
    exec "$DART_BIN" format "$@"
fi
exec "$DART_BIN" format .
"""

def _flutter_format_impl(ctx):
    flutter_toolchain, flutter_bin = _resolve_flutter_toolchain(ctx)

    runner = ctx.actions.declare_file(ctx.label.name + "_format.sh")
    ctx.actions.write(
        output = runner,
        content = _render_format_script(ctx.file.pubspec, flutter_bin.short_path),
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

_flutter_format_rule = rule(
    implementation = _flutter_format_impl,
    attrs = {
        "pubspec": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Source pubspec.yaml locating the package directory to format.",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Runs `dart format` (write-back) over the package's source directory.",
)

def _flutter_sync_impl(ctx):
    # Reuse the mounting semantics of generated_srcs: directory artifacts
    # (dart_proto_library trees) merge into the dest dir; files copy flat.
    entries = _generated_srcs_entries(ctx.attr.generated_srcs)
    trees = []
    manifest_lines = []
    dest_dirs = {}
    for rel, artifact in entries:
        kind = "dir" if artifact.is_directory else "file"
        if artifact.is_directory:
            dest_dirs[rel] = True
        manifest_lines.append("{}\t{}\t{}".format(kind, artifact.short_path, rel))
        trees.append(artifact)

    manifest = ctx.actions.declare_file(ctx.label.name + "_sync_manifest.txt")
    ctx.actions.write(manifest, "\n".join(manifest_lines) + "\n")

    runner = ctx.actions.declare_file(ctx.label.name + "_sync.sh")
    ctx.actions.write(
        output = runner,
        content = """#!/bin/bash
set -euo pipefail

resolve_runfile() {{
    local rel="$1"
    for root in "${{RUNFILES_DIR:-}}" "$PWD" "$PWD.runfiles"; do
        if [ -n "$root" ] && [ -e "$root/$rel" ]; then
            echo "$root/$rel"
            return 0
        fi
    done
    [ -e "$rel" ] && {{ echo "$rel"; return 0; }}
    return 1
}}

WORKSPACE_DIR="${{BUILD_WORKSPACE_DIRECTORY:-}}"
if [ -z "$WORKSPACE_DIR" ]; then
    echo "✗ BUILD_WORKSPACE_DIRECTORY is not set; run via 'bazel run' inside a workspace." >&2
    exit 1
fi

PACKAGE_DIR="$WORKSPACE_DIR/{package}"
MANIFEST="$(resolve_runfile "{manifest}")"
if [ -z "$MANIFEST" ]; then
    echo "✗ sync manifest not found in runfiles" >&2
    exit 1
fi

# Clear each destination directory so removed generated sources don't linger.
DEST_DIRS=({dest_dirs})
for D in "${{DEST_DIRS[@]}}"; do
    rm -rf "$PACKAGE_DIR/$D"
done

while IFS=$'\t' read -r KIND SRC_REL DEST_REL; do
    [ -z "$KIND" ] && continue
    SRC="$(resolve_runfile "$SRC_REL")"
    if [ -z "$SRC" ]; then
        echo "✗ generated source not found in runfiles: $SRC_REL" >&2
        exit 1
    fi
    DEST="$PACKAGE_DIR/$DEST_REL"
    if [ "$KIND" = "dir" ]; then
        mkdir -p "$DEST"
        # Trees overlap (shared well-known-type files) and arrive read-only;
        # make earlier copies writable before merging the next.
        find "$DEST" -type d ! -perm -200 -exec chmod u+w {{}} + 2>/dev/null || true
        if command -v rsync >/dev/null 2>&1; then
            rsync -aL "$SRC/" "$DEST/"
        else
            cp -RLf "$SRC/." "$DEST/"
        fi
    else
        mkdir -p "$(dirname "$DEST")"
        cp -Lf "$SRC" "$DEST"
    fi
done < "$MANIFEST"

# Generated sources are checked out read-only from bazel-bin; make the
# synced copies writable so the IDE/analyzer and later syncs can manage them.
for D in "${{DEST_DIRS[@]}}"; do
    chmod -R u+w "$PACKAGE_DIR/$D" 2>/dev/null || true
done

echo "✓ Synced generated sources into $PACKAGE_DIR"
""".format(
            package = ctx.label.package,
            manifest = manifest.short_path,
            dest_dirs = " ".join([_shell_quote(d) for d in sorted(dest_dirs.keys())]) if dest_dirs else "",
        ),
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([runner]),
            runfiles = ctx.runfiles(files = [runner, manifest] + trees),
        ),
    ]

_flutter_sync_rule = rule(
    implementation = _flutter_sync_impl,
    attrs = {
        "generated_srcs": attr.label_keyed_string_dict(
            allow_files = True,
            mandatory = True,
            doc = "Same mapping as flutter_library.generated_srcs; written back to the source tree.",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Writes generated_srcs (e.g. dart_proto_library outputs) back into the
source tree so the IDE analyzer sees them. Not needed by the hermetic build,
which mounts the same outputs into its sandbox automatically.""",
)

def _build_runner_command_impl(ctx):
    flutter_toolchain, flutter_bin = _resolve_flutter_toolchain(ctx)

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

def _forward_common_target_args(target_args, kwargs, visibility = None, tags = None):
    """Copy visibility/tags/testonly from a macro's kwargs onto a helper target."""
    if visibility != None:
        target_args["visibility"] = visibility
    elif "visibility" in kwargs:
        target_args["visibility"] = kwargs["visibility"]
    if tags != None:
        target_args["tags"] = tags
    elif "tags" in kwargs:
        target_args["tags"] = kwargs["tags"]
    if kwargs.get("testonly", False):
        target_args["testonly"] = True
    return target_args

def _emit_format_target(name, kwargs, create):
    """Emit the `{name}.format` write-back helper when a pubspec is present."""
    if not create:
        return
    if not kwargs.get("pubspec"):
        return
    _flutter_format_rule(**_forward_common_target_args(
        {"name": name + ".format", "pubspec": kwargs["pubspec"]},
        kwargs,
    ))

def _emit_sync_target(name, kwargs, create):
    """Emit the `{name}.sync` IDE write-back helper when generated_srcs is set."""
    if not create:
        return
    if not kwargs.get("generated_srcs"):
        return
    _flutter_sync_rule(**_forward_common_target_args(
        {"name": name + ".sync", "generated_srcs": kwargs["generated_srcs"]},
        kwargs,
    ))

def _compute_relative_to_package(ctx, file):
    """Return file path relative to the package directory."""

    package = ctx.label.package
    short_path = file.short_path

    if package:
        prefix = package + "/"
        if short_path.startswith(prefix):
            return short_path[len(prefix):]

    return file.basename

def _generated_srcs_entries(generated_srcs):
    """Expand a generated_srcs dict into explicit (rel_path, file) mounts.

    Directory artifacts (e.g. dart_proto_library outputs) are merged into the
    destination directory; regular files mount flat by basename.
    """
    entries = []
    for target, dest_dir in generated_srcs.items():
        dest = dest_dir.strip("/")
        if not dest:
            fail("generated_srcs destination for {} must be a non-empty package-relative directory".format(target.label))
        if DartProtoLibraryInfo in target:
            for tree in target[DartProtoLibraryInfo].sources.to_list():
                entries.append((dest, tree))
        else:
            for f in target[DefaultInfo].files.to_list():
                if f.is_directory:
                    entries.append((dest, f))
                else:
                    entries.append((dest + "/" + f.basename, f))
    return entries

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

    # Collect pub_cache directories from all transitive dependencies
    transitive_pub_caches = []
    for dep in ctx.attr.deps:
        if FlutterLibraryInfo in dep:
            # Collect transitive pub_caches depset from flutter_library deps
            transitive_pub_caches.append(dep[FlutterLibraryInfo].transitive_pub_caches)
        elif DartLibraryInfo in dep:
            # Collect transitive pub_caches depset from dart_library deps
            transitive_pub_caches.append(dep[DartLibraryInfo].transitive_pub_caches)

    # Hosted pub packages that need only their own payload staged skip the
    # workspace/codegen path entirely (one cheap action, one output tree).
    staged_cache = _maybe_stage_pub_package(ctx)
    if staged_cache != None:
        return [
            DefaultInfo(files = depset([staged_cache, pubspec_file])),
            FlutterLibraryInfo(
                workspace = None,
                pub_get_log = None,
                pub_cache = staged_cache,
                pub_deps = pub_deps_file,
                dart_tool = None,
                pubspec = pubspec_file,
                dart_sources = depset(dart_files),
                other_sources = depset(other_files),
                transitive_pub_caches = depset(
                    direct = [staged_cache],
                    transitive = transitive_pub_caches,
                ),
                assembled_cache = False,
            ),
        ]

    working_dir, _ = create_flutter_working_dir(
        ctx,
        pubspec_file,
        dart_files,
        other_files,
        list(ctx.files.data),
        extra_entries = _generated_srcs_entries(ctx.attr.generated_srcs),
        allow_remote_exec = _allow_remote_exec(ctx),
        remote_cache_trees = _remote_cache_trees(ctx),
    )

    prepared_workspace, pub_get_output, pub_cache_dir, pub_deps, dart_tool_dir = _prepare_library_deps(
        ctx,
        flutter_toolchain,
        working_dir,
        pubspec_file,
        pub_deps_file,
        transitive_pub_caches,
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
            assembled_cache = ctx.attr.assemble_dep_caches,
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
        "generated_srcs": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = """Targets whose outputs are mounted at an explicit package-relative
directory inside the Flutter workspace, e.g.
`{"//protos/api/v1:api_dart_proto": "lib/generated/protos"}`. dart_proto_library
targets mount each generated file at its proto-import-relative path under the
destination; other targets mount flat by basename.""",
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
        "pub_payload": attr.label(
            allow_files = True,
            doc = """For hosted pub-package targets: the package's own files (the
`_package_payload` filegroup). When set on a pub_package target with no
codegen, the package is staged directly into the offline cache by a single
cheap action instead of the full prepare/codegen path.""",
        ),
        "assemble_dep_caches": attr.bool(
            doc = """Whether to merge transitive dependency pub caches into this
library's own cache tree. Generated package repositories set this to False so
each package contributes only its own hosted payload — the full cache is
assembled once, by the top-level consumer, from the transitive depset —
instead of duplicating shared transitive packages at every level of the
dependency graph.""",
            default = True,
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Prepares a Flutter library by assembling its dependency cache and metadata.

The generated workspace, pub cache, and dependency metadata are reused by
flutter_app and flutter_test via the embed attribute.""",
)

_BUILD_MODES = ["debug", "profile", "release"]

def flutter_build_settings(
        name,
        mode_default = "release",
        build_number = True,
        visibility = None):
    """Emit the command-line build settings a release/multi-env app needs.

    flutter_app's `mode` and `build_number` are plain attributes meant to be
    driven by `select()` on user build settings. This macro creates the usual
    scaffolding so you don't hand-roll it:

    - `{name}_mode`: a string_flag over debug/profile/release (default
      `mode_default`), plus a `{name}_<mode>` config_setting for each mode.
    - `{name}_build_number`: a string_flag (default empty) when `build_number`
      is True, so a release wrapper can inject a version code on the command
      line instead of rewriting pubspec.yaml.

    Wire them into flutter_app, e.g.:

        flutter_app(
            name = "app",
            apk = {
                "srcs": [":android_srcs"],
                "mode": select({
                    ":settings_release": "release",
                    "//conditions:default": "debug",
                }),
                "build_number": ":settings_build_number",
                "android_sdk": "@androidsdk//:sdk_path",
            },
            ...
        )

    then build with `--//your/pkg:settings_mode=release
    --//your/pkg:settings_build_number=42`.

    Args:
      name: Prefix for the emitted targets (`{name}_mode`,
        `{name}_<mode>` config_settings, `{name}_build_number`).
      mode_default: Default build mode (debug/profile/release) for the mode flag.
      build_number: Whether to emit the `{name}_build_number` string_flag.
      visibility: Optional visibility applied to every emitted target.
    """
    if mode_default not in _BUILD_MODES:
        fail("flutter_build_settings mode_default must be one of {}".format(_BUILD_MODES))

    string_flag(
        name = name + "_mode",
        build_setting_default = mode_default,
        values = _BUILD_MODES,
        visibility = visibility,
    )
    for mode in _BUILD_MODES:
        native.config_setting(
            name = "{}_{}".format(name, mode),
            flag_values = {":{}_mode".format(name): mode},
            visibility = visibility,
        )
    if build_number:
        string_flag(
            name = name + "_build_number",
            build_setting_default = "",
            visibility = visibility,
        )

def flutter_library(
        name,
        create_update_target = True,
        create_format_target = True,
        create_sync_target = True,
        update_visibility = None,
        update_tags = None,
        **kwargs):
    """Defines a flutter_library target and optional .update/.format helpers.

    Args:
      name: Target name for the flutter_library rule.
      create_update_target: Whether to emit the runnable `.update` helper.
      create_format_target: Whether to emit the runnable `.format` helper
        (`dart format` write-back over the package source directory).
      create_sync_target: Whether to emit the runnable `.sync` helper, which
        writes generated_srcs (e.g. proto outputs) back into the source tree
        for the IDE analyzer. Only emitted when generated_srcs is set.
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
    _emit_format_target(name, kwargs, create_format_target)
    _emit_sync_target(name, kwargs, create_sync_target)

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

def _tree_root_path(files, attr_name, label):
    """Return the directory path a filegroup of SDK/NDK files is rooted at.

    Handles both a single directory artifact (e.g. @androidsdk//:sdk_path,
    whose srcs are ["."]) and plain file lists from an external repository.
    """
    if not files:
        fail("flutter_app '{}': attribute '{}' resolved to no files. ".format(label, attr_name) +
             "For rules_android/rules_android_ndk repositories this usually means " +
             "ANDROID_HOME/ANDROID_NDK_HOME was not set when the repository was fetched.")
    first = files[0]
    if len(files) == 1 and first.is_directory:
        return first.path
    parts = first.path.split("/")
    if parts[0] == "external" and len(parts) >= 2:
        return "external/" + parts[1]
    fail("flutter_app '{}': unable to derive a root directory for '{}' from {}".format(
        label,
        attr_name,
        first.path,
    ))

def _android_environment(ctx):
    """Assemble the Android build environment for apk/appbundle targets.

    The SDK/NDK come from ecosystem rulesets (rules_android's @androidsdk and
    rules_android_ndk's @androidndk wrap a host installation); JAVA_HOME comes
    from Bazel's java runtime toolchain (hermetic remote JDK).
    """
    if ctx.attr.target not in ["apk", "appbundle"]:
        return None

    if not ctx.attr.android_sdk:
        fail("flutter_app '{}' target '{}' requires the android_sdk attribute ".format(ctx.label, ctx.attr.target) +
             "(e.g. android_sdk = \"@androidsdk//:sdk_path\" from rules_android).")

    sdk_files = ctx.attr.android_sdk[DefaultInfo].files.to_list()
    sdk_path = _tree_root_path(sdk_files, "android_sdk", ctx.label)

    # The SDK/NDK trees wrap host installations via symlinks the sandbox
    # cannot stage; the Android action runs unsandboxed (it is declared
    # non-hermetic regardless), so they are path references, not inputs.
    ndk_path = None
    transitive = []
    if ctx.attr.android_ndk:
        ndk_files = ctx.attr.android_ndk[DefaultInfo].files.to_list()
        ndk_path = _tree_root_path(ndk_files, "android_ndk", ctx.label)

    java_toolchain = ctx.toolchains["@bazel_tools//tools/jdk:runtime_toolchain_type"]
    if java_toolchain == None:
        fail("flutter_app '{}': no java runtime toolchain resolved; Gradle needs a JDK.".format(ctx.label))
    java_runtime = java_toolchain.java_runtime
    transitive.append(java_runtime.files)

    return struct(
        sdk_path = sdk_path,
        ndk_path = ndk_path,
        java_home = java_runtime.java_home,
        files = depset(transitive = transitive),
    )

def _flutter_app_impl(ctx):
    """Implementation for flutter_app targets."""

    if not ctx.attr.embed:
        fail("flutter_app requires at least one flutter_library in embed")

    if len(ctx.attr.embed) != 1:
        fail("flutter_app currently supports exactly one entry in embed")

    library_target = ctx.attr.embed[0]
    library_info = library_target[FlutterLibraryInfo]
    _check_embeddable(ctx, library_target, library_info)

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]

    # Prepare a dedicated workspace for this build by copying the library workspace
    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_workspace")
    manifest = ctx.actions.declare_file(ctx.label.name + "_app_overlay.manifest")

    overlay_entries = [
        "{}|{}".format(_compute_relative_to_package(ctx, f), f.path)
        for f in ctx.files.srcs
    ]

    # Trailing newline matters: `while read` drops a final unterminated line.
    ctx.actions.write(
        output = manifest,
        content = "\n".join(overlay_entries) + "\n" if overlay_entries else "",
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

    android = _android_environment(ctx)

    build_args = list(ctx.attr.build_args)
    if ctx.attr.build_name:
        build_args.append("--build-name=" + ctx.attr.build_name)
    if ctx.attr.build_number:
        build_number = ctx.attr.build_number[BuildSettingInfo].value
        if build_number:
            build_args.append("--build-number=" + build_number)

    build_output, build_artifacts = flutter_build_action(
        ctx,
        flutter_toolchain,
        prepared_workspace,
        ctx.attr.target,
        library_info.pub_cache,
        library_info.dart_tool,
        mode = ctx.attr.mode,
        dart_defines = ctx.attr.dart_defines,
        build_args = build_args,
        env = ctx.attr.env,
        android = android,
        android_test = ctx.attr.android_test,
        allow_remote_exec = _allow_remote_exec(ctx),
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
            values = ["web", "apk", "appbundle", "ios", "macos", "linux", "windows"],
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
        "android_sdk": attr.label(
            allow_files = True,
            doc = """Android SDK directory for apk/appbundle targets, typically
rules_android's `@androidsdk//:sdk_path` (which wraps the host installation
discovered via ANDROID_HOME).""",
        ),
        "android_test": attr.bool(
            default = False,
            doc = """For apk targets: after the Flutter build, additionally run
Gradle's app:assembleAndroidTest and copy the instrumentation APK into
androidTest/ under the build artifacts — the two-APK layout Firebase Test
Lab's instrumentation testing expects.""",
        ),
        "build_name": attr.string(
            doc = "Overrides the pubspec version name (--build-name).",
        ),
        "build_number": attr.label(
            providers = [BuildSettingInfo],
            doc = """string_flag whose value (when non-empty) is passed as
--build-number, letting release wrappers inject e.g. the next Play Store
version code via --//app:android_build_number=N.""",
        ),
        "android_ndk": attr.label(
            allow_files = True,
            doc = """Optional Android NDK directory, typically from
rules_android_ndk's `@androidndk` (wrapping ANDROID_NDK_HOME); written to
local.properties as ndk.dir.""",
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    executable = True,
    toolchains = [
        "//flutter:toolchain_type",
        config_common.toolchain_type("@bazel_tools//tools/jdk:runtime_toolchain_type", mandatory = False),
    ],
    doc = "Internal rule for flutter_app platform targets.",
)

def _render_dev_server_script(pubspec_rel, flutter_bin, device, dart_defines, run_args):
    """Render the `bazel run` dev-server script (source-workspace execution)."""

    dart_define_args = " ".join([
        _shell_quote("--dart-define={}={}".format(key, dart_defines[key]))
        for key in sorted(dart_defines.keys())
    ])
    run_args_quoted = " ".join([_shell_quote(arg) for arg in run_args])

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

export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
export PUB_ENVIRONMENT="flutter_tool:bazel_run"

cd "$SOURCE_PACKAGE_DIR"

DART_DEFINE_ARGS=({dart_define_args})
RUN_ARGS=({run_args})
CMD=("$FLUTTER_BIN" "--suppress-analytics" "--no-version-check" "run" "-d" {device})
if [ ${{#DART_DEFINE_ARGS[@]}} -gt 0 ]; then
    CMD+=("${{DART_DEFINE_ARGS[@]}}")
fi
if [ ${{#RUN_ARGS[@]}} -gt 0 ]; then
    CMD+=("${{RUN_ARGS[@]}}")
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
        device = _shell_quote(device),
        dart_define_args = dart_define_args,
        run_args = run_args_quoted,
    )

def _flutter_dev_server_impl(ctx):
    """Implementation for the {name}.dev run helper."""

    library_info, _ = _single_embedded_library(ctx, "flutter_app dev server")

    flutter_toolchain, flutter_bin_file = _resolve_flutter_toolchain(ctx)

    runner = ctx.actions.declare_file(ctx.label.name + "_dev_runner.sh")
    ctx.actions.write(
        output = runner,
        content = _render_dev_server_script(
            library_info.pubspec.short_path,
            flutter_bin_file.short_path,
            ctx.attr.device,
            ctx.attr.dart_defines,
            ctx.attr.run_args,
        ),
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([runner]),
            runfiles = ctx.runfiles(
                files = [runner, library_info.pubspec] +
                        flutter_toolchain.flutterinfo.tool_files +
                        flutter_toolchain.flutterinfo.sdk_files,
            ),
        ),
    ]

_flutter_dev_server_rule = rule(
    implementation = _flutter_dev_server_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library whose source package the dev server runs in.",
        ),
        "device": attr.string(
            default = "web-server",
            doc = "Device id passed to flutter run -d.",
        ),
        "dart_defines": attr.string_dict(
            default = {},
            doc = "Compile-time --dart-define pairs (configurable via select()).",
        ),
        "run_args": attr.string_list(
            default = [],
            doc = "Extra args forwarded to flutter run (e.g. --web-port=8080).",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Runs `flutter run` in the SOURCE workspace with the hermetic SDK.

Unlike build actions this is a development helper: it uses the checked-out
sources (with hot reload) and the developer's package resolution, not the
prepared Bazel workspace.""",
)

def _to_label_list(value):
    if value == None:
        return []
    if type(value) == type([]):
        return value
    return [value]

_PLATFORM_SPEC_KEYS = ["srcs", "dart_defines", "build_args", "mode", "env", "android_sdk", "android_ndk", "android_test", "build_name", "build_number", "tags"]

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
        android_sdk = None,
        android_ndk = None,
        create_dev_target = True,
        dev_run_args = None,
        web = None,
        apk = None,
        appbundle = None,
        ios = None,
        macos = None,
        linux = None,
        windows = None):
    """Macro that defines flutter_app platform targets.

    Each platform attribute (`web`, `apk`, `ios`, `macos`, `linux`, `windows`) accepts
    either labels for files that should be overlaid into the Flutter workspace when
    building for that platform, or a dict spec with any of the keys `srcs`,
    `dart_defines`, `build_args`, `mode`, `env`, `android_sdk`, `android_ndk`,
    `android_test`, `build_name`, `build_number`, and `tags` to customize that
    platform's build. A target is emitted only when the corresponding attribute
    is provided. Spec `tags` extend the macro-level `tags` (e.g. to mark only
    the mobile platforms `manual`).

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
      android_sdk: Android SDK directory for apk/appbundle targets (e.g.
        rules_android's `@androidsdk//:sdk_path`).
      android_ndk: Optional Android NDK directory (e.g. from
        rules_android_ndk's `@androidndk`).
      create_dev_target: Whether to emit a runnable `{name}.dev` helper (when
        `web` is configured) that runs `flutter run -d web-server` in the
        source workspace with the hermetic SDK and the web dart_defines.
      dev_run_args: Extra args forwarded to flutter run by the dev helper.
      web: Files or dict spec for the {name}.web target.
      apk: Files or dict spec for the {name}.apk target.
      appbundle: Files or dict spec for the {name}.appbundle target (Android
        App Bundle; requires an Android SDK toolchain, see flutter.android_sdk).
      ios: Files or dict spec for the {name}.ios target.
      macos: Files or dict spec for the {name}.macos target.
      linux: Files or dict spec for the {name}.linux target.
      windows: Files or dict spec for the {name}.windows target.
    """

    platform_specs = {
        "web": web,
        "apk": apk,
        "appbundle": appbundle,
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

        platform_android_sdk = spec.get("android_sdk", android_sdk)
        if platform_android_sdk != None:
            rule_args["android_sdk"] = platform_android_sdk
        platform_android_ndk = spec.get("android_ndk", android_ndk)
        if platform_android_ndk != None:
            rule_args["android_ndk"] = platform_android_ndk

        for passthrough in ["android_test", "build_name", "build_number"]:
            if spec.get(passthrough) != None:
                rule_args[passthrough] = spec[passthrough]

        if visibility != None:
            rule_args["visibility"] = visibility

        # Platform spec tags extend the macro-level tags, so e.g. mobile
        # platforms can be tagged manual (host SDK prerequisites) while web
        # stays visible to wildcard builds.
        spec_tags = spec.get("tags")
        if tags != None or spec_tags != None:
            rule_args["tags"] = (tags if tags != None else []) + (spec_tags if spec_tags != None else [])
        if testonly:
            rule_args["testonly"] = True

        _flutter_app_rule(**rule_args)
        generated.append(target_name)

        if platform == "web" and create_dev_target:
            dev_args = {
                "name": "{}.dev".format(name),
                "embed": embed,
            }
            if merged_dart_defines != None:
                dev_args["dart_defines"] = merged_dart_defines
            if dev_run_args != None:
                dev_args["run_args"] = dev_run_args
            if visibility != None:
                dev_args["visibility"] = visibility
            if tags != None:
                dev_args["tags"] = tags
            if testonly:
                dev_args["testonly"] = True
            _flutter_dev_server_rule(**dev_args)

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

def _render_runtime_bootstrap(prepared_workspace, library_info, flutter_bin, log_name = "flutter_test.log", pub_cache_mode = "copy"):
    """Render the bash prologue materializing a mutable runtime workspace.

    After this fragment runs, $RUNTIME_WORKSPACE holds a writable copy of the
    prepared workspace with its pub cache at $RUNTIME_PUB_CACHE and a
    regenerated package config; $TEST_LOG points at the log file and
    $FLUTTER_BIN_ABS/$FLUTTER_ROOT are exported. The current directory is
    unchanged.

    pub_cache_mode selects how the (multi-GB) pub cache is materialized:
    "copy" (byte copy, the historical behavior), "hardlink" (opt-in: link the
    dereferenced files — read-only, inode-shared with the Bazel tree; fails
    over to copy), "reference" (no materialization — the package config points
    into the Bazel-provided cache read-only), or "auto" (APFS clone on macOS,
    byte copy elsewhere; always writable).
    """
    return """#!/bin/bash
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

# Materialize a tree without moving bytes: hardlink the dereferenced symlink
# targets (GNU cp -RLl) or APFS-clone them (macOS cp -c). Fails (nonzero) when
# src/dest sit on different filesystems or cp lacks the flag — callers fall
# back to copy_tree. Hardlinked files share inodes with the Bazel-owned
# source tree and stay read-only; APFS clones are fresh copy-on-write inodes
# and may be made writable safely.
link_tree() {{
    local src="$1"
    local dest="$2"
    if [ "$(uname)" = "Darwin" ]; then
        cp -c -RL "$src/." "$dest/" 2>/dev/null
    else
        cp -RLl "$src/." "$dest/" 2>/dev/null
    fi
}}

# Reset a possibly partially-linked destination for a copy retry. A failed
# link_tree leaves the source's read-only (0555) directory skeleton behind,
# which a plain rm -rf cannot unlink into as non-root — restore directory
# write bits first (directories are never hardlinked, so this cannot touch
# inodes shared with the source tree).
reset_dest() {{
    local dest="$1"
    find "$dest" -type d ! -perm -200 -exec chmod u+w {{}} + 2>/dev/null || true
    rm -rf "$dest"
    mkdir -p "$dest"
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
TEST_LOG="$LOG_ROOT/{log_name}"

mkdir -p "$LOG_ROOT"
: > "$TEST_LOG"

rm -rf "$RUNTIME_WORKSPACE"
mkdir -p "$RUNTIME_WORKSPACE"
copy_tree "$WORKSPACE_ABS" "$RUNTIME_WORKSPACE"
chmod -R u+w "$RUNTIME_WORKSPACE" 2>/dev/null || true

mkdir -p "$RUNTIME_PUB_CACHE"
PUB_CACHE_MODE="{pub_cache_mode}"
PUB_CACHE_FOR_CONFIG="$RUNTIME_PUB_CACHE"
if [ -n "$PUB_CACHE_ABS" ] && [ -d "$PUB_CACHE_ABS" ] && [ -n "$(ls -A "$PUB_CACHE_ABS" 2>/dev/null)" ]; then
    case "$PUB_CACHE_MODE" in
        reference)
            # Use the Bazel-provided cache in place, read-only. The package
            # config references packages by path, so no materialized copy is
            # needed; $RUNTIME_PUB_CACHE stays an empty writable scratch dir
            # for any stray tool write. Canonicalize so the relative rootUris
            # computed against the runtime workspace traverse real paths
            # (macOS /var vs /private/var).
            PUB_CACHE_FOR_CONFIG="$(cd "$PUB_CACHE_ABS" && pwd -P)"
            ;;
        hardlink)
            # Explicit opt-in: hardlink the dereferenced files (near-instant
            # for a multi-GB cache). The links share inodes with the
            # Bazel-owned tree and stay READ-ONLY — safe as long as nothing
            # writes into the cache at test time. Falls back to the byte
            # copy when linking isn't possible (cross-device TEST_TMPDIR,
            # busybox cp).
            if ! link_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"; then
                reset_dest "$RUNTIME_PUB_CACHE"
                copy_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"
                chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
            fi
            ;;
        copy)
            copy_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"
            chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
            ;;
        *)
            # auto: on macOS, APFS-clone the cache (fresh copy-on-write
            # inodes, so restoring the historical writable contract via
            # chmod is safe); everywhere else keep the byte copy — Linux
            # hardlinks would share inodes with bazel-out AND drop the
            # writable contract, which `hardlink` exists to opt into
            # explicitly.
            if [ "$(uname)" = "Darwin" ] && link_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"; then
                chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
            else
                reset_dest "$RUNTIME_PUB_CACHE"
                copy_tree "$PUB_CACHE_ABS" "$RUNTIME_PUB_CACHE"
                chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
            fi
            ;;
    esac
fi

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
export FLUTTER_ALREADY_LOCKED=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
export PUB_CACHE="$RUNTIME_PUB_CACHE"
export HOME="${{TEST_TMPDIR}}/flutter_home"
mkdir -p "$HOME"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export FLUTTER_ROOT
export PATH="$FLUTTER_BIN_DIR:$PATH"

# Regenerate package_config.json directly from the declared pub_deps.json
# metadata. Do NOT re-run pub resolution here: dependency_overrides are
# stripped from prepared workspaces, so an offline solve could legitimately
# fail even though the pinned package set is complete and consistent.
echo "Regenerating package_config.json for runtime workspace..."
PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "✗ python interpreter not found on PATH" | tee -a "$TEST_LOG"
    exit 1
fi
export PUB_DEPS_PATH="$RUNTIME_WORKSPACE/pub_deps.json"
export PUB_CACHE_ABS="$PUB_CACHE_FOR_CONFIG"
export WORKSPACE_ABS="$(cd "$RUNTIME_WORKSPACE" && pwd -P)"
export PACKAGE_CONFIG_PATH="$RUNTIME_WORKSPACE/.dart_tool/package_config.json"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
rm -f "$PACKAGE_CONFIG_PATH"
if "$PYTHON_BIN" <<'PY'
{package_config_py}
PY
then
    echo "✓ Package config regenerated from declared metadata" | tee -a "$TEST_LOG"
else
    echo "✗ package_config regeneration failed" | tee -a "$TEST_LOG"
    exit 1
fi
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
        log_name = log_name,
        pub_cache_mode = pub_cache_mode,
        package_config_py = PACKAGE_CONFIG_FROM_PUB_DEPS_PY,
    )

def _single_embedded_library(ctx, rule_name):
    """Return (library_info, flutter_bin) for a rule embedding one flutter_library."""

    if not ctx.attr.embed:
        fail("{} requires at least one flutter_library in embed".format(rule_name))

    if len(ctx.attr.embed) != 1:
        fail("{} currently supports exactly one entry in embed".format(rule_name))

    library_info = ctx.attr.embed[0][FlutterLibraryInfo]
    _check_embeddable(ctx, ctx.attr.embed[0], library_info)

    _, flutter_bin = _resolve_flutter_toolchain(ctx)

    return library_info, flutter_bin.path

def _prepare_overlay_workspace(ctx, library_info, overlay_files, suffix, mnemonic):
    """Copy the library workspace and overlay extra files into a tree artifact."""

    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + suffix)

    # Build args for file copying: pairs of rel_path and abs_path
    overlay_args = []
    for f in overlay_files:
        overlay_args.extend([_compute_relative_to_package(ctx, f), f.path])

    copy_script = """#!/bin/bash
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

# Copy overlay files: arguments come in pairs (rel_path, abs_path)
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

    ctx.actions.run_shell(
        inputs = [library_info.workspace] + overlay_files,
        outputs = [prepared_workspace],
        arguments = [
            prepared_workspace.path,
            library_info.workspace.path,
        ] + overlay_args,
        command = copy_script,
        mnemonic = mnemonic,
        progress_message = "%s for %s" % (mnemonic, ctx.label.name),
        # A ~100MB local copy of the library workspace feeding local-only
        # test/goldens actions: never worth remote execution (a remote hit
        # would just force a full tree download) and, by default, kept out of
        # the remote cache (see tree_output_execution_requirements).
        execution_requirements = tree_output_execution_requirements(
            _allow_remote_exec(ctx),
            _remote_cache_trees(ctx),
        ),
    )

    return prepared_workspace

def _runtime_runfiles(ctx, runner, prepared_workspace, library_info):
    """Runfiles common to rules that materialize a runtime workspace."""
    return ctx.runfiles(
        files = [
            runner,
            prepared_workspace,
            library_info.pub_cache,
            library_info.pub_deps,
            library_info.dart_tool,
        ],
    )

def _flutter_test_impl(ctx):
    """Implementation for flutter_test rule."""

    library_info, flutter_bin = _single_embedded_library(ctx, "flutter_test")

    prepared_workspace = _prepare_overlay_workspace(
        ctx,
        library_info,
        list(ctx.files.srcs),
        "_test_workspace",
        "PrepareFlutterTestWorkspace",
    )

    def _escape_pattern(pattern):
        return pattern.replace("\\", "\\\\").replace("'", "\\'")

    test_patterns_literal = "\n".join([_escape_pattern(pattern) for pattern in ctx.attr.test_files])

    test_runner = ctx.actions.declare_file(ctx.label.name + "_test_runner.sh")

    test_runner_content = _render_runtime_bootstrap(
        prepared_workspace,
        library_info,
        flutter_bin,
        pub_cache_mode = ctx.attr.pub_cache_materialization,
    ) + """
CMD=("$FLUTTER_BIN_ABS" "--suppress-analytics" "--no-version-check" "test" "--no-pub")
JOBS="{jobs}"
if [ -n "$JOBS" ] && [ "$JOBS" != "0" ]; then
    CMD+=("-j" "$JOBS")
fi

# Bazel test sharding protocol: acknowledge support up front (with
# --incompatible_check_sharding_support an untouched status file fails the
# test whenever shard_count is set).
if [ -n "${{TEST_SHARD_STATUS_FILE:-}}" ]; then
    touch "$TEST_SHARD_STATUS_FILE" 2>/dev/null || true
fi

TEST_ARGS=()
IFS=$'\n'
for pattern in $'{test_patterns}'; do
    if [ -n "$pattern" ]; then
        TEST_ARGS+=("$pattern")
    fi
done
unset IFS

TOTAL_SHARDS="${{TEST_TOTAL_SHARDS:-1}}"
if [ "$TOTAL_SHARDS" -gt 1 ]; then
    # Partition the test files here rather than passing --total-shards to
    # flutter: package:test shards by suite in directory-listing order (which
    # is not sorted, so the partition would depend on readdir order) and exits
    # 79 when a shard receives no suites. Expanding the patterns ourselves and
    # round-robin-assigning the LC_ALL=C-sorted file list keeps every shard's
    # slice deterministic, disjoint, and complete, and lets an empty shard
    # pass without paying flutter startup.
    SHARD_INDEX="${{TEST_SHARD_INDEX:-0}}"
    EXPANDED="$(
        for pattern in ${{TEST_ARGS[@]+"${{TEST_ARGS[@]}}"}}; do
            trimmed="${{pattern%/}}"
            if [ -d "$RUNTIME_WORKSPACE/$trimmed" ]; then
                (cd "$RUNTIME_WORKSPACE" && find "$trimmed" -type f -name '*_test.dart')
            else
                echo "$pattern"
            fi
        done | LC_ALL=C sort -u
    )"
    TEST_ARGS=()
    idx=0
    while IFS= read -r test_file; do
        [ -n "$test_file" ] || continue
        if [ $(( idx % TOTAL_SHARDS )) -eq "$SHARD_INDEX" ]; then
            TEST_ARGS+=("$test_file")
        fi
        idx=$(( idx + 1 ))
    done <<< "$EXPANDED"
    if [ "$idx" -eq 0 ]; then
        # Nothing matched ANY shard: an unsharded run would fail ("No tests
        # ran"), so all shards silently passing would green-light a target
        # that runs nothing.
        echo "✗ test_files patterns matched no *_test.dart files; failing." | tee -a "$TEST_LOG"
        exit 1
    fi
    if [ "${{#TEST_ARGS[@]}}" -eq 0 ]; then
        echo "No test files fall in shard $SHARD_INDEX of $TOTAL_SHARDS; passing." | tee -a "$TEST_LOG"
        exit 0
    fi
fi

for test_arg in ${{TEST_ARGS[@]+"${{TEST_ARGS[@]}}"}}; do
    CMD+=("$test_arg")
done

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
        test_patterns = test_patterns_literal,
        jobs = str(ctx.attr.jobs),
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
            runfiles = _runtime_runfiles(ctx, test_runner, prepared_workspace, library_info),
        ),
    ] + _test_execution_info(ctx)

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library targets to embed for testing.",
        ),
        "cpu": attr.int(
            default = 0,
            doc = "Local CPUs to reserve for this test (execution requirement " +
                  "`cpu:N`). 0 (default) declares nothing. Only useful together " +
                  "with `jobs`/sharding on large workers — reserving cores " +
                  "where none are spare just serializes tests that would " +
                  "otherwise overlap.",
        ),
        "jobs": attr.int(
            default = 0,
            doc = "Concurrency passed to `flutter test -j`. 0 (default) keeps " +
                  "flutter's own default (the number of cores). Cap this when " +
                  "several flutter_test targets run concurrently on one worker " +
                  "so their internal parallelism doesn't oversubscribe it.",
        ),
        "pub_cache_materialization": attr.string(
            default = "auto",
            values = ["auto", "copy", "hardlink", "reference"],
            doc = "How the test materializes the (multi-GB) pub cache at run " +
                  "time. `auto` (default) APFS-clones it on macOS (fresh " +
                  "copy-on-write inodes, kept writable) and byte-copies " +
                  "elsewhere — behaviorally identical to `copy` everywhere. " +
                  "`copy` forces the historical byte copy. `hardlink` opts " +
                  "into linking the dereferenced files (near-instant, but the " +
                  "links share inodes with the Bazel-owned tree and stay " +
                  "read-only; falls back to a copy when linking isn't " +
                  "possible). `reference` skips materialization entirely and " +
                  "points the regenerated package config into the " +
                  "Bazel-provided cache read-only.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test source files to copy into the runtime workspace.",
        ),
        "test_files": attr.string_list(
            default = ["test/"],
            doc = "Test files or directories to run",
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    test = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Runs Flutter tests using a prepared flutter_library workspace.""",
)

# Build-action script that regenerates goldens hermetically. It materializes a
# writable copy of the prepared workspace (protos and other generated_srcs
# already mounted, so nothing needs to exist in the source tree), regenerates
# package_config.json from the declared pub_deps.json (never re-resolving —
# dependency_overrides are stripped), then runs `flutter test --update-goldens`
# and copies the produced `**/goldens/**` trees into the declared output dir.
# Because it is a normal cached build action, an unchanged embed/test/lib graph
# is a cache hit (no re-render). The run is scoped to the golden tag(s) via
# --tags so --run-skipped only un-skips golden tests; a failing golden test
# fails the action (it does not replace a general widget-test gate).
_GOLDENS_ACTION_SCRIPT = """#!/bin/bash
set -euo pipefail

OUT_DIR="$1"
WORKSPACE_SRC="$2"
PUB_CACHE_SRC="$3"
PUB_DEPS_SRC="$4"
DART_TOOL_SRC="$5"
FLUTTER_BIN_REL="$6"
JOBS="$7"
TEST_TAGS="$8"
shift 8

copy_tree() {
    if command -v rsync >/dev/null 2>&1; then
        rsync -aL "$1/" "$2/"
    else
        cp -RL "$1/." "$2/"
    fi
}

# APFS-clone the dereferenced files instead of copying bytes on macOS (fresh
# copy-on-write inodes, safe to chmod); anywhere else the byte copy keeps the
# historical writable staging contract.
clone_tree() {
    [ "$(uname)" = "Darwin" ] || return 1
    cp -c -RL "$1/." "$2/" 2>/dev/null
}

# Reset a possibly partially-cloned destination for a copy retry: a failed
# clone can leave the source's read-only (0555) directory skeleton, which a
# plain rm -rf cannot unlink into as non-root.
reset_dest() {
    find "$1" -type d ! -perm -200 -exec chmod u+w {} + 2>/dev/null || true
    rm -rf "$1"
    mkdir -p "$1"
}

# Scratch must live INSIDE the action root ($PWD, the execroot/sandbox): the
# regenerated package_config points at the SDK by a path relative to the
# runtime workspace, and only paths within the action root resolve (an
# out-of-tree /tmp dir cannot reach the sandboxed SDK inputs).
WORK="$(mktemp -d "$PWD/.rf_goldens.XXXXXX")"
# Tolerant cleanup: restore directory write bits before removing (staged
# trees can carry 0555 dirs) and never let the EXIT trap's status replace a
# successful run's exit code.
cleanup() {
    find "$WORK" -type d ! -perm -200 -exec chmod u+w {} + 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

RUNTIME_WORKSPACE="$WORK/ws"
RUNTIME_PUB_CACHE="$WORK/pub_cache"
mkdir -p "$RUNTIME_WORKSPACE" "$RUNTIME_PUB_CACHE"

copy_tree "$WORKSPACE_SRC" "$RUNTIME_WORKSPACE"
chmod -R u+w "$RUNTIME_WORKSPACE" 2>/dev/null || true

if [ -d "$PUB_CACHE_SRC" ] && [ -n "$(ls -A "$PUB_CACHE_SRC" 2>/dev/null)" ]; then
    if clone_tree "$PUB_CACHE_SRC" "$RUNTIME_PUB_CACHE"; then
        chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
    else
        reset_dest "$RUNTIME_PUB_CACHE"
        copy_tree "$PUB_CACHE_SRC" "$RUNTIME_PUB_CACHE"
        chmod -R u+w "$RUNTIME_PUB_CACHE" 2>/dev/null || true
    fi
fi

if [ -d "$DART_TOOL_SRC" ]; then
    mkdir -p "$RUNTIME_WORKSPACE/.dart_tool"
    copy_tree "$DART_TOOL_SRC" "$RUNTIME_WORKSPACE/.dart_tool"
    chmod -R u+w "$RUNTIME_WORKSPACE/.dart_tool" 2>/dev/null || true
fi

if [ -f "$PUB_DEPS_SRC" ]; then
    cp "$PUB_DEPS_SRC" "$RUNTIME_WORKSPACE/pub_deps.json"
    chmod u+w "$RUNTIME_WORKSPACE/pub_deps.json" 2>/dev/null || true
fi

FLUTTER_BIN_ABS="$PWD/$FLUTTER_BIN_REL"
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    FLUTTER_BIN_ABS="$FLUTTER_BIN_REL"
fi
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "Flutter binary not found: $FLUTTER_BIN_REL" >&2
    exit 1
fi
FLUTTER_BIN_DIR="$(dirname "$FLUTTER_BIN_ABS")"
FLUTTER_ROOT="$(cd "$FLUTTER_BIN_DIR/.." && pwd)"

export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
export PUB_CACHE="$RUNTIME_PUB_CACHE"
export HOME="$WORK/home"
mkdir -p "$HOME"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
export FLUTTER_ROOT
export PATH="$FLUTTER_BIN_DIR:$PATH"

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "python interpreter not found on PATH" >&2
    exit 1
fi
export PUB_DEPS_PATH="$RUNTIME_WORKSPACE/pub_deps.json"
export PUB_CACHE_ABS="$RUNTIME_PUB_CACHE"
export WORKSPACE_ABS="$RUNTIME_WORKSPACE"
export PACKAGE_CONFIG_PATH="$RUNTIME_WORKSPACE/.dart_tool/package_config.json"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
rm -f "$PACKAGE_CONFIG_PATH"
"$PYTHON_BIN" <<'PY'
__PACKAGE_CONFIG_PY__
PY

CMD=("$FLUTTER_BIN_ABS" "--suppress-analytics" "--no-version-check" "test" "--no-pub" "--update-goldens" "--run-skipped")
# Scope --run-skipped to the golden tag(s) so it only un-skips golden tests and
# never wrongly runs tests that are `skip: true` for unrelated reasons
# (parked/flaky/platform). Empty test_tags = unscoped (caller's explicit risk).
if [ -n "$TEST_TAGS" ]; then
    CMD+=("--tags" "$TEST_TAGS")
fi
if [ -n "$JOBS" ] && [ "$JOBS" != "0" ]; then
    CMD+=("-j" "$JOBS")
fi
for pattern in "$@"; do
    if [ -n "$pattern" ]; then
        CMD+=("$pattern")
    fi
done

( cd "$RUNTIME_WORKSPACE" && "${CMD[@]}" )

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
while IFS= read -r golden_dir; do
    rel="${golden_dir#./}"
    mkdir -p "$OUT_DIR/$(dirname "$rel")"
    copy_tree "$RUNTIME_WORKSPACE/$rel" "$OUT_DIR/$rel"
done < <(cd "$RUNTIME_WORKSPACE" && find . -type d -name goldens 2>/dev/null)
""".replace("__PACKAGE_CONFIG_PY__", PACKAGE_CONFIG_FROM_PUB_DEPS_PY)

# `bazel run` write-back: copy the (cached) regenerated goldens into the source
# tree. Clears existing goldens dirs first so removed images don't linger.
_GOLDENS_WRITEBACK_SCRIPT = """#!/bin/bash
set -euo pipefail

resolve_runfile() {
    local rel="$1"
    for root in "${RUNFILES_DIR:-}" "$PWD" "$PWD.runfiles"; do
        if [ -n "$root" ] && [ -e "$root/$rel" ]; then
            echo "$root/$rel"
            return 0
        fi
    done
    [ -e "$rel" ] && { echo "$rel"; return 0; }
    return 1
}

WORKSPACE_DIR="${BUILD_WORKSPACE_DIRECTORY:-}"
if [ -z "$WORKSPACE_DIR" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set; run via 'bazel run'." >&2
    exit 1
fi

PACKAGE_SUBDIR="__PACKAGE__"
PACKAGE_DIR="$WORKSPACE_DIR"
if [ -n "$PACKAGE_SUBDIR" ]; then
    PACKAGE_DIR="$WORKSPACE_DIR/$PACKAGE_SUBDIR"
fi

SRC="$(resolve_runfile "__GOLDENS_SHORT__")"
if [ -z "$SRC" ]; then
    echo "regenerated goldens not found in runfiles" >&2
    exit 1
fi

# Collect the regenerated golden dirs FIRST. If none were produced, refuse to
# touch the source tree — otherwise a bad/empty regeneration would silently
# wipe the committed goldens.
REGEN=()
while IFS= read -r golden_dir; do
    REGEN+=("$golden_dir")
done < <(find -L "$SRC" -type d -name goldens 2>/dev/null)
if [ "${#REGEN[@]}" -eq 0 ]; then
    echo "✗ no goldens were regenerated; refusing to modify the source tree" >&2
    exit 1
fi

# Clear existing goldens only WITHIN the regenerated test scope (never the whole
# package or repo root), so removed images don't linger but out-of-scope goldens
# are never deleted.
TEST_ROOTS=(__TEST_ROOTS__)
for root in "${TEST_ROOTS[@]}"; do
    base="$PACKAGE_DIR/$root"
    [ -d "$base" ] || continue
    while IFS= read -r existing; do
        rm -rf "$existing"
    done < <(find "$base" -type d -name goldens 2>/dev/null)
done

count=0
for golden_dir in "${REGEN[@]}"; do
    rel="${golden_dir#"$SRC"/}"
    dest="$PACKAGE_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -RL "$golden_dir" "$dest"
    # Bazel marks declared-output files read-only/executable (0555); copying
    # that into the source tree would flip every golden's git mode to 100755.
    # Normalize to standard modes so git sees only real (content) changes.
    find "$dest" -type d -exec chmod 0755 {} + 2>/dev/null || true
    find "$dest" -type f -exec chmod 0644 {} + 2>/dev/null || true
    count=$((count + 1))
done

echo "Updated $count golden directory(ies) in $PACKAGE_DIR"
"""

def _flutter_goldens_impl(ctx):
    """Regenerate goldens hermetically (cached) and write them back on run."""
    library_info, flutter_bin = _single_embedded_library(ctx, "flutter_goldens")
    flutter_toolchain, _ = _resolve_flutter_toolchain(ctx)

    prepared_workspace = _prepare_overlay_workspace(
        ctx,
        library_info,
        list(ctx.files.srcs),
        "_goldens_workspace",
        "PrepareFlutterGoldensWorkspace",
    )

    goldens_out = ctx.actions.declare_directory(ctx.label.name + "_goldens")

    action_inputs = [
        prepared_workspace,
        library_info.pub_cache,
        library_info.pub_deps,
        library_info.dart_tool,
    ] + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files

    ctx.actions.run_shell(
        inputs = action_inputs,
        outputs = [goldens_out],
        arguments = [
            goldens_out.path,
            prepared_workspace.path,
            library_info.pub_cache.path,
            library_info.pub_deps.path,
            library_info.dart_tool.path,
            flutter_bin,
            str(ctx.attr.jobs),
            ",".join(ctx.attr.test_tags),
        ] + ctx.attr.test_files,
        command = _GOLDENS_ACTION_SCRIPT,
        mnemonic = "FlutterUpdateGoldens",
        progress_message = "Regenerating Flutter goldens for %s" % ctx.label.name,
        execution_requirements = {} if _allow_remote_exec(ctx) else {"no-remote-exec": "1"},
    )

    runner = ctx.actions.declare_file(ctx.label.name + "_update_goldens.sh")
    test_roots = " ".join([_shell_quote(t) for t in ctx.attr.test_files])
    ctx.actions.write(
        output = runner,
        content = _GOLDENS_WRITEBACK_SCRIPT.replace("__PACKAGE__", ctx.label.package).replace("__GOLDENS_SHORT__", goldens_out.short_path).replace("__TEST_ROOTS__", test_roots),
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([goldens_out]),
            runfiles = ctx.runfiles(files = [runner, goldens_out]),
        ),
    ]

flutter_goldens = rule(
    implementation = _flutter_goldens_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library target to embed (exactly one).",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test sources (including golden tests) to overlay into the workspace.",
        ),
        "test_files": attr.string_list(
            default = ["test/"],
            doc = "Test files or directories whose golden tests to (re)generate. " +
                  "Also bounds the write-back's clear step: only goldens under " +
                  "these roots are cleared before restoring the regenerated set.",
        ),
        "test_tags": attr.string_list(
            default = ["golden"],
            doc = "Tags passed to `flutter test --tags`, scoping --run-skipped. " +
                  "Defaults to [\"golden\"] so only golden-tagged tests are " +
                  "un-skipped and rendered — a test that is `skip: true` for an " +
                  "unrelated reason (parked/flaky/platform) is never run. Set to " +
                  "[] to run every test under test_files (unscoped --run-skipped; " +
                  "only safe when golden is the sole skip).",
        ),
        "jobs": attr.int(
            default = 0,
            doc = "Concurrency for `flutter test -j` (0 = flutter's default).",
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = """Regenerates Flutter golden images hermetically and writes them back
to the source tree.

The build action runs `flutter test --tags <test_tags> --update-goldens
--run-skipped` inside a prepared workspace (dart_proto_library trees and other
generated_srcs already mounted, so no source-tree pre-population/refresh is
required) and captures the produced `**/goldens/**` PNG trees as a declared
output — so an unchanged embed/test/lib graph is a cache hit and re-renders
nothing. `bazel run` copies the (cached) goldens back into the source tree for
review and commit.

By default it runs only golden-tagged tests (test_tags = ["golden"]), so a
golden-test failure fails the action but it is NOT a general widget-test gate —
keep a separate flutter_test target for that. The scoping is deliberate:
`--run-skipped` un-skips tests, and limiting it to the golden tag ensures tests
that are `skip: true` for unrelated reasons are never run. Set test_tags = []
to run every test under test_files (only safe when golden is the sole skip).""",
)

def _flutter_analyze_test_impl(ctx):
    """Implementation for flutter_analyze_test rule."""

    library_info, flutter_bin = _single_embedded_library(ctx, "flutter_analyze_test")

    prepared_workspace = _prepare_overlay_workspace(
        ctx,
        library_info,
        list(ctx.files.srcs),
        "_analyze_workspace",
        "PrepareFlutterAnalyzeWorkspace",
    )

    flags = []
    if ctx.attr.fatal_infos:
        flags.append("--fatal-infos")
    if not ctx.attr.fatal_warnings:
        flags.append("--no-fatal-warnings")
    flags.extend(ctx.attr.extra_args)
    flags_literal = " ".join([_shell_quote(flag) for flag in flags])

    runner = ctx.actions.declare_file(ctx.label.name + "_analyze_runner.sh")

    runner_content = _render_runtime_bootstrap(
        prepared_workspace,
        library_info,
        flutter_bin,
        log_name = "flutter_analyze.log",
        pub_cache_mode = ctx.attr.pub_cache_materialization,
    ) + """
CMD=("$FLUTTER_BIN_ABS" "--suppress-analytics" "--no-version-check" "analyze" "--no-pub" {flags})

pushd "$RUNTIME_WORKSPACE" >/dev/null

set +e
"${{CMD[@]}}" 2>&1 | tee -a "$TEST_LOG"
RESULT=${{PIPESTATUS[0]}}
set -e

popd >/dev/null

echo "" | tee -a "$TEST_LOG"
if [ "$RESULT" -eq 0 ]; then
    echo "✓ Flutter analysis passed" | tee -a "$TEST_LOG"
else
    echo "✗ Flutter analysis reported issues" | tee -a "$TEST_LOG"
fi

exit "$RESULT"
""".format(
        flags = flags_literal,
    )

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([runner]),
            runfiles = _runtime_runfiles(ctx, runner, prepared_workspace, library_info),
        ),
    ] + _test_execution_info(ctx)

flutter_analyze_test = rule(
    implementation = _flutter_analyze_test_impl,
    attrs = {
        "embed": attr.label_list(
            providers = [FlutterLibraryInfo],
            doc = "flutter_library targets whose prepared workspace is analyzed.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Additional files overlaid before analyzing (e.g. analysis_options.yaml, test sources).",
        ),
        "fatal_infos": attr.bool(
            default = False,
            doc = "Treat info-level issues as fatal (--fatal-infos).",
        ),
        "fatal_warnings": attr.bool(
            default = True,
            doc = "Treat warnings as fatal; set False to pass --no-fatal-warnings.",
        ),
        "extra_args": attr.string_list(
            default = [],
            doc = "Additional arguments forwarded to flutter analyze.",
        ),
        "cpu": attr.int(
            default = 0,
            doc = "Local CPUs to reserve for this test (execution requirement " +
                  "`cpu:N`); see flutter_test.cpu. 0 (default) declares nothing.",
        ),
        "pub_cache_materialization": attr.string(
            default = "auto",
            values = ["auto", "copy", "hardlink", "reference"],
            doc = "How the analyze run materializes the pub cache; see " +
                  "flutter_test.pub_cache_materialization.",
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    test = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Runs `flutter analyze` hermetically against a prepared flutter_library workspace.",
)

def _dart_format_test_impl(ctx):
    """Implementation for dart_format_test rule."""

    flutter_toolchain, flutter_bin_file = _resolve_flutter_toolchain(ctx)

    if not ctx.files.srcs:
        fail("dart_format_test requires at least one file in srcs")

    # Runfiles-relative location of the flutter binary (external repo files
    # have short_paths beginning with ../<repo>/).
    flutter_short = flutter_bin_file.short_path
    if flutter_short.startswith("../"):
        flutter_rel = flutter_short[len("../"):]
    else:
        flutter_rel = ctx.workspace_name + "/" + flutter_short

    files_literal = "\n".join([f.short_path for f in ctx.files.srcs])

    runner = ctx.actions.declare_file(ctx.label.name + "_format_runner.sh")
    runner_content = """#!/bin/bash
set -euo pipefail

RUNFILES_ROOT="${{RUNFILES_DIR:-${{TEST_SRCDIR:-$PWD}}}}"
FLUTTER_BIN="$RUNFILES_ROOT/{flutter_rel}"
if [ ! -f "$FLUTTER_BIN" ]; then
    echo "✗ Flutter binary not found at $FLUTTER_BIN" >&2
    exit 1
fi
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
DART_BIN="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ ! -x "$DART_BIN" ]; then
    echo "✗ Dart binary not found at $DART_BIN" >&2
    exit 1
fi

# dartdev's analytics initializer writes $HOME/.dart-tool; give it a scratch
# HOME so a read-only test environment cannot crash the CLI.
export HOME="${{TEST_TMPDIR:-$(mktemp -d)}}/dart_home"
mkdir -p "$HOME"
export CI=true

cd "$RUNFILES_ROOT/${{TEST_WORKSPACE:-_main}}"

FILES=()
IFS=$'\n'
for f in $'{files}'; do
    if [ -n "$f" ]; then
        FILES+=("$f")
    fi
done
unset IFS

exec "$DART_BIN" format --output=none --set-exit-if-changed "${{FILES[@]}}"
""".format(
        flutter_rel = flutter_rel,
        files = files_literal,
    )

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = runner,
            files = depset([runner]),
            runfiles = ctx.runfiles(
                files = [runner] + ctx.files.srcs +
                        flutter_toolchain.flutterinfo.tool_files +
                        flutter_toolchain.flutterinfo.sdk_files,
            ),
        ),
    ] + _test_execution_info(ctx)

dart_format_test = rule(
    implementation = _dart_format_test_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            mandatory = True,
            doc = "Dart sources checked with `dart format --set-exit-if-changed`.",
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    test = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Fails when any of the given Dart sources are not dart-format clean.",
)

# --incompatible_enable_proto_toolchain_resolution support: when the flag is
# set, protoc comes from the resolved proto toolchain (typically a prebuilt
# binary registered by e.g. toolchains_protoc) instead of the source-built
# @protobuf//:protoc, keeping protobuf's C++ compilation graph out of
# analysis entirely. The flag surfaces as a load-time constant, so rule
# shape (attrs/toolchains) is fixed per invocation — the same migration
# pattern as rules_go and protobuf's private toolchain_helpers.bzl (which
# instructs other repositories to copy it).
_PROTO_TOOLCHAIN_TYPE = Label("@protobuf//bazel/private:proto_toolchain_type")

_INCOMPATIBLE_PROTO_TOOLCHAIN_RESOLUTION = getattr(
    proto_common,
    "INCOMPATIBLE_ENABLE_PROTO_TOOLCHAIN_RESOLUTION",
    False,
)

def _proto_toolchain_requests():
    """Extra toolchain requests for rules/aspects that run protoc."""
    if _INCOMPATIBLE_PROTO_TOOLCHAIN_RESOLUTION:
        return [config_common.toolchain_type(_PROTO_TOOLCHAIN_TYPE, mandatory = False)]
    return []

def _if_legacy_proto_toolchain(legacy_attrs):
    """The given attrs only when protoc is NOT resolved via toolchains."""
    if _INCOMPATIBLE_PROTO_TOOLCHAIN_RESOLUTION:
        return {}
    return legacy_attrs

def _find_protoc(ctx):
    """Returns protoc for action use, from the resolved proto toolchain or the legacy attr."""
    if _INCOMPATIBLE_PROTO_TOOLCHAIN_RESOLUTION:
        toolchain = ctx.toolchains[_PROTO_TOOLCHAIN_TYPE]
        if not toolchain:
            fail("No toolchains registered for '%s'." % _PROTO_TOOLCHAIN_TYPE)
        return toolchain.proto.proto_compiler
    return ctx.executable._protoc

def _dart_proto_aspect_impl(target, ctx):
    """Generate Dart sources for one proto_library node in the deps closure."""

    proto_info = target[ProtoInfo]

    transitive = [
        dep[DartProtoAspectInfo].trees
        for dep in getattr(ctx.rule.attr, "deps", [])
        if DartProtoAspectInfo in dep
    ]

    if not proto_info.direct_sources:
        return [DartProtoAspectInfo(trees = depset(transitive = transitive))]

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    flutter_bin = flutter_toolchain.flutterinfo.target_tool_path
    flutter_bin_dir = paths.dirname(flutter_bin)
    dart_bin = paths.normalize(paths.join(flutter_bin_dir, "cache", "dart-sdk", "bin", "dart"))
    flutter_root = paths.dirname(flutter_bin_dir)

    tree = ctx.actions.declare_directory(ctx.label.name + ".dart_pb")
    wrapper_script = ctx.actions.declare_file(ctx.label.name + ".dart_pb_protoc_gen_dart.sh")

    # The plugin executes out of its own pub repository, whose fetch vendors
    # the exact dependency closure its pub_deps.json pinned into .pub_cache —
    # independent of whatever versions the consuming app resolves. The package
    # config is generated at runtime from that metadata.
    plugin_repo = ctx.attr._dart_plugin_files.label.workspace_name

    wrapper_content = """#!/bin/bash
set -euo pipefail

DART_BIN="{dart}"
if [ ! -x "$DART_BIN" ]; then
    if [ -x "${{DART_BIN}}.exe" ]; then
        DART_BIN="${{DART_BIN}}.exe"
    fi
fi

PYTHON_BIN="$(command -v python3 || command -v python)"

PLUGIN_ROOT="$PWD/external/{plugin_repo}"
ENTRYPOINT="$PLUGIN_ROOT/bin/protoc_plugin.dart"
if [ ! -f "$ENTRYPOINT" ]; then
    echo "✗ protoc_plugin entrypoint not found at $ENTRYPOINT" >&2
    exit 1
fi

export PUB_DEPS_PATH="$PLUGIN_ROOT/pub_deps.json"
export PUB_CACHE_ABS="$PLUGIN_ROOT/.pub_cache"
export WORKSPACE_ABS="$PLUGIN_ROOT"
export PACKAGE_CONFIG_PATH="$(mktemp -d)/package_config.json"
export FLUTTER_ROOT="$PWD/{flutter_root}"

"$PYTHON_BIN" <<'PYEOF'
{package_config_py}
PYEOF

exec "$DART_BIN" --packages="$PACKAGE_CONFIG_PATH" "$ENTRYPOINT" "$@"
""".format(
        dart = dart_bin,
        plugin_repo = plugin_repo,
        flutter_root = flutter_root,
        package_config_py = PACKAGE_CONFIG_FROM_PUB_DEPS_PY,
    )

    ctx.actions.write(
        output = wrapper_script,
        content = wrapper_content,
        is_executable = True,
    )

    tool_inputs = depset(flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files)
    additional_inputs = depset(
        transitive = [
            ctx.attr._dart_plugin_files[DefaultInfo].files,
            tool_inputs,
        ],
    )

    proto_lang_toolchain_info = proto_common.ProtoLangToolchainInfo(
        out_replacement_format_flag = None,
        plugin_format_flag = None,
        plugin = None,
        runtime = None,
        provided_proto_sources = [],
        proto_compiler = _find_protoc(ctx),
        protoc_opts = [],
        progress_message = "Generating Dart protos %{label}",
        mnemonic = "DartProtoCompile",
        allowlist_different_package = None,
        # Under toolchain resolution, proto_common.compile passes this to
        # actions.run(toolchain = ...) so the action executes on the platform
        # the resolved protoc binary was built for.
        toolchain_type = _PROTO_TOOLCHAIN_TYPE if _INCOMPATIBLE_PROTO_TOOLCHAIN_RESOLUTION else None,
    )

    args = ctx.actions.args()
    args.add("--plugin=protoc-gen-dart=" + wrapper_script.path)

    # protoc writes each output at <out root>/<proto import path>.pb.dart, so
    # rooting at the tree artifact reproduces the import-path layout exactly.
    # gRPC stubs are emitted only for files that declare services, which is why
    # a directory output is used instead of per-file declarations.
    args.add("--dart_out=grpc:" + tree.path)

    proto_common.compile(
        ctx.actions,
        proto_info,
        proto_lang_toolchain_info,
        [tree],
        additional_args = args,
        additional_inputs = additional_inputs,
        additional_tools = [wrapper_script],
    )

    return [DartProtoAspectInfo(trees = depset([tree], transitive = transitive))]

_dart_proto_aspect = aspect(
    implementation = _dart_proto_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _if_legacy_proto_toolchain({
        "_protoc": attr.label(
            default = Label("@protobuf//:protoc"),
            cfg = "exec",
            executable = True,
        ),
    }) | {
        "_dart_plugin_files": attr.label(
            default = Label("@pub_protoc_plugin//:protoc_plugin_files"),
        ),
    },
    required_providers = [ProtoInfo],
    toolchains = ["//flutter:toolchain_type"] + _proto_toolchain_requests(),
    doc = "Generates Dart protobuf sources for every proto_library in the deps closure.",
)

def _dart_proto_library_impl(ctx):
    """Implementation for dart_proto_library rule."""

    if not ctx.attr.deps:
        fail("dart_proto_library requires the deps attribute to reference at least one proto_library target.")

    trees = depset(transitive = [
        dep[DartProtoAspectInfo].trees
        for dep in ctx.attr.deps
    ])

    return [
        DefaultInfo(files = trees),
        DartProtoLibraryInfo(sources = trees),
    ]

dart_proto_library = rule(
    implementation = _dart_proto_library_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            providers = [ProtoInfo],
            aspects = [_dart_proto_aspect],
            doc = """proto_library targets to generate Dart for. Generation covers the
whole transitive proto closure (including well-known types such as
google/protobuf/timestamp), matching what generated imports expect.""",
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = "Generates Dart sources from proto_library targets using the Dart protoc plugin.",
)

def _dart_library_impl(ctx):
    """Implementation for dart_library rule"""

    # Get the Flutter toolchain
    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]

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
    prepared_workspace = None

    if ctx.attr.generated_srcs and not pubspec_file:
        fail("dart_library 'generated_srcs' requires the 'pubspec' attribute to be set")

    if pubspec_file:
        pub_deps_input = ctx.file.pub_deps
        if not pub_deps_input:
            fail("dart_library with 'pubspec' requires the 'pub_deps' attribute to point at a checked-in pub_deps.json")

        staged_cache = _maybe_stage_pub_package(ctx)
        if staged_cache != None:
            # Hosted pub package: stage its own payload only (one action, one
            # tree) instead of the full workspace/prepare path.
            pub_cache_dir = staged_cache
            pub_deps = pub_deps_input
        else:
            # Create a working directory mirroring the package layout
            working_dir, _ = create_flutter_working_dir(
                ctx,
                pubspec_file,
                direct_srcs,
                [],
                list(ctx.files.data),
                extra_entries = _generated_srcs_entries(ctx.attr.generated_srcs),
                allow_remote_exec = _allow_remote_exec(ctx),
                remote_cache_trees = _remote_cache_trees(ctx),
            )

            # Prepare dependency cache and package metadata from declared pub_deps.json.
            prepared_workspace, pub_get_output, pub_cache_dir, pub_deps_file, dart_tool_dir = _prepare_library_deps(
                ctx,
                flutter_toolchain,
                working_dir,
                pubspec_file,
                pub_deps_input,
                transitive_pub_caches,
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
        assembled_cache = ctx.attr.assemble_dep_caches,
    )

    output_files = list(direct_srcs)
    if pubspec_file:
        output_files.append(pubspec_file)
    for produced in [pub_deps, pub_get_output, pub_cache_dir, dart_tool_dir]:
        if produced != None:
            output_files.append(produced)

    providers = [
        DefaultInfo(files = depset(output_files)),
        library_info,
    ]

    # When a full workspace was prepared (a dart_library with a pubspec that is
    # not a bare staged pub package), also expose FlutterLibraryInfo so the
    # library can be embedded by flutter_app/flutter_test/flutter_analyze_test
    # exactly like a flutter_library. Bare (no-pubspec) and staged-package
    # dart_libraries have no prepared workspace and remain non-embeddable.
    if prepared_workspace != None:
        dart_files = [f for f in direct_srcs if f.extension == "dart"]
        other_files = [f for f in direct_srcs if f.extension != "dart"]
        providers.append(FlutterLibraryInfo(
            workspace = prepared_workspace,
            pub_get_log = pub_get_output,
            pub_cache = pub_cache_dir,
            pub_deps = pub_deps,
            dart_tool = dart_tool_dir,
            pubspec = pubspec_file,
            dart_sources = depset(dart_files),
            other_sources = depset(other_files),
            transitive_pub_caches = library_info.transitive_pub_caches,
            assembled_cache = ctx.attr.assemble_dep_caches,
        ))

    return providers

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
        "generated_srcs": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = """Targets whose outputs are mounted at an explicit package-relative
directory inside the package workspace (requires 'pubspec'). dart_proto_library
targets mount each generated file at its proto-import-relative path under the
destination; other targets mount flat by basename.""",
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
        "pub_payload": attr.label(
            allow_files = True,
            doc = """For hosted pub-package targets: the package's own files (the
`_package_payload` filegroup). When set on a pub_package target with no
codegen, the package is staged directly into the offline cache by a single
cheap action instead of the full prepare/codegen path.""",
        ),
        "assemble_dep_caches": attr.bool(
            doc = """Whether to merge transitive dependency pub caches into this
library's own cache tree. Generated package repositories set this to False so
each package contributes only its own hosted payload — the full cache is
assembled once, by the top-level consumer, from the transitive depset —
instead of duplicating shared transitive packages at every level of the
dependency graph.""",
            default = True,
        ),
    } | ALLOW_REMOTE_EXECUTION_ATTR,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Defines a Dart library",
)

def dart_library(
        name,
        create_update_target = True,
        create_format_target = True,
        create_sync_target = True,
        update_visibility = None,
        update_tags = None,
        **kwargs):
    """Defines a dart_library target and optional .update/.format helpers.

    Args:
      name: Target name for the dart_library rule.
      create_update_target: Whether to emit the runnable `.update` helper (only if pubspec is provided).
      create_format_target: Whether to emit the runnable `.format` helper (only if pubspec is provided).
      create_sync_target: Whether to emit the runnable `.sync` helper (only if generated_srcs is set).
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
        _emit_format_target(name, kwargs, create_format_target)
    _emit_sync_target(name, kwargs, create_sync_target)

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
