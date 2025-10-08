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

def _ensure_pub_deps(repository_ctx, package_name, package_dir):
    """Ensure pub_deps.json exists by running pub deps --json when necessary."""

    if package_dir in (".", ""):
        pubspec_rel = "pubspec.yaml"
        pub_deps_rel = "pub_deps.json"
        pub_cache_rel = ".pub_cache"
    else:
        pubspec_rel = package_dir + "/pubspec.yaml"
        pub_deps_rel = package_dir + "/pub_deps.json"
        pub_cache_rel = package_dir + "/.pub_cache"

    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return

    pub_deps_path = repository_ctx.path(pub_deps_rel)
    if pub_deps_path.exists:
        content = repository_ctx.read(pub_deps_rel)
        if content.strip():
            return

    command, tool = _find_pub_command(repository_ctx)
    if not command:
        fail("""Unable to locate a Dart or Flutter executable while preparing '{}' to run `pub deps --json`.
Install Flutter or Dart on PATH, or check in pub_deps.json for this package.""".format(package_name))

    workdir = str(repository_ctx.path(package_dir if package_dir not in (".", "") else "."))
    run_env = {
        "PUB_CACHE": str(repository_ctx.path(pub_cache_rel)),
        "PUB_ENVIRONMENT": "rules_flutter:repository",
    }
    if tool == "flutter":
        run_env["FLUTTER_SUPPRESS_ANALYTICS"] = "true"
        run_env["CI"] = "true"

    repository_ctx.report_progress(
        "Resolving pub dependencies for {}".format(package_name),
    )

    deps_result = repository_ctx.execute(
        command + ["deps", "--json"],
        working_directory = workdir,
        environment = run_env,
        quiet = True,
    )
    if deps_result.return_code != 0:
        fail("Failed to run `{tool} pub deps --json` for package '{pkg}' (dir: {dir}).\nstdout: {stdout}\nstderr: {stderr}".format(
            tool = tool,
            pkg = package_name,
            dir = package_dir,
            stdout = deps_result.stdout,
            stderr = deps_result.stderr,
        ))

    # Write the generated JSON payload (strip any leading log lines).
    output = deps_result.stdout
    json_start = -1
    for idx in range(len(output)):
        ch = output[idx]
        if ch == "{" or ch == "[":
            json_start = idx
            break
    if json_start == -1:
        fail("`{tool} pub deps --json` for package '{pkg}' did not produce JSON output.\nstdout: {stdout}\nstderr: {stderr}".format(
            tool = tool,
            pkg = package_name,
            stdout = deps_result.stdout,
            stderr = deps_result.stderr,
        ))

    json_text = output[json_start:]
    if not json_text.endswith("\n"):
        json_text += "\n"
    repository_ctx.file(pub_deps_rel, json_text)

def _find_pub_command(repository_ctx):
    """Locate a flutter or dart executable and return the pub command prefix."""

    os_name = repository_ctx.os.name.lower()
    flutter_candidates = [
        "flutter/bin/flutter",
        "bin/flutter",
        "flutter/bin/flutter.bat",
        "bin/flutter.bat",
    ]
    dart_candidates = [
        "flutter/bin/cache/dart-sdk/bin/dart",
        "bin/dart",
        "flutter/bin/cache/dart-sdk/bin/dart.exe",
        "bin/dart.exe",
    ]

    for candidate in flutter_candidates:
        path = repository_ctx.path(candidate)
        if path.exists:
            return _pub_command_prefix(str(path)), "flutter"

    host_flutter = repository_ctx.which("flutter.bat" if os_name.startswith("windows") else "flutter")
    if host_flutter:
        return _pub_command_prefix(str(host_flutter)), "flutter"

    for candidate in dart_candidates:
        path = repository_ctx.path(candidate)
        if path.exists:
            return _pub_command_prefix(str(path)), "dart"

    host_dart = repository_ctx.which("dart.exe" if os_name.startswith("windows") else "dart")
    if host_dart:
        return _pub_command_prefix(str(host_dart)), "dart"

    return None, None

def _pub_command_prefix(executable):
    if executable.endswith(".bat") or executable.endswith(".cmd"):
        return ["cmd.exe", "/c", "\"{}\"".format(executable), "pub"]
    return [executable, "pub"]

def generate_package_build(repository_ctx, package_name, package_dir = ".", sdk_repo = None, include_hosted_deps = False):
    """Generate a BUILD.bazel for the given package directory.

    Args:
        repository_ctx: Repository rule context.
        package_name: The Bazel target / Dart package name.
        package_dir: Relative directory containing the package ("." for root).
        sdk_repo: Optional repository label used to resolve SDK-provided
            dependencies (e.g. `@flutter_macos`). When omitted, a sensible
            default for the current host platform is used.
        include_hosted_deps: When true, emit hosted pub.dev dependencies from
            pub_deps.json as external repositories. Flutter SDK packages set
            this to False because their hosted deps are already vendored in the
            SDK and should not pull from pub.dev.
    """

    _ensure_pub_deps(repository_ctx, package_name, package_dir)
    rule_kind = _determine_rule_kind(repository_ctx, package_dir)
    srcs = _collect_lib_sources(repository_ctx, package_dir)
    deps = _collect_direct_deps(
        repository_ctx,
        package_dir,
        sdk_repo,
        include_hosted_deps = include_hosted_deps,
    )

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

def _collect_direct_deps(repository_ctx, package_dir, sdk_repo, include_hosted_deps = True):
    """Return Bazel labels for direct dependencies sourced from pub or the SDK.

    Args:
        repository_ctx: Repository rule context.
        package_dir: Relative location of the package being generated.
        sdk_repo: Repository label to use for Flutter SDK provided packages.
        include_hosted_deps: Whether hosted pub.dev dependencies should be
            emitted as external repos (True) or skipped (False).
    """

    deps_rel = "pub_deps.json" if package_dir in (".", "") else package_dir + "/pub_deps.json"
    deps_path = repository_ctx.path(deps_rel)
    if not deps_path.exists:
        return []

    packages = _parse_pub_deps(repository_ctx.read(deps_rel))
    deps = []
    for pkg, info in packages.items():
        dep_kind = info.get("dependency", "") or ""
        if not dep_kind.startswith("direct"):
            continue

        source = info.get("source")
        if source == "hosted":
            if not include_hosted_deps:
                continue
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

def _parse_pub_deps(content):
    """Parse flutter pub deps --json output into a dict of package metadata."""

    data = json.decode(content)
    packages = {}
    for entry in data.get("packages", []):
        name = entry.get("name")
        if not name:
            continue

        source = entry.get("source")
        dependency = entry.get("dependency") or entry.get("kind")
        version = entry.get("version")
        description = entry.get("description")
        url = _description_url(description)
        if source == "hosted" and not url:
            url = "https://pub.dev"

        packages[name] = {
            "dependency": dependency,
            "source": source,
            "version": version,
            "url": url,
        }

    return packages

def _description_url(description):
    if type(description) == "string":
        return description
    if type(description) == "dict":
        return (
            description.get("url") or
            description.get("base_url") or
            description.get("hosted_url") or
            description.get("hosted-url")
        )
    return None
