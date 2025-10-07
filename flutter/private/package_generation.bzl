"""Helpers for generating BUILD files for Dart/Flutter packages."""

_LIB_DISCOVERY_SCRIPT = """
import os
import sys

root = os.path.abspath(sys.argv[1])
paths = []

for dirpath, _, filenames in os.walk(root):
    rel_dir = os.path.relpath(dirpath, root)
    for name in filenames:
        rel_path = os.path.join(rel_dir, name) if rel_dir != "." else name
        paths.append(rel_path.replace(os.sep, "/"))

for path in sorted(paths):
    print(path)
"""

_DEF_LOAD_STMT = 'load("@rules_flutter//flutter:defs.bzl", "dart_library", "flutter_library")'

_DEF_VISIBILITY = '    visibility = ["//visibility:public"],'

def generate_package_build(repository_ctx, package_name, package_dir = ".", sdk_repo = None):
    """Generate a BUILD.bazel for the given package directory.

    Args:
        repository_ctx: Repository rule context.
        package_name: The Bazel target / Dart package name.
        package_dir: Relative directory containing the package ("." for root).
        sdk_repo: Optional repository label used to resolve SDK-provided
            dependencies (e.g. `@flutter_macos`). When omitted, a sensible
            default for the current host platform is used.
    """

    rule_kind = _determine_rule_kind(repository_ctx, package_dir)
    srcs = _collect_lib_sources(repository_ctx, package_dir)
    deps = _collect_direct_deps(repository_ctx, package_dir, sdk_repo)

    lines = [
        "# Generated BUILD file for package: {}".format(package_name),
        _DEF_LOAD_STMT,
        "",
        "{}(".format(rule_kind),
        '    name = "{}",'.format(package_name),
    ]

    if srcs:
        lines.append("    srcs = [")
        for src in srcs:
            lines.append('        "{}",'.format(src))
        lines.append("    ],")

    lines.append('    pubspec = "pubspec.yaml",')

    if deps:
        lines.append("    deps = [")
        for dep in deps:
            lines.append('        "{}",'.format(dep))
        lines.append("    ],")

    lines.append(_DEF_VISIBILITY)
    lines.append(")")

    lines.extend([
        "",
        "alias(",
        '    name = "lib",',
        '    actual = ":{}",'.format(package_name),
        _DEF_VISIBILITY,
        ")",
    ])

    build_path = "BUILD.bazel" if package_dir in (".", "") else package_dir + "/BUILD.bazel"
    repository_ctx.file(build_path, "\n".join(lines) + "\n")

def _determine_rule_kind(repository_ctx, package_dir):
    """Decide which rule kind (flutter or dart) to emit."""

    pubspec_rel = "pubspec.yaml" if package_dir in (".", "") else package_dir + "/pubspec.yaml"
    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return "dart_library"

    content = repository_ctx.read(pubspec_rel)
    in_environment = False
    env_indent = 0
    has_flutter = False
    has_sdk = False

    for raw_line in content.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if not in_environment:
            if stripped == "environment:":
                in_environment = True
                env_indent = indent
            continue

        if indent <= env_indent:
            in_environment = False
            if stripped == "environment:":
                in_environment = True
                env_indent = indent
            continue

        key = stripped.split(":", 1)[0]
        if key == "flutter":
            has_flutter = True
        if key == "sdk":
            has_sdk = True

    if has_flutter:
        return "flutter_library"
    if has_sdk:
        return "dart_library"
    return "flutter_library"

def _collect_lib_sources(repository_ctx, package_dir):
    """Collect all files under lib/ using a Python helper."""

    lib_rel = "lib" if package_dir in (".", "") else package_dir + "/lib"
    lib_path = repository_ctx.path(lib_rel)
    if not lib_path.exists or not lib_path.is_dir:
        return []

    python = repository_ctx.which("python3") or repository_ctx.which("python")
    if not python:
        fail("Unable to locate python3 to enumerate lib/ sources")

    result = repository_ctx.execute([
        python,
        "-c",
        _LIB_DISCOVERY_SCRIPT,
        str(lib_path),
    ], quiet = True)

    if result.return_code:
        fail(
            "Failed to enumerate lib/ sources (code {}): {}".format(
                result.return_code,
                result.stderr or result.stdout,
            ),
        )

    sources = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            # Only include .dart files for dart_library rule
            if line.endswith(".dart"):
                sources.append("lib/{}".format(line))

    return sorted(sources)

def _collect_direct_deps(repository_ctx, package_dir, sdk_repo):
    """Return the Bazel labels for direct dependencies (hosted + sdk)."""

    lock_rel = "pubspec.lock" if package_dir in (".", "") else package_dir + "/pubspec.lock"
    lock_path = repository_ctx.path(lock_rel)
    if not lock_path.exists:
        return []

    packages = _parse_pubspec_lock(repository_ctx.read(lock_rel))
    deps = []
    for pkg, info in packages.items():
        dep_kind = info.get("dependency", "") or ""
        if not dep_kind.startswith("direct"):
            continue

        source = info.get("source")
        if source == "hosted":
            repo_name = _sanitize_repo_name(pkg)
            deps.append("@{}//:{}".format(repo_name, pkg))
        elif source == "sdk":
            label = _sdk_dep_label(repository_ctx, package_dir, pkg, sdk_repo)
            if label:
                deps.append(label)

    return sorted(deps)

def _sanitize_repo_name(pkg):
    """Convert a package name to a canonical repository identifier."""

    pieces = ["pub_"]
    for idx in range(len(pkg)):
        ch = pkg[idx]
        if (
            ("a" <= ch and ch <= "z") or
            ("A" <= ch and ch <= "Z") or
            ("0" <= ch and ch <= "9") or
            ch == "_"
        ):
            pieces.append(ch)
        else:
            pieces.append("_")
    return "".join(pieces)

def _strip_quotes(value):
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value

def _sdk_dep_label(repository_ctx, package_dir, pkg, sdk_repo):
    path = _sdk_package_path(pkg)
    if not path:
        return None

    if package_dir.startswith("flutter/"):
        return "//{}:{}".format(path, pkg)

    repo = sdk_repo or _default_sdk_repo(repository_ctx)
    return "{}//{}:{}".format(repo, path, pkg)

def _default_sdk_repo(repository_ctx):
    os_name = repository_ctx.os.name.lower()
    if os_name.startswith("mac"):
        suffix = "macos"
    elif os_name.startswith("windows"):
        suffix = "windows"
    else:
        suffix = "linux"
    return "@flutter_{}".format(suffix)

def _sdk_package_path(pkg):
    if pkg == "sky_engine":
        return "flutter/bin/cache/pkg/{}".format(pkg)
    return "flutter/packages/{}".format(pkg)

def _parse_pubspec_lock(content):
    """Parse pubspec.lock into a dict of package metadata."""

    packages = {}
    in_packages = False
    current_pkg = None
    current_info = {}

    def _commit():
        if not current_pkg:
            return
        packages[current_pkg] = {
            "dependency": current_info.get("dependency"),
            "source": current_info.get("source"),
            "version": current_info.get("version"),
            "url": current_info.get("url"),
        }

    for raw_line in content.splitlines():
        if not in_packages:
            if raw_line.strip() == "packages:":
                in_packages = True
            continue

        if raw_line and not raw_line.startswith(" "):
            _commit()
            in_packages = False
            current_pkg = None
            current_info = {}
            continue

        if raw_line.startswith("  ") and not raw_line.startswith("    "):
            _commit()
            current_pkg = raw_line.strip().rstrip(":")
            current_info = {}
            continue

        if not current_pkg:
            continue

        stripped = raw_line.strip()
        if not stripped or stripped.startswith("description:"):
            continue

        if stripped.startswith("dependency:"):
            current_info["dependency"] = _strip_quotes(stripped.split(":", 1)[1].strip())
        elif stripped.startswith("source:"):
            current_info["source"] = _strip_quotes(stripped.split(":", 1)[1].strip())
        elif stripped.startswith("version:"):
            current_info["version"] = _strip_quotes(stripped.split(":", 1)[1].strip())
        elif stripped.startswith("url:"):
            current_info["url"] = _strip_quotes(stripped.split(":", 1)[1].strip())

    _commit()
    return packages
