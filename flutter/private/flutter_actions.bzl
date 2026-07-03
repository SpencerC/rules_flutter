"""Flutter command execution actions for Bazel rules."""

def shell_quote(arg):
    """Quote a string for safe interpolation into a bash script."""
    return "'" + arg.replace("'", "'\"'\"'") + "'"

# Python snippet that resolves a `package:executable` command (from the
# CODEGEN_CMD env var) to its bin/<executable>.dart entrypoint using the
# package_config.json at PACKAGE_CONFIG_PATH. Injected as a format *value*,
# so braces here are single.
RESOLVE_ENTRYPOINT_PY = """import json
import os
import sys
import urllib.parse
import urllib.request

command = os.environ["CODEGEN_CMD"]
config_path = os.environ["PACKAGE_CONFIG_PATH"]
config_dir = os.path.dirname(config_path)

if command.startswith("package:"):
    command = command[len("package:"):]

if ":" in command:
    package, executable = command.split(":", 1)
else:
    package = command
    executable = command

if not package or not executable:
    sys.stderr.write("Invalid generator command: {}\\n".format(os.environ["CODEGEN_CMD"]))
    sys.exit(1)

with open(config_path, "r", encoding="utf-8") as fh:
    config = json.load(fh)

root_uri = None
for entry in config.get("packages", []):
    if entry.get("name") == package:
        root_uri = entry.get("rootUri")
        break

if not root_uri:
    sys.stderr.write("Package '{}' not found in {}\\n".format(package, config_path))
    sys.exit(1)

parsed = urllib.parse.urlparse(root_uri)
if parsed.scheme == "file":
    root_path = urllib.request.url2pathname(parsed.path)
elif parsed.scheme:
    sys.stderr.write("Unsupported package root URI for '{}': {}\\n".format(package, root_uri))
    sys.exit(1)
else:
    root_path = os.path.abspath(os.path.join(config_dir, urllib.parse.unquote(root_uri)))

entrypoint = os.path.join(root_path, "bin", executable + ".dart")
if not os.path.isfile(entrypoint):
    sys.stderr.write("Codegen entrypoint not found: {}\\n".format(entrypoint))
    sys.exit(1)

print(entrypoint)"""

# Python snippet that writes .dart_tool/package_config.json from declared
# pub_deps.json metadata. Inputs via env: PUB_DEPS_PATH, PUB_CACHE_ABS,
# WORKSPACE_ABS, PACKAGE_CONFIG_PATH, FLUTTER_ROOT. Injected as a format
# *value*, so braces here are single.
PACKAGE_CONFIG_FROM_PUB_DEPS_PY = """import json
import os

deps_path = os.environ["PUB_DEPS_PATH"]
cache_root = os.environ["PUB_CACHE_ABS"]
workspace_root = os.environ["WORKSPACE_ABS"]
config_path = os.environ["PACKAGE_CONFIG_PATH"]
config_dir = os.path.dirname(config_path)

def _read_language_spec(root_path):
    pubspec = os.path.join(root_path, "pubspec.yaml")
    if not os.path.exists(pubspec):
        return ">=3.0.0 <4.0.0"

    capture = False
    with open(pubspec, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("environment:"):
                capture = True
                continue
            if capture:
                if stripped.startswith("sdk:"):
                    return stripped.split(":", 1)[1].strip().strip('"').strip("'")
                if stripped and not stripped.startswith("#") and not stripped.startswith(("flutter:", "flutter_test:", "dart:")):
                    break
    return ">=3.0.0 <4.0.0"

def _parse_language(spec):
    if not spec:
        return "3.0"
    spec = spec.replace(">=", " ").replace("<=", " ").replace(">", " ").replace("<", " ").replace("^", " ").split()
    if spec:
        version = spec[0].split("+")[0]
        parts = version.split(".")
        numeric_parts = []
        for part in parts:
            if part.isdigit():
                numeric_parts.append(part)
            else:
                break
        if len(numeric_parts) >= 2:
            return ".".join(numeric_parts[:2])
        if len(numeric_parts) == 1:
            return numeric_parts[0] + ".0"
    return "3.0"

def _root_uri(root_path):
    rel = os.path.relpath(root_path, config_dir).replace(os.sep, "/")
    if rel != "." and not rel.endswith("/"):
        rel += "/"
    return rel

default_language_version = _parse_language(_read_language_spec(workspace_root))

def _package_language_version(root_path):
    pubspec = os.path.join(root_path, "pubspec.yaml")
    if not os.path.exists(pubspec):
        return default_language_version

    capture = False
    with open(pubspec, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("environment:"):
                capture = True
                continue
            if capture:
                if stripped.startswith("sdk:"):
                    return _parse_language(stripped.split(":", 1)[1].strip().strip('"').strip("'"))
                if stripped and not stripped.startswith("#") and not stripped.startswith(("flutter:", "flutter_test:", "dart:")):
                    break
    return default_language_version

with open(deps_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

packages = []

def add_package(name, root_path):
    if not name or not root_path or not os.path.isdir(root_path):
        return
    pkg = dict()
    pkg["name"] = name
    pkg["rootUri"] = _root_uri(root_path)
    pkg["packageUri"] = "lib/"
    pkg["languageVersion"] = _package_language_version(root_path)
    packages.append(pkg)

for entry in data.get("packages", []):
    name = entry.get("name")
    source = entry.get("source")
    version = entry.get("version")
    description = entry.get("description")
    if not name:
        continue
    if source == "hosted" and version:
        root_path = os.path.join(cache_root, "hosted", "pub.dev", name + "-" + version)
        add_package(name, root_path)
    elif source == "root":
        add_package(name, workspace_root)
    elif source == "sdk":
        if name == "sky_engine":
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "bin", "cache", "pkg", name)
        elif name == "_macros":
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "bin", "cache", "dart-sdk", "pkg", name)
        else:
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "packages", name)
        add_package(name, root_path)
    elif source == "path":
        path_value = ""
        if isinstance(description, str):
            path_value = description
        elif isinstance(description, dict):
            path_value = description.get("path") or ""
        if path_value:
            add_package(name, os.path.abspath(os.path.join(workspace_root, path_value)))

config = dict()
config["configVersion"] = 2
config["generated"] = True
config["generator"] = "rules_flutter"
config["packages"] = packages
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2)
    fh.write("\\n")

# Newer flutter_tools also require .dart_tool/package_graph.json (normally
# written by `pub get`).
graph_packages = []
root_name = None
for entry in data.get("packages", []):
    name = entry.get("name")
    if not name:
        continue
    if entry.get("source") == "root":
        root_name = name
    node = dict()
    node["name"] = name
    node["version"] = entry.get("version") or "0.0.0"
    node["dependencies"] = [dep for dep in entry.get("dependencies", []) if isinstance(dep, str)]
    if entry.get("source") == "root":
        node["devDependencies"] = []
    graph_packages.append(node)

graph = dict()
graph["configVersion"] = 1
graph["roots"] = [root_name] if root_name else []
graph["packages"] = graph_packages
graph_path = os.path.join(config_dir, "package_graph.json")
with open(graph_path, "w", encoding="utf-8") as fh:
    json.dump(graph, fh, indent=2)
    fh.write("\\n")"""

def create_flutter_working_dir(ctx, pubspec_file, dart_files, other_files, data_files, extra_entries = []):
    """Create a working directory structure for Flutter commands.

    Args:
        ctx: The rule context
        pubspec_file: The pubspec.yaml file
        dart_files: List of .dart source files
        other_files: List of other source files declared in srcs
        data_files: List of additional data files that must be available in the workspace
        extra_entries: List of (rel_path, file) tuples mounted at explicit
            workspace-relative paths (e.g. generated proto sources). These take
            precedence over the derived layout for the same file.

    Returns:
        Tuple of (working_dir, input_files)
    """
    working_dir = ctx.actions.declare_directory(ctx.label.name + "_workspace_seed")

    # Build a manifest of files that should be available inside the workspace with
    # paths relative to the package root so code generation tools see the expected
    # project layout (e.g. lib/, test/, l10n/, web/).
    package = ctx.label.package
    package_prefix = package + "/" if package else ""
    workspace_name = ctx.workspace_name

    def source_relative_path(file):
        candidates = []
        for path in [file.short_path, file.path]:
            stripped = path
            if stripped.startswith("external/"):
                parts = stripped.split("/", 2)
                if len(parts) == 3:
                    stripped = parts[2]
            elif stripped.startswith("../"):
                parts = stripped.split("/", 2)
                if len(parts) == 3:
                    stripped = parts[2]
            if workspace_name:
                for repo_prefix in [
                    "external/{}/".format(workspace_name),
                    "../{}/".format(workspace_name),
                    "{}/".format(workspace_name),
                ]:
                    if stripped.startswith(repo_prefix):
                        stripped = stripped[len(repo_prefix):]
                        break
            candidates.append(stripped)

        for candidate in candidates:
            if package_prefix and candidate.startswith(package_prefix):
                return candidate[len(package_prefix):]
            if not package_prefix and not candidate.startswith("../") and not candidate.startswith("external/") and not candidate.startswith("bazel-out/"):
                return candidate

        return file.basename

    workspace_entries = {}
    seen = {}

    def add_entry(file, rel_path = None):
        if file == None:
            return
        if file.path in seen:
            return
        seen[file.path] = True

        if rel_path == None:
            rel_path = source_relative_path(file)

        workspace_entries[rel_path] = file

    add_entry(pubspec_file, "pubspec.yaml")

    for f in dart_files + other_files + data_files:
        add_entry(f)

    manifest = ctx.actions.declare_file(ctx.label.name + "_workspace_manifest.txt")
    manifest_content = []
    for rel_path in sorted(workspace_entries.keys()):
        file = workspace_entries[rel_path]
        manifest_content.append("{}|{}".format(rel_path, file.path))

    # Explicit mounts go last so they take precedence, and several directory
    # artifacts may merge into the same destination (the setup script merges
    # directory sources instead of replacing them).
    for rel_path, f in extra_entries:
        if f.path in seen:
            continue
        seen[f.path] = True
        manifest_content.append("{}|{}".format(rel_path, f.path))

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
    if [ -d "$SOURCE_PATH" ]; then
        # Merge directory sources so several tree artifacts can share a
        # destination (e.g. per-proto_library outputs under lib/generated).
        mkdir -p "$DEST_PATH"
        cp -RL "$SOURCE_PATH/." "$DEST_PATH/"
    else
        mkdir -p "$(dirname "$DEST_PATH")"
        cp -RL "$SOURCE_PATH" "$DEST_PATH"
    fi
done < "$MANIFEST_FILE"
""",
        is_executable = True,
    )

    # Collect unique input files for the action
    input_files = []
    seen_inputs = {}
    for f in [pubspec_file] + [entry[1] for entry in extra_entries] + dart_files + other_files + data_files:
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

def flutter_pub_get_action(
        ctx,
        flutter_toolchain,
        working_dir,
        pubspec_file,
        pub_deps_file,
        dependency_pub_caches = [],
        generator_commands = [],
        build_runner_common_args = [],
        build_runner_build_args = [],
        run_build_runner_build = False,
        is_pub_package = False):
    """Prepare Flutter/Dart dependencies from declared pub_deps.json metadata.

    Args:
        ctx: The rule context.
        flutter_toolchain: The resolved Flutter toolchain.
        working_dir: Directory containing the staged package sources.
        pubspec_file: The pubspec.yaml file for the library.
        pub_deps_file: Checked-in or repository-generated pub_deps.json.
        dependency_pub_caches: Files or depsets with pub cache directories from dependencies.
        generator_commands: Optional list of one-shot code generation commands
            (package:script).
        build_runner_common_args: Optional list of CLI args shared by all
            build_runner modes.
        build_runner_build_args: Optional list of CLI args passed to
            `build_runner build`.
        run_build_runner_build: Whether to run `dart run build_runner build`
            in this action.
        is_pub_package: Whether the target represents a hosted pub.dev package.

    Returns:
        Tuple of (prepared_workspace, pub_get_output, pub_cache_dir, pub_deps, dart_tool_dir).
    """

    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    dep_pub_cache_files = []
    for item in dependency_pub_caches:
        if type(item) == "depset":
            dep_pub_cache_files.extend(item.to_list())
        else:
            dep_pub_cache_files.append(item)

    pub_get_output = ctx.actions.declare_file(ctx.label.name + "_pub_prepare.log")
    pub_cache_dir = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")
    pub_deps = ctx.actions.declare_file(ctx.label.name + "_pub_deps.json")
    dart_tool_dir = ctx.actions.declare_directory(ctx.label.name + "_dart_tool")
    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_prepared_flutter_workspace")

    dep_pub_cache_args = []
    for dep_cache in dep_pub_cache_files:
        dep_pub_cache_args.append(dep_cache.path)

    generator_args = [shell_quote(cmd) for cmd in generator_commands]
    build_runner_common_args_quoted = [shell_quote(arg) for arg in build_runner_common_args]
    build_runner_build_args_quoted = [shell_quote(arg) for arg in build_runner_build_args]

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_SRC="{workspace_src}"
WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
PUB_DEPS_INPUT="{pub_deps_input}"
DART_TOOL_DIR="{dart_tool_dir}"
FLUTTER_BIN="{flutter_bin}"
IS_PUB_PACKAGE="{is_pub_package}"
ORIGINAL_PWD="$PWD"

WORKSPACE_SRC_ABS="$ORIGINAL_PWD/$WORKSPACE_SRC"
WORKSPACE_DIR_ABS="$ORIGINAL_PWD/$WORKSPACE_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"
DART_TOOL_DIR_ABS="$ORIGINAL_PWD/$DART_TOOL_DIR"
if [[ "$PUB_DEPS_INPUT" == /* ]]; then
    PUB_DEPS_INPUT_ABS="$PUB_DEPS_INPUT"
else
    PUB_DEPS_INPUT_ABS="$ORIGINAL_PWD/$PUB_DEPS_INPUT"
fi

# Copy staged workspace into prepared output directory
rm -rf "$WORKSPACE_DIR_ABS"
mkdir -p "$WORKSPACE_DIR_ABS"
if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$WORKSPACE_SRC_ABS/" "$WORKSPACE_DIR_ABS/"
else
    cp -RL "$WORKSPACE_SRC_ABS/." "$WORKSPACE_DIR_ABS/"
fi
chmod -R u+rwX "$WORKSPACE_DIR_ABS"

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "✗ FATAL ERROR: python interpreter not found on PATH" >&2
    exit 1
fi

if [ -f "$WORKSPACE_DIR_ABS/pubspec.yaml" ]; then
    # Published pub packages get their dev_dependencies/dependency_overrides
    # stripped (irrelevant to consumers, sometimes unresolvable). The root
    # package KEEPS its dependency_overrides: offline re-resolution (used to
    # regenerate flutter's plugin tooling for mobile builds) must honor them.
    PUBSPEC_SECTIONS=""
    if [ "$IS_PUB_PACKAGE" = "1" ]; then
        PUBSPEC_SECTIONS="dependency_overrides dev_dependencies"
    fi
    PUBSPEC_PATH="$WORKSPACE_DIR_ABS/pubspec.yaml" PUBSPEC_SECTIONS="$PUBSPEC_SECTIONS" "$PYTHON_BIN" - <<'PY'
import os
import sys

path = os.environ.get("PUBSPEC_PATH")
sections = set(filter(None, (os.environ.get("PUBSPEC_SECTIONS") or "").split()))
if not path or not os.path.exists(path) or not sections:
    sys.exit(0)

with open(path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

output = []
skip = False
skip_indent = 0
for line in lines:
    stripped = line.rstrip()
    indent = len(line) - len(line.lstrip(" "))
    if skip:
        if stripped and not stripped.startswith("#") and indent <= skip_indent:
            skip = False
        else:
            continue

    key = stripped.rstrip(":")
    if not skip and stripped.endswith(":") and key in sections:
        skip = True
        skip_indent = indent
        continue

    output.append(line)

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(output)
PY
fi

export PUB_CACHE="$PUB_CACHE_DIR_ABS"
mkdir -p "$PUB_CACHE_DIR_ABS"

echo "=== Preparing pub cache from dependencies ==="
DEP_CACHES=({dep_caches})
if [ ${{#DEP_CACHES[@]}} -gt 0 ]; then
    for DEP_CACHE in "${{DEP_CACHES[@]}}"; do
        if [[ "$DEP_CACHE" != /* ]]; then
            DEP_CACHE="$ORIGINAL_PWD/$DEP_CACHE"
        fi
        if [ -d "$DEP_CACHE" ] && [ -n "$(ls -A "$DEP_CACHE" 2>/dev/null)" ]; then
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "$DEP_CACHE/" "$PUB_CACHE_DIR_ABS/"
            else
                cp -RL "$DEP_CACHE/." "$PUB_CACHE_DIR_ABS/"
            fi
        fi
    done
else
    echo "No dependency caches supplied"
fi

if [ -d "$WORKSPACE_DIR_ABS/.pub_cache" ]; then
    echo "Merging package-local .pub_cache"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$WORKSPACE_DIR_ABS/.pub_cache/" "$PUB_CACHE_DIR_ABS/"
    else
        cp -RL "$WORKSPACE_DIR_ABS/.pub_cache/." "$PUB_CACHE_DIR_ABS/"
    fi
fi
echo ""

export PUBSPEC_PATH="$WORKSPACE_DIR_ABS/pubspec.yaml"
PACKAGE_INFO="$("$PYTHON_BIN" <<'PY'
import os
path = os.environ.get("PUBSPEC_PATH")
name = ""
version = ""
language = ""
if path and os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if stripped.startswith("name:") and not name:
                value = stripped.split(":", 1)[1].strip()
                value = value.strip("\\\"").strip("'")
                name = value
            elif stripped.startswith("version:") and not version:
                value = stripped.split(":", 1)[1].strip()
                value = value.strip("\\\"").strip("'")
                version = value
            elif stripped.startswith("environment:"):
                break
        fh.seek(0)
        capture = False
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("environment:"):
                capture = True
                continue
            if capture:
                if stripped.startswith("sdk:"):
                    value = stripped.split(":", 1)[1].strip()
                    value = value.strip("\\\"").strip("'")
                    language = value
                    break
                if stripped and not stripped.startswith("#") and not stripped.startswith(("flutter:", "flutter_test:", "dart:")):
                    break
values = [name or "", version or "", language or ""]
print("|".join(values))
PY
)"

PACKAGE_NAME="${{PACKAGE_INFO%%|*}}"
PACKAGE_VERSION="${{PACKAGE_INFO#*|}}"
PACKAGE_VERSION="${{PACKAGE_VERSION%%|*}}"
LANGUAGE_SPEC="${{PACKAGE_INFO##*|}}"
if [ -z "$LANGUAGE_SPEC" ]; then
    LANGUAGE_SPEC=">=3.0.0 <4.0.0"
fi

if [ "$IS_PUB_PACKAGE" = "1" ] && [ -n "$PACKAGE_NAME" ] && [ -n "$PACKAGE_VERSION" ]; then
    DEST="$PUB_CACHE_DIR_ABS/hosted/pub.dev/${{PACKAGE_NAME}}-${{PACKAGE_VERSION}}"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    if command -v rsync >/dev/null 2>&1; then
        rsync -aL "$WORKSPACE_DIR_ABS/" "$DEST/"
    else
        cp -RL "$WORKSPACE_DIR_ABS/." "$DEST/"
    fi
fi

export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"
if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at $FLUTTER_BIN_ABS" >&2
    exit 1
fi

FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN_ABS")/.." && pwd -P)"
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"

cd "$WORKSPACE_DIR_ABS"

echo "=== Using declared pub_deps.json ==="
if [ ! -s "$PUB_DEPS_INPUT_ABS" ]; then
    echo "✗ FATAL ERROR: pub_deps.json input is missing or empty: $PUB_DEPS_INPUT_ABS" >&2
    echo "Run the generated .update target or provide a checked-in pub_deps.json." >&2
    exit 1
fi
cp "$PUB_DEPS_INPUT_ABS" pub_deps.json

export PUB_DEPS_PATH="$WORKSPACE_DIR_ABS/pub_deps.json"
"$PYTHON_BIN" <<'PY'
import json
import os

path = os.environ.get("PUB_DEPS_PATH")
if path and os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        payload = fh.read()
    start = None
    for idx, ch in enumerate(payload):
        if ch == "[" or ch == chr(123):
            start = idx
            break
    if start and start > 0:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(payload[start:])
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data.get("packages"), list):
        raise SystemExit("pub_deps.json must contain a packages list")
PY

if [ ! -s pub_deps.json ]; then
    echo "✗ FATAL ERROR: pub_deps.json is empty" >&2
    exit 1
fi

export PUB_CACHE_ABS="$PUB_CACHE_DIR_ABS"
export WORKSPACE_ABS="$WORKSPACE_DIR_ABS"
export PACKAGE_CONFIG_PATH="$WORKSPACE_DIR_ABS/.dart_tool/package_config.json"
export ROOT_PACKAGE_NAME="$PACKAGE_NAME"
export ROOT_LANGUAGE_SPEC="$LANGUAGE_SPEC"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
"$PYTHON_BIN" <<'PY'
import json
import os

deps_path = os.path.join(os.environ["WORKSPACE_ABS"], "pub_deps.json")
cache_root = os.environ["PUB_CACHE_ABS"]
workspace_root = os.environ["WORKSPACE_ABS"]
config_path = os.environ["PACKAGE_CONFIG_PATH"]
root_name = os.environ.get("ROOT_PACKAGE_NAME") or ""
language_spec = os.environ.get("ROOT_LANGUAGE_SPEC") or ""

def _parse_language(spec):
    if not spec:
        return "3.0"
    spec = spec.replace(">=", " ").replace("<=", " ").replace(">", " ").replace("<", " ").replace("^", " ").split()
    if spec:
        version = spec[0].split("+")[0]
        parts = version.split(".")
        numeric_parts = []
        for part in parts:
            if part.isdigit():
                numeric_parts.append(part)
            else:
                break
        if len(numeric_parts) >= 2:
            return ".".join(numeric_parts[:2])
        if len(numeric_parts) == 1:
            return numeric_parts[0] + ".0"
    return "3.0"

language_version = _parse_language(language_spec)

def _package_language_version(root_path):
    pubspec = os.path.join(root_path, "pubspec.yaml")
    if not os.path.exists(pubspec):
        return language_version

    capture = False
    with open(pubspec, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("environment:"):
                capture = True
                continue
            if capture:
                if stripped.startswith("sdk:"):
                    return _parse_language(stripped.split(":", 1)[1].strip().strip("\\\"").strip("'"))
                if stripped and not stripped.startswith("#") and not stripped.startswith(("flutter:", "flutter_test:", "dart:")):
                    break
    return language_version

with open(deps_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

packages = []
config_dir = os.path.dirname(config_path)

def _root_uri(root_path):
    rel = os.path.relpath(root_path, config_dir).replace(os.sep, "/")
    if rel != "." and not rel.endswith("/"):
        rel += "/"
    return rel

def add_package(name, root_path):
    if not name or not root_path or not os.path.isdir(root_path):
        return
    pkg = dict()
    pkg["name"] = name
    pkg["rootUri"] = _root_uri(root_path)
    pkg["packageUri"] = "lib/"
    pkg["languageVersion"] = _package_language_version(root_path)
    packages.append(pkg)

for entry in data.get("packages", []):
    name = entry.get("name")
    source = entry.get("source")
    version = entry.get("version")
    description = entry.get("description")
    if not name:
        continue
    if source == "hosted" and version:
        root_path = os.path.join(cache_root, "hosted", "pub.dev", name + "-" + version)
        add_package(name, root_path)
    elif source == "root":
        add_package(name, workspace_root)
    elif source == "sdk":
        if name == "sky_engine":
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "bin", "cache", "pkg", name)
        elif name == "_macros":
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "bin", "cache", "dart-sdk", "pkg", name)
        else:
            root_path = os.path.join(os.environ["FLUTTER_ROOT"], "packages", name)
        add_package(name, root_path)
    elif source == "path":
        path_value = ""
        if isinstance(description, str):
            path_value = description
        elif isinstance(description, dict):
            path_value = description.get("path") or ""
        if path_value:
            add_package(name, os.path.abspath(os.path.join(workspace_root, path_value)))

config = dict()
config["configVersion"] = 2
config["generated"] = True
config["generator"] = "rules_flutter"
config["packages"] = packages
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2)
    fh.write("\\n")

# Synthesize a minimal pubspec.lock when the package does not ship one:
# build_runner's package graph requires it to classify dependencies
# (direct main / direct dev / transitive), which pub_deps.json records
# as "kind".
lock_path = os.path.join(workspace_root, "pubspec.lock")
if not os.path.exists(lock_path):
    kind_map = dict()
    kind_map["direct"] = "direct main"
    kind_map["dev"] = "direct dev"
    kind_map["transitive"] = "transitive"

    lines = []
    lines.append("# Generated by rules_flutter from pub_deps.json.")
    lines.append("packages:")
    for entry in data.get("packages", []):
        name = entry.get("name")
        source = entry.get("source")
        version = entry.get("version") or "0.0.0"
        kind = entry.get("kind") or "transitive"
        if not name or source == "root":
            continue
        dependency = kind_map.get(kind, "transitive")
        lines.append("  {{}}:".format(name))
        lines.append('    dependency: "{{}}"'.format(dependency))
        if source == "sdk":
            lines.append('    source: sdk')
            lines.append('    description: "flutter"')
        elif source == "path":
            description = entry.get("description")
            path_value = ""
            if isinstance(description, str):
                path_value = description
            elif isinstance(description, dict):
                path_value = description.get("path") or ""
            lines.append("    source: path")
            lines.append("    description:")
            lines.append('      path: "{{}}"'.format(path_value))
            lines.append("      relative: true")
        else:
            lines.append("    source: hosted")
            lines.append("    description:")
            lines.append('      name: "{{}}"'.format(name))
            lines.append('      url: "https://pub.dev"')
        lines.append('    version: "{{}}"'.format(version))
    lines.append("sdks:")
    lines.append('  dart: ">=3.0.0 <4.0.0"')
    with open(lock_path, "w", encoding="utf-8") as fh:
        fh.write("\\n".join(lines) + "\\n")
PY

GENERATOR_COMMANDS=({generator_commands})
if [ ${{#GENERATOR_COMMANDS[@]}} -gt 0 ]; then
    DART_BIN_LOCAL="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
    if [ ! -x "$DART_BIN_LOCAL" ]; then
        echo "✗ FATAL ERROR: Dart binary not found at $DART_BIN_LOCAL" >&2
        exit 1
    fi
    for CODEGEN_CMD in "${{GENERATOR_COMMANDS[@]}}"; do
        if [ -n "$CODEGEN_CMD" ]; then
            echo "Running code generation: $CODEGEN_CMD"
            CODEGEN_ENTRYPOINT="$(
                CODEGEN_CMD="$CODEGEN_CMD" PACKAGE_CONFIG_PATH="$PACKAGE_CONFIG_PATH" "$PYTHON_BIN" <<'PY'
{resolve_entrypoint_py}
PY
            )"
            if ! "$DART_BIN_LOCAL" --packages="$PACKAGE_CONFIG_PATH" "$CODEGEN_ENTRYPOINT"; then
                echo "✗ FATAL ERROR: Generator command '$CODEGEN_CMD' failed" >&2
                exit 1
            fi
        fi
    done
    rm -f .dart_tool/version 2>/dev/null || true
    rm -f .dart_tool/package_config_subset 2>/dev/null || true
fi

BUILD_RUNNER_COMMON_ARGS=({build_runner_common_args})
BUILD_RUNNER_BUILD_ARGS=({build_runner_build_args})
if [ "{run_build_runner_build}" = "1" ]; then
    DART_BIN_LOCAL="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
    if [ ! -x "$DART_BIN_LOCAL" ]; then
        echo "✗ FATAL ERROR: Dart binary not found at $DART_BIN_LOCAL" >&2
        exit 1
    fi

    if ! "$PYTHON_BIN" - "$WORKSPACE_ABS/pub_deps.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

for entry in data.get("packages", []):
    if entry.get("name") == "build_runner":
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
        echo "✗ FATAL ERROR: build_runner requested but not present in pub_deps.json" >&2
        exit 1
    fi

    # Resolve build_runner's entrypoint from package_config.json and invoke it
    # with an explicit --packages flag. `dart run` would first check that the
    # package resolution is up to date and attempt an implicit (networked)
    # `pub get`, which must never happen inside a build action.
    BUILD_RUNNER_ENTRYPOINT="$(
        CODEGEN_CMD="build_runner:build_runner" PACKAGE_CONFIG_PATH="$PACKAGE_CONFIG_PATH" "$PYTHON_BIN" <<'PY'
{resolve_entrypoint_py}
PY
    )"
    if [ -z "$BUILD_RUNNER_ENTRYPOINT" ]; then
        echo "✗ FATAL ERROR: unable to resolve build_runner entrypoint from package_config.json" >&2
        exit 1
    fi

    CMD=("$DART_BIN_LOCAL" "--packages=$PACKAGE_CONFIG_PATH" "$BUILD_RUNNER_ENTRYPOINT" "build")
    if [ ${{#BUILD_RUNNER_COMMON_ARGS[@]}} -gt 0 ]; then
        CMD+=("${{BUILD_RUNNER_COMMON_ARGS[@]}}")
    fi
    if [ ${{#BUILD_RUNNER_BUILD_ARGS[@]}} -gt 0 ]; then
        CMD+=("${{BUILD_RUNNER_BUILD_ARGS[@]}}")
    fi
    DELETE_CONFLICTING_PRESENT=0
    for ARG in "${{CMD[@]}}"; do
        if [ "$ARG" = "--delete-conflicting-outputs" ]; then
            DELETE_CONFLICTING_PRESENT=1
        fi
    done
    if [ "$DELETE_CONFLICTING_PRESENT" = "0" ]; then
        CMD+=("--delete-conflicting-outputs")
    fi

    echo "Running build_runner build: ${{CMD[*]}}"
    if ! "${{CMD[@]}}"; then
        echo "✗ FATAL ERROR: build_runner build failed" >&2
        exit 1
    fi
fi

echo ""
echo "=== Dependency preparation complete ==="
""".format(
        workspace_src = working_dir.path,
        workspace_dir = prepared_workspace.path,
        pub_cache_dir = pub_cache_dir.path,
        pub_deps = pub_deps.path,
        pub_deps_input = pub_deps_file.path,
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        dep_caches = " ".join(['"{}"'.format(path) for path in dep_pub_cache_args]),
        generator_commands = " ".join(generator_args),
        build_runner_common_args = " ".join(build_runner_common_args_quoted),
        build_runner_build_args = " ".join(build_runner_build_args_quoted),
        run_build_runner_build = "1" if run_build_runner_build else "0",
        is_pub_package = "1" if is_pub_package else "0",
        resolve_entrypoint_py = RESOLVE_ENTRYPOINT_PY,
    )

    ctx.actions.run_shell(
        inputs = [working_dir, pubspec_file, pub_deps_file] + dep_pub_cache_files + flutter_toolchain.flutterinfo.tool_files + flutter_toolchain.flutterinfo.sdk_files,
        outputs = [pub_get_output, pub_deps, pub_cache_dir, dart_tool_dir, prepared_workspace],
        command = script_content + """

cd "$ORIGINAL_PWD"

mkdir -p "$(dirname "{pub_get_output}")"
mkdir -p "$(dirname "{pub_deps}")"
mkdir -p "$PUB_CACHE_DIR_ABS"
mkdir -p "{dart_tool_dir}"

LOG_FILE="{pub_get_output}"
echo "=== Flutter Dependency Preparation ===" > "$LOG_FILE"
echo "Flutter binary: {flutter_bin}" >> "$LOG_FILE"
echo "Workspace output: {workspace_dir}" >> "$LOG_FILE"
echo "Prepared at: $(date)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

if [ -f "$WORKSPACE_DIR_ABS/pub_deps.json" ]; then
    cp "$WORKSPACE_DIR_ABS/pub_deps.json" "{pub_deps}"
    echo "✓ Copied declared pub_deps.json" >> "$LOG_FILE"
else
    echo "✗ pub_deps.json missing after preparation" >> "$LOG_FILE"
    exit 1
fi

rm -rf "{dart_tool_dir}"
mkdir -p "{dart_tool_dir}"
if [ -d "$WORKSPACE_DIR_ABS/.dart_tool" ]; then
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$WORKSPACE_DIR_ABS/.dart_tool/" "{dart_tool_dir}/"
    else
        cp -RL "$WORKSPACE_DIR_ABS/.dart_tool/." "{dart_tool_dir}/"
    fi
    echo "✓ Created .dart_tool/package_config.json" >> "$LOG_FILE"
else
    echo "{{}}" > "{dart_tool_dir}/package_config.json"
    echo "⚠ .dart_tool missing, wrote minimal package_config.json" >> "$LOG_FILE"
fi

mkdir -p "{pub_cache_dir}"
if [ -n "$(ls -A "$PUB_CACHE_DIR_ABS" 2>/dev/null)" ]; then
    echo "✓ Populated pub_cache directory" >> "$LOG_FILE"
else
    echo '{{}}' > "{pub_cache_dir}/.empty_cache.json"
    echo "⚠ Dependency cache was empty" >> "$LOG_FILE"
fi

echo "Status: Prepared dependencies from declared metadata" >> "$LOG_FILE"
""".format(
            pub_get_output = pub_get_output.path,
            pub_deps = pub_deps.path,
            pub_cache_dir = pub_cache_dir.path,
            dart_tool_dir = dart_tool_dir.path,
            flutter_bin = flutter_bin,
            workspace_dir = prepared_workspace.path,
        ),
        mnemonic = "FlutterPrepareDeps",
        progress_message = "Preparing Flutter dependencies for %s" % ctx.label.name,
    )

    return prepared_workspace, pub_get_output, pub_cache_dir, pub_deps, dart_tool_dir

ANDROID_TARGETS = ["apk", "appbundle"]

def flutter_build_action(
        ctx,
        flutter_toolchain,
        working_dir,
        target,
        pub_cache_dir,
        dart_tool_dir,
        mode = "release",
        dart_defines = {},
        build_args = [],
        env = {},
        android = None,
        android_test = False):
    """Execute flutter build command for the specified target.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        target: Build target (web, apk, appbundle, ios, etc.)
        pub_cache_dir: Assembled pub cache directory used for offline resolution
        dart_tool_dir: Prepared .dart_tool directory containing package_config metadata
        mode: Flutter build mode (release, profile, or debug)
        dart_defines: Dict of compile-time --dart-define key/value pairs
        build_args: Extra args appended verbatim to the flutter build command
        env: Extra environment variables exported before invoking flutter
        android: struct(sdk_path, ndk_path, java_home, files) for apk/appbundle
            targets — SDK/NDK trees from rules_android / rules_android_ndk and
            a JAVA_HOME from Bazel's java runtime toolchain. The action is
            tagged requires-network for Gradle's distribution/Maven downloads
        android_test: For apk targets, additionally run Gradle's
            app:assembleAndroidTest after the Flutter build and copy the
            instrumentation APK into androidTest/ under the build artifacts
            (the Firebase Test Lab instrumentation flow)

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

    # Map targets to Flutter build args and output paths. {mode}/{Mode} are
    # substituted with the requested build mode.
    target_configs = {
        "web": {
            "args": ["build", "web", "--no-pub"],
            "output_dir": "build/web",
        },
        "apk": {
            "args": ["build", "apk", "--no-pub"],
            "output_dir": "build/app/outputs/flutter-apk",
        },
        "appbundle": {
            "args": ["build", "appbundle", "--no-pub"],
            "output_dir": "build/app/outputs/bundle/{mode}",
        },
        "ios": {
            "args": ["build", "ios", "--no-codesign", "--no-pub"],
            "output_dir": "build/ios/iphoneos",
        },
        "macos": {
            "args": ["build", "macos", "--no-pub"],
            "output_dir": "build/macos/Build/Products/{Mode}",
        },
        "linux": {
            "args": ["build", "linux", "--no-pub"],
            "output_dir": "build/linux/x64/{mode}/bundle",
        },
        "windows": {
            "args": ["build", "windows", "--no-pub"],
            "output_dir": "build/windows/x64/runner/{Mode}",
        },
    }

    config = target_configs.get(target, target_configs["web"])

    if android_test and target != "apk":
        fail("flutter_app '{}': android_test is only supported on apk targets (got '{}').".format(ctx.label, target))

    command_args = list(config["args"])
    command_args.append("--" + mode)
    for key in sorted(dart_defines.keys()):
        command_args.append("--dart-define={}={}".format(key, dart_defines[key]))
    command_args.extend(build_args)
    build_command = " ".join([shell_quote(arg) for arg in command_args])

    output_dir = config["output_dir"].replace("{mode}", mode).replace("{Mode}", mode.capitalize())

    env_exports = "\n".join([
        "export {}={}".format(key, shell_quote(env[key]))
        for key in sorted(env.keys())
    ])

    # flutter's plugin tooling (.flutter-plugins-dependencies and the platform
    # plugin registrants) is only regenerated by `pub get`; `flutter build
    # --no-pub` assumes it already exists. Mobile targets therefore run an
    # offline pub get against the prepared cache (dependency_overrides are
    # preserved in the root pubspec so the offline solve reproduces the pins).
    mobile_pub_get = ""
    if target in ANDROID_TARGETS or target == "ios":
        mobile_pub_get = """
# pub writes bookkeeping (active_roots) into PUB_CACHE, so give it a mutable
# copy of the assembled cache before regenerating plugin tooling.
RW_PUB_CACHE="$BUILD_WORKSPACE_TMP/.pub_cache_rw"
mkdir -p "$RW_PUB_CACHE"
if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$PUB_CACHE_DIR_ABS/" "$RW_PUB_CACHE/"
else
    cp -RL "$PUB_CACHE_DIR_ABS/." "$RW_PUB_CACHE/"
fi
chmod -R u+w "$RW_PUB_CACHE"
export PUB_CACHE="$RW_PUB_CACHE"
export PUB_CACHE_DIR_ABS="$RW_PUB_CACHE"
export PUB_CACHE_ABS="$RW_PUB_CACHE"

echo "Running flutter pub get --offline to regenerate plugin tooling..."
if ! "$FLUTTER_BIN_ABS" --suppress-analytics --no-version-check pub get --offline; then
    echo "✗ FATAL ERROR: flutter pub get --offline failed" >&2
    exit 1
fi
"""

    ios_env = ""
    if target == "ios":
        # Host Xcode and CocoaPods are declared prerequisites (standard Bazel
        # practice for Apple builds); flutter drives `pod install` itself.
        ios_env = """
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "✗ FATAL ERROR: xcodebuild not found; iOS builds require a host Xcode installation." >&2
    exit 1
fi
# --incompatible_strict_action_env gives actions a minimal PATH; probe the
# common CocoaPods install locations before giving up.
if ! command -v pod >/dev/null 2>&1; then
    for CANDIDATE in /opt/homebrew/bin /usr/local/bin "${HOME:-/var/empty}/.gem/bin" /usr/local/lib/ruby/gems/*/bin; do
        if [ -x "$CANDIDATE/pod" ]; then
            export PATH="$CANDIDATE:$PATH"
            break
        fi
    done
fi
if ! command -v pod >/dev/null 2>&1; then
    echo "✗ FATAL ERROR: CocoaPods (pod) not found on PATH; install the version pinned in Podfile.lock." >&2
    exit 1
fi
export LANG="${LANG:-en_US.UTF-8}"
if [ -n "${RULES_FLUTTER_CP_HOME:-}" ]; then
    export CP_HOME_DIR="$RULES_FLUTTER_CP_HOME"
    mkdir -p "$CP_HOME_DIR"
fi
"""

    android_test_step = ""
    if android_test:
        # Runs in the mutable workspace after a successful flutter build, so
        # local.properties, the Gradle env, and plugin tooling already exist.
        android_test_step = """
    echo "Building androidTest instrumentation APK..."
    chmod +x android/gradlew 2>/dev/null || true
    if ! (cd android && ./gradlew app:assembleAndroidTest); then
        echo "✗ FATAL ERROR: gradlew app:assembleAndroidTest failed" >&2
        exit 1
    fi
    if [ ! -d build/app/outputs/apk/androidTest ]; then
        echo "✗ FATAL ERROR: androidTest outputs not found at build/app/outputs/apk/androidTest" >&2
        exit 1
    fi
    mkdir -p "$BUILD_ARTIFACTS_ABS/androidTest"
    cp -r build/app/outputs/apk/androidTest/. "$BUILD_ARTIFACTS_ABS/androidTest/"
    echo "✓ androidTest instrumentation APK copied"
"""

    # iOS keeps the caller's HOME (when the build passes it through, e.g.
    # --action_env=HOME) so CocoaPods spec/pod caches persist across builds;
    # under --incompatible_strict_action_env HOME is absent, so fall back to a
    # scratch dir rather than aborting. Everything else always gets a scratch
    # HOME to keep config/analytics writes out of shared state.
    if target == "ios":
        home_export = 'export HOME="${HOME:-$(mktemp -d)}"'
    else:
        home_export = 'export HOME="$(mktemp -d)"'

    android_gradle_env = ""
    if target in ANDROID_TARGETS:
        if android == None:
            fail("flutter_app '{}' target '{}' requires the android_sdk attribute (see flutter_app docs).".format(ctx.label, target))
        java_home_export = (
            "export JAVA_HOME=\"{}\"".format(android.java_home) if android.java_home.startswith("/") else "export JAVA_HOME=\"$ORIGINAL_PWD/{}\"".format(android.java_home)
        )
        android_env_exports = "\n".join([
            "export ANDROID_HOME=\"$ORIGINAL_PWD/{}\"".format(android.sdk_path),
            "export ANDROID_SDK_ROOT=\"$ANDROID_HOME\"",
            java_home_export,
        ])

        # Executed after the mutable workspace copy exists. Gradle needs a
        # writable home; RULES_FLUTTER_GRADLE_USER_HOME (via --action_env plus
        # --sandbox_writable_path) opts into a persistent cache so warm builds
        # skip the distribution/Maven downloads.
        android_gradle_env = """
export GRADLE_USER_HOME="${RULES_FLUTTER_GRADLE_USER_HOME:-$BUILD_WORKSPACE_TMP/.gradle_home}"
mkdir -p "$GRADLE_USER_HOME"
export GRADLE_OPTS="-Dorg.gradle.daemon=false ${GRADLE_OPTS:-}"
# rules_android's repository wraps the host SDK with symlinks and omits some
# directories (ndk/, licenses/). AGP 8 dropped ndk.dir support, so resolve the
# real host SDK behind the wrapper — SDK-embedded components stay visible.
if [ -L "$ANDROID_HOME/platforms" ]; then
    REAL_PLATFORMS="$(readlink "$ANDROID_HOME/platforms")"
    case "$REAL_PLATFORMS" in
        /*)
            export ANDROID_HOME="$(dirname "$REAL_PLATFORMS")"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            ;;
    esac
fi
mkdir -p android
printf 'sdk.dir=%s\\nflutter.sdk=%s\\n' "$ANDROID_HOME" "$FLUTTER_ROOT" > android/local.properties
"""
        if android.ndk_path:
            android_gradle_env = "RULES_FLUTTER_NDK_DIR=\"$ORIGINAL_PWD/" + android.ndk_path + "\"\n" + android_gradle_env
    else:
        android_env_exports = "export ANDROID_HOME=\"\"\nexport ANDROID_SDK_ROOT=\"\""

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
DART_TOOL_DIR="{dart_tool_dir}"
FLUTTER_BIN="{flutter_bin}"
OUTPUT_LOG="{output_log}"
BUILD_ARTIFACTS="{build_artifacts}"
BUILD_OUTPUT_DIR="{build_output_dir}"
ORIGINAL_PWD="$PWD"

# Convert relative paths to absolute before changing directories
OUTPUT_LOG_ABS="$ORIGINAL_PWD/$OUTPUT_LOG"
BUILD_ARTIFACTS_ABS="$ORIGINAL_PWD/$BUILD_ARTIFACTS"
DART_TOOL_DIR_ABS="$ORIGINAL_PWD/$DART_TOOL_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"

mkdir -p "$(dirname "$OUTPUT_LOG_ABS")"
: > "$OUTPUT_LOG_ABS"
exec > >(tee "$OUTPUT_LOG_ABS") 2>&1

# Set up environment
export PUB_CACHE="$PUB_CACHE_DIR_ABS"

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

FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN_ABS")/.." && pwd -P)"

# Configure Flutter for sandbox environment. The SDK repository is sealed
# read-only at fetch time; FLUTTER_ALREADY_LOCKED skips the bin/cache lockfile
# and the scratch HOME keeps config/analytics writes out of the repository.
export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
{home_export}
{android_env_exports}
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"
{env_exports}

# Copy the prepared workspace input into a mutable directory for Flutter. Bazel
# may present input tree artifacts as read-only in the sandbox.
SOURCE_WORKSPACE_ABS="$ORIGINAL_PWD/$WORKSPACE_DIR"
BUILD_TMP_PARENT="$ORIGINAL_PWD/$(dirname "$BUILD_ARTIFACTS")"
mkdir -p "$BUILD_TMP_PARENT"
BUILD_WORKSPACE_TMP="$(mktemp -d "$BUILD_TMP_PARENT/rules_flutter_build.XXXXXX")"
# bash 3.2 (macOS /bin/bash) runs the EXIT trap with $?=0 after a `set -u`
# expansion error, which would let a failed build report success to Bazel.
# The sentinel forces any abort before the final line to exit nonzero.
SCRIPT_COMPLETED=0
cleanup() {{
    rc=$?
    rm -rf "$BUILD_WORKSPACE_TMP" || true
    if [ "$SCRIPT_COMPLETED" != 1 ] && [ "$rc" = 0 ]; then
        rc=1
    fi
    exit "$rc"
}}
trap cleanup EXIT

if command -v rsync >/dev/null 2>&1; then
    rsync -aL "$SOURCE_WORKSPACE_ABS/" "$BUILD_WORKSPACE_TMP/"
else
    cp -RL "$SOURCE_WORKSPACE_ABS/." "$BUILD_WORKSPACE_TMP/"
fi
chmod -R u+rwX "$BUILD_WORKSPACE_TMP"

# Change to the mutable workspace directory
cd "$BUILD_WORKSPACE_TMP"

# Copy .dart_tool tree to workspace. Dereference symlinks (-L): sandboxed
# inputs are symlinks to read-only files, and the regeneration step below
# must be able to rewrite these copies in place.
if [ -d "$DART_TOOL_DIR_ABS" ]; then
    mkdir -p .dart_tool
    cp -RL "$DART_TOOL_DIR_ABS/." .dart_tool/
    chmod -R u+rwX .dart_tool
fi
{android_gradle_env}
{ios_env}

# Run flutter build
echo "=== Flutter Build {target} ==="
echo "Working directory: $(pwd)"
echo "Flutter binary: $FLUTTER_BIN"
echo "Target: {target}"
echo ""

# Regenerate package_config.json with correct paths for this sandbox from the
# declared dependency metadata. Do not invoke pub here; the build action must
# use the prepared cache and metadata.
echo ""
echo "Regenerating package_config.json from declared metadata..."
PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "✗ FATAL ERROR: python interpreter not found on PATH" >&2
    exit 1
fi
if [ ! -s pub_deps.json ]; then
    echo "✗ FATAL ERROR: pub_deps.json missing from prepared workspace" >&2
    exit 1
fi

export PUB_DEPS_PATH="$PWD/pub_deps.json"
export PUB_CACHE_ABS="$PUB_CACHE_DIR_ABS"
export WORKSPACE_ABS="$PWD"
export PACKAGE_CONFIG_PATH="$PWD/.dart_tool/package_config.json"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
rm -f "$PACKAGE_CONFIG_PATH" "$PWD/.dart_tool/package_graph.json"
"$PYTHON_BIN" <<'PY'
{package_config_py}
PY
echo "✓ Package config regenerated from declared metadata"
echo ""
{mobile_pub_get}
echo "Running: $FLUTTER_BIN_ABS {build_command}"

if "$FLUTTER_BIN_ABS" --suppress-analytics --no-version-check {build_command}; then
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
{android_test_step}
    echo "✓ Flutter build completed successfully"
else
    echo "✗ FATAL ERROR: flutter {build_command} failed"
    echo "Check your Flutter project configuration and dependencies"
    echo "Ensure the offline pub cache contains all required dependencies"
    exit 1
fi
SCRIPT_COMPLETED=1
""".format(
        workspace_dir = working_dir.path,
        pub_cache_dir = pub_cache_dir.path,
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        output_log = build_output.path,
        build_artifacts = build_artifacts.path,
        build_command = build_command,
        build_output_dir = output_dir,
        target = target,
        env_exports = env_exports,
        android_env_exports = android_env_exports,
        android_gradle_env = android_gradle_env,
        home_export = home_export,
        ios_env = ios_env,
        mobile_pub_get = mobile_pub_get,
        android_test_step = android_test_step,
        package_config_py = PACKAGE_CONFIG_FROM_PUB_DEPS_PY,
    )

    inputs = depset(
        direct = [working_dir, pub_cache_dir, dart_tool_dir] +
                 flutter_toolchain.flutterinfo.tool_files +
                 flutter_toolchain.flutterinfo.sdk_files,
        transitive = [android.files] if android else [],
    )

    execution_requirements = None
    use_default_shell_env = False
    mnemonic = "FlutterBuild"
    if target in ANDROID_TARGETS:
        # Gradle downloads its distribution and Maven dependencies; keep the
        # action off remote executors and let RULES_FLUTTER_GRADLE_USER_HOME
        # (an --action_env opt-in) reach the script.
        execution_requirements = {
            # The host-wrapped SDK/NDK symlink trees cannot be staged into a
            # sandbox, and Gradle needs network for its distribution/Maven
            # dependencies.
            "no-remote-exec": "1",
            "no-sandbox": "1",
            "requires-network": "1",
        }
        use_default_shell_env = True
        mnemonic = "FlutterBuildAndroid"
    elif target == "ios":
        # Host Xcode + CocoaPods; pod install fetches specs and binary pods
        # over the network.
        execution_requirements = {
            "no-remote-exec": "1",
            "no-sandbox": "1",
            "requires-darwin": "1",
            "requires-network": "1",
        }
        use_default_shell_env = True
        mnemonic = "FlutterBuildIos"

    # Execute build
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [build_output, build_artifacts],
        command = script_content,
        mnemonic = mnemonic,
        progress_message = "Running flutter build %s for %s" % (target, ctx.label.name),
        execution_requirements = execution_requirements,
        use_default_shell_env = use_default_shell_env,
    )

    return build_output, build_artifacts
