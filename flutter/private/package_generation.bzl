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

def _ensure_pub_deps(repository_ctx, package_name, package_dir, allow_fallback_on_failure = False):
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
        return False

    # Some packages publish with a leftover `resolution: workspace` marker
    # (pub workspaces). It only makes sense inside the source monorepo and
    # causes `pub deps` to refuse to resolve the package standalone.
    pubspec_content = repository_ctx.read(pubspec_rel)
    if pubspec_content.lstrip().startswith("resolution:") or "\nresolution:" in pubspec_content:
        stripped_lines = [
            line
            for line in pubspec_content.splitlines()
            if not line.startswith("resolution:")
        ]
        repository_ctx.file(pubspec_rel, "\n".join(stripped_lines) + "\n")

    pub_deps_path = repository_ctx.path(pub_deps_rel)
    if pub_deps_path.exists:
        content = repository_ctx.read(pub_deps_rel)
        if content.strip():
            return False

    command, tool = _find_pub_command(repository_ctx)
    if not command:
        repository_ctx.report_progress(
            "No Dart or Flutter executable found for {}; falling back to pubspec.yaml dependency metadata".format(package_name),
        )
        _write_fallback_pub_deps(repository_ctx, package_name, package_dir, pub_deps_rel)
        return True

    workdir = str(repository_ctx.path(package_dir if package_dir not in (".", "") else "."))
    run_env = {
        "PUB_CACHE": str(repository_ctx.path(pub_cache_rel)),
        "PUB_ENVIRONMENT": "rules_flutter:repository",
    }
    if tool == "flutter":
        run_env["FLUTTER_SUPPRESS_ANALYTICS"] = "true"
        run_env["FLUTTER_UPDATE_DISABLED"] = "true"
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
        stderr = deps_result.stderr or ""

        # Packages such as `package:http` reference dev-only path dependencies that
        # are not present in the published archive. In those cases, flutter pub deps
        # fails with a path resolution error. Allow falling back to pubspec parsing
        # so repository generation can continue.
        lower_stderr = stderr.lower()
        unsupported_path_dep = "path" in lower_stderr and (
            "could not find package" in lower_stderr or
            "which doesn't exist" in lower_stderr
        )
        unsupported_sdk_dep = "from sdk" in lower_stderr and (
            "could not find package" in lower_stderr or
            "doesn't exist" in lower_stderr or
            "doesn't match any versions" in lower_stderr
        )

        # Pre-null-safety packages (e.g. `color` 3.0.0) ship SDK constraints a
        # modern pub solver refuses outright; their metadata can still be read
        # from pubspec.yaml.
        unresolvable_sdk_constraint = (
            "null safety" in lower_stderr or
            "try using the dart sdk version" in lower_stderr
        )
        if unsupported_path_dep or unsupported_sdk_dep or unresolvable_sdk_constraint:
            repository_ctx.report_progress(
                "Skipping pub deps generation for {} due to unsupported dependency source; falling back to pubspec.yaml".format(package_name),
            )
            _write_fallback_pub_deps(repository_ctx, package_name, package_dir, pub_deps_rel)
            return True
        if allow_fallback_on_failure:
            repository_ctx.report_progress(
                "Skipping pub deps generation for {} after pub failed; falling back to pubspec.yaml".format(package_name),
            )
            _write_fallback_pub_deps(repository_ctx, package_name, package_dir, pub_deps_rel)
            return True
        fail("Failed to run `{tool} pub deps --json` for package '{pkg}' (dir: {dir}).\nstdout: {stdout}\nstderr: {stderr}".format(
            tool = tool,
            pkg = package_name,
            dir = package_dir,
            stdout = deps_result.stdout,
            stderr = stderr,
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
    return True

def _write_fallback_pub_deps(repository_ctx, package_name, package_dir, pub_deps_rel):
    """Write minimal dependency metadata from pubspec.yaml when pub cannot solve."""

    metadata = _parse_pubspec_metadata(repository_ctx, package_dir)
    root_name = metadata.get("name") or package_name
    root_version = metadata.get("version") or "0.0.0"

    packages = [
        {
            "name": root_name,
            "version": root_version,
            "source": "root",
            "dependency": "root",
            "description": {"path": "."},
        },
    ]

    for dep in _parse_pubspec_dependencies(repository_ctx, package_dir):
        entry = {
            "name": dep["name"],
            "source": dep["source"],
            "dependency": "direct main",
        }
        if dep["source"] == "path":
            entry["description"] = {"path": dep.get("path", "")}
        elif dep["source"] == "sdk":
            entry["description"] = dep.get("sdk", "")
        packages.append(entry)

    repository_ctx.file(pub_deps_rel, json.encode({"packages": packages}) + "\n")

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

    for candidate in dart_candidates:
        path = repository_ctx.path(candidate)
        if path.exists:
            return _pub_command_prefix(str(path)), "dart"

    host_dart = repository_ctx.which("dart.exe" if os_name.startswith("windows") else "dart")
    if host_dart:
        return _pub_command_prefix(str(host_dart)), "dart"

    host_flutter = repository_ctx.which("flutter.bat" if os_name.startswith("windows") else "flutter")
    if host_flutter:
        return _pub_command_prefix(str(host_flutter)), "flutter"

    return None, None

def _pub_command_prefix(executable):
    if executable.endswith(".bat") or executable.endswith(".cmd"):
        return ["cmd.exe", "/c", "\"{}\"".format(executable), "pub"]
    return [executable, "pub"]

def generate_package_build(repository_ctx, package_name, package_dir = ".", sdk_repo = "@flutter_sdk", include_hosted_deps = True, include_pub_cache_data = False):
    """Generate a BUILD.bazel for the given package directory.

    Args:
        repository_ctx: Repository rule context.
        package_name: The Bazel target / Dart package name.
        package_dir: Relative directory containing the package ("." for root).
        sdk_repo: Optional repository label used to resolve SDK-provided
            dependencies (e.g. `@flutter_sdk`). When omitted, a sensible
            default for the current host platform is used.
        include_hosted_deps: When true, emit hosted pub.dev dependencies from
            pub_deps.json as external repositories. Flutter SDK packages pass
            False because their hosted deps are already vendored in the SDK and
            should not pull from pub.dev.
        include_pub_cache_data: When true and the package contains a local
            `.pub_cache`, expose it as data so package preparation can publish
            those vendored artifacts transitively.
    """

    _ensure_pub_deps(
        repository_ctx,
        package_name,
        package_dir,
        allow_fallback_on_failure = not include_hosted_deps,
    )
    rule_kind = _determine_rule_kind(repository_ctx, package_dir)
    srcs = _collect_lib_sources(repository_ctx, package_dir)
    metadata_files = _collect_metadata_files(repository_ctx, package_dir)
    deps = _collect_direct_deps(
        repository_ctx,
        package_dir,
        sdk_repo,
        include_hosted_deps = include_hosted_deps,
    )
    pub_cache_files_target = None
    if include_pub_cache_data and _package_pub_cache_exists(repository_ctx, package_dir):
        pub_cache_files_target = "_pub_cache_files"

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
    lines.append('    pub_deps = "pub_deps.json",')

    if deps:
        lines.append("    deps = [")
        for dep in deps:
            lines.append('        "{}",'.format(dep))
        lines.append("    ],")

    data_entries = ['"{}"'.format(name) for name in metadata_files]
    if pub_cache_files_target:
        data_entries.append('":{}"'.format(pub_cache_files_target))
    if data_entries:
        lines.append("    data = [{}],".format(", ".join(data_entries)))

    if rule_kind == "dart_library":
        lines.append("    pub_package = True,")

    lines.append(_DEF_VISIBILITY)
    lines.append(")")

    if pub_cache_files_target:
        lines.extend([
            "",
            "filegroup(",
            '    name = "{}",'.format(pub_cache_files_target),
            '    srcs = glob([".pub_cache/**"]),',
            ")",
        ])

    lines.extend([
        "",
        "alias(",
        '    name = "lib",',
        '    actual = ":{}",'.format(package_name),
        _DEF_VISIBILITY,
        ")",
        "",
        "filegroup(",
        '    name = "{}_files",'.format(package_name),
        '    srcs = glob(["**/*"], exclude = ["BUILD", "BUILD.bazel"]),',
        _DEF_VISIBILITY,
        ")",
    ])

    build_path = "BUILD.bazel" if package_dir in (".", "") else package_dir + "/BUILD.bazel"
    repository_ctx.file(build_path, "\n".join(lines) + "\n")

def _package_pub_cache_exists(repository_ctx, package_dir):
    pub_cache_rel = ".pub_cache" if package_dir in (".", "") else package_dir + "/.pub_cache"
    pub_cache_path = repository_ctx.path(pub_cache_rel)
    return pub_cache_path.exists and pub_cache_path.is_dir

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

def _parse_pubspec_metadata(repository_ctx, package_dir):
    """Extract root package metadata from pubspec.yaml."""

    pubspec_rel = "pubspec.yaml" if package_dir in (".", "") else package_dir + "/pubspec.yaml"
    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return {}

    metadata = {}
    for raw_line in repository_ctx.read(pubspec_rel).splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        key = key.strip()
        if key in ["name", "version"]:
            metadata[key] = value.strip().strip("'\"")
        if "name" in metadata and "version" in metadata:
            break

    return metadata

def _collect_lib_sources(repository_ctx, package_dir):
    """Collect Dart sources needed for a generated pub package target."""

    source_roots = []
    for source_dir in ["lib", "bin"]:
        rel = source_dir if package_dir in (".", "") else package_dir + "/" + source_dir
        path = repository_ctx.path(rel)
        if path.exists and path.is_dir:
            source_roots.append((source_dir, path))

    if not source_roots:
        return []

    python = repository_ctx.which("python3") or repository_ctx.which("python")
    if not python:
        fail("Unable to locate python3 to enumerate Dart sources")

    sources = []
    for source_dir, root_path in source_roots:
        result = repository_ctx.execute([
            python,
            "-c",
            _LIB_DISCOVERY_SCRIPT,
            str(root_path),
        ], quiet = True)

        if result.return_code:
            fail(
                "Failed to enumerate {}/ sources (code {}): {}".format(
                    source_dir,
                    result.return_code,
                    result.stderr or result.stdout,
                ),
            )

        for line in result.stdout.splitlines():
            line = line.strip()
            if line and line.endswith(".dart"):
                sources.append("{}/{}".format(source_dir, line))

    return sorted(sources)

def _collect_metadata_files(repository_ctx, package_dir):
    """Top-level metadata files that must reach the assembled pub cache.

    build.yaml carries builder definitions that build_runner discovers from
    the cache copy of the package.
    """
    found = []
    for name in ["build.yaml"]:
        rel = name if package_dir in (".", "") else package_dir + "/" + name
        if repository_ctx.path(rel).exists:
            found.append(name)
    return found

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
    packages = None
    if deps_path.exists:
        packages = _parse_pub_deps(repository_ctx.read(deps_rel))

    if not packages:
        fallback_packages = _parse_pubspec_dependencies(repository_ctx, package_dir)
    else:
        fallback_packages = None

    deps = []
    if packages:
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
                label = _sdk_dep_label(package_dir, pkg, sdk_repo)
                if label:
                    deps.append(label)
    elif fallback_packages:
        for entry in fallback_packages:
            pkg = entry["name"]
            source = entry["source"]
            if source == "hosted":
                if not include_hosted_deps:
                    continue
                repo_name = _sanitize_repo_name(pkg)
                deps.append("@{}//:{}".format(repo_name, pkg))
            elif source == "sdk":
                label = _sdk_dep_label(package_dir, pkg, sdk_repo)
                if label:
                    deps.append(label)

    return sorted(deps)

def _parse_pubspec_dependencies(repository_ctx, package_dir):
    """Fallback parser to extract dependencies from pubspec.yaml when pub_deps.json is unavailable."""

    pubspec_rel = "pubspec.yaml" if package_dir in (".", "") else package_dir + "/pubspec.yaml"
    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return []

    content = repository_ctx.read(pubspec_rel).splitlines()
    deps = []
    in_deps = False
    deps_indent = 0
    current_name = ""
    current_indent = 0
    current_block = None

    for raw_line in content:
        stripped = raw_line.strip()
        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if not stripped or stripped.startswith("#"):
            continue

        if not in_deps:
            if stripped == "dependencies:":
                in_deps = True
                deps_indent = indent
            continue

        if indent <= deps_indent:
            if current_name:
                if current_block != None and "path" in current_block:
                    deps.append({"name": current_name, "source": "path", "path": current_block.get("path")})
                elif current_block != None and current_block.get("sdk"):
                    deps.append({"name": current_name, "source": "sdk", "sdk": current_block.get("sdk")})
                elif current_name:
                    deps.append({"name": current_name, "source": "hosted"})
            current_name = ""
            current_block = None

            # End of the dependencies block.
            break

        if current_name and indent > current_indent:
            if ":" in stripped:
                sub_key, sub_value = stripped.split(":", 1)
                if current_block == None:
                    current_block = {}
                current_block[sub_key.strip()] = sub_value.strip().strip("'\"")
            continue

        if ":" not in stripped:
            continue

        name, remainder = stripped.split(":", 1)
        name = name.strip()
        remainder = remainder.strip()
        entry_indent = indent

        if not name:
            continue

        if current_name:
            if current_block != None and "path" in current_block:
                deps.append({"name": current_name, "source": "path", "path": current_block.get("path")})
            elif current_block != None and current_block.get("sdk"):
                deps.append({"name": current_name, "source": "sdk", "sdk": current_block.get("sdk")})
            else:
                deps.append({"name": current_name, "source": "hosted"})
            current_block = None
        current_name = name
        current_indent = entry_indent

        if remainder:
            deps.append({"name": current_name, "source": "hosted"})
            current_name = ""
            current_block = None
        else:
            current_block = {}

    if current_name:
        if current_block != None and "path" in current_block:
            deps.append({"name": current_name, "source": "path", "path": current_block.get("path")})
        elif current_block != None and current_block.get("sdk"):
            deps.append({"name": current_name, "source": "sdk", "sdk": current_block.get("sdk")})
        elif current_name:
            deps.append({"name": current_name, "source": "hosted"})

    return deps

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

def _sdk_dep_label(package_dir, pkg, sdk_repo):
    path = _sdk_package_path(pkg)
    if not path:
        return None

    if package_dir.startswith("flutter/"):
        return "//{}:{}".format(path, pkg)

    return "{}//{}:{}".format(sdk_repo, path, pkg)

def _sdk_package_path(pkg):
    if pkg == "sky_engine":
        return "flutter/bin/cache/pkg/{}".format(pkg)
    if pkg == "_macros":
        # `_macros` is provided by the Dart SDK internals and does not live under flutter/packages.
        return None
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
