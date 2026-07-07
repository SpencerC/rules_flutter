"""Extensions for bzlmod.

Installs a flutter toolchain.
Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("//flutter/private:pub_repository.bzl", "pub_dev_repository")
load("//flutter/private:version_select.bzl", "highest_version")
load("//flutter/private:versions.bzl", "TOOL_VERSIONS")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = "Explicit version of flutter.", mandatory = True),
    "precache": attr.string_list(doc = """\
Artifact groups (web, android, ios, macos, linux, windows) that must be present
in the SDK cache after fetch. Stable archives already ship these; when one is
missing, `flutter precache` runs at repository fetch time. Unioned across
registrations of the same toolchain name.
""", default = []),
    "integrity": attr.string_dict(doc = """\
Escape hatch for Flutter versions not in the built-in version table: a map
from platform (macos, linux, windows) to the SRI integrity of that platform's
stable release archive, e.g. {"macos": "sha256-...", "linux": "sha256-..."}.
Only the platforms you actually build on need an entry (the per-platform SDK
repositories are fetched lazily). When flutter_version is in the built-in
table this may be omitted. Merged across registrations of the same name.
""", default = {}),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    precache_groups = {}
    integrity_overrides = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
                precache_groups[toolchain.name] = {}
                integrity_overrides[toolchain.name] = {}
            registrations[toolchain.name].append(toolchain.flutter_version)
            for group in toolchain.precache:
                precache_groups[toolchain.name][group] = True

            # Integrity is bound to the (name, version) it was declared for, so
            # a map declared for one version is never applied to a different
            # version that happens to win selection.
            if toolchain.integrity:
                by_version = integrity_overrides[toolchain.name]
                if toolchain.flutter_version not in by_version:
                    by_version[toolchain.flutter_version] = {}
                for platform, sri in toolchain.integrity.items():
                    by_version[toolchain.flutter_version][platform] = sri
    for name, versions in registrations.items():
        # Deduplicate versions to avoid noise when the same version is registered multiple times
        unique_versions = {v: True for v in versions}.keys()
        if len(unique_versions) > 1:
            # Highest requested version wins (MVS: every module gets at least
            # the version it asked for), compared semver-aware not lexically.
            selected = highest_version(unique_versions)

            # buildifier: disable=print
            print("NOTE: flutter toolchain {} has multiple versions {}, selected {}".format(name, list(unique_versions), selected))
        else:
            selected = versions[0]

        # Only integrity declared for the selected version applies.
        overrides = integrity_overrides[name].get(selected, {})
        if selected not in TOOL_VERSIONS and not overrides:
            fail(("rules_flutter: Flutter {} is not in the built-in version table. " +
                  "Register it with an integrity map, e.g. " +
                  "flutter.toolchain(flutter_version = \"{}\", integrity = {{\"macos\": \"sha256-...\", \"linux\": \"sha256-...\"}}). " +
                  "Compute each SRI from the stable archive at " +
                  "https://storage.googleapis.com/flutter_infra_release/releases/stable/<platform>/flutter_<platform>_{}-stable.<ext>.").format(selected, selected, selected))

        flutter_register_toolchains(
            name = name,
            flutter_version = selected,
            precache = sorted(precache_groups[name].keys()),
            integrity = overrides,
            register = False,
        )

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {"toolchain": flutter_toolchain},
)

# Pub.dev package management extension
pub_package = tag_class(attrs = {
    "name": attr.string(doc = "Repository name for the package", mandatory = True),
    "package": attr.string(doc = "Package name on pub.dev", mandatory = True),
    "version": attr.string(doc = "Package version (optional, defaults to latest)"),
})

_DEPS_DISCOVERY_SCRIPT = """
import os
import sys

root = os.path.realpath(sys.argv[1])
results = []

SKIP_PREFIXES = ("bazel-",)
SKIP_NAMES = {".git", ".hg", ".svn", ".dart_tool"}

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [
        name
        for name in dirnames
        if not name.startswith(SKIP_PREFIXES) and name not in SKIP_NAMES
    ]
    if "pub_deps.json" in filenames:
        results.append(os.path.join(dirpath, "pub_deps.json"))

for path in sorted(results):
    print(path)
"""

def _module_root(module_ctx, mod):
    """Return the filesystem root for the given module."""
    module_name = mod.name or ""
    if mod.is_root:
        label = "@@//:MODULE.bazel"
    else:
        label = "@@{}//:MODULE.bazel".format(module_name)
    module_file = module_ctx.path(Label(label))
    return module_file.dirname

def _execute_deps_scan(module_ctx, root):
    """Run a python helper to locate pub_deps.json files under the module root."""
    python = module_ctx.which("python3") or module_ctx.which("python")
    if not python:
        fail("Unable to locate python3 or python on PATH while scanning pub_deps.json files")

    result = module_ctx.execute([
        python,
        "-c",
        _DEPS_DISCOVERY_SCRIPT,
        str(root),
    ], quiet = True)

    if result.return_code != 0:
        fail(
            "pub extension failed to scan {} for pub_deps.json files (code {}):\nstdout: {}\nstderr: {}".format(
                str(root),
                result.return_code,
                result.stdout,
                result.stderr,
            ),
        )

    deps_files = [line for line in result.stdout.splitlines() if line]
    return [module_ctx.path(path) for path in deps_files]

def _sanitize_repo_name(package):
    """Generate a deterministic repository name for a package."""

    def _is_valid_char(ch):
        return (
            ("a" <= ch and ch <= "z") or
            ("A" <= ch and ch <= "Z") or
            ("0" <= ch and ch <= "9") or
            ch == "_"
        )

    sanitized = []
    for idx in range(len(package)):
        ch = package[idx]
        sanitized.append(ch if _is_valid_char(ch) else "_")
    return "pub_" + "".join(sanitized)

def _parse_pub_deps_json(content):
    """Return mapping of package -> metadata from pub_deps.json payload."""

    data = json.decode(content)
    packages = {}
    for entry in data.get("packages", []):
        name = entry.get("name")
        if not name:
            continue

        source = entry.get("source")
        version = entry.get("version")
        description = entry.get("description")
        url = _extract_description_url(description)
        if source == "hosted" and version:
            packages[name] = {
                "version": version,
                "url": url or "https://pub.dev",
                "dependencies": [dep for dep in entry.get("dependencies", []) if type(dep) == "string"],
            }

    return packages

def _prune_dependency_cycles(edges):
    """Return edges with back edges removed via iterative DFS.

    The pub universe contains genuine dependency cycles (e.g. dio <->
    dio_web_adapter) that Bazel target graphs cannot express. Dropping the
    back edge keeps cache propagation intact for any consumer that reaches
    the cycle through its conventional entry point.
    """
    UNVISITED = 0
    ON_STACK = 1
    DONE = 2

    state = {name: UNVISITED for name in edges.keys()}
    pruned = {name: [] for name in edges.keys()}

    for root in sorted(edges.keys()):
        if state[root] != UNVISITED:
            continue

        # Each stack frame is [node, next_child_index].
        stack = [[root, 0]]
        state[root] = ON_STACK
        for _ in range(1000000):  # bounded loop: Starlark has no while
            if not stack:
                break
            frame = stack[-1]
            node, idx = frame[0], frame[1]
            children = edges[node]
            if idx >= len(children):
                state[node] = DONE
                stack.pop()
                continue
            frame[1] = idx + 1
            child = children[idx]
            if child not in state:
                continue
            if state[child] == ON_STACK:
                # Back edge: dropping it breaks the cycle.
                continue
            pruned[node].append(child)
            if state[child] == UNVISITED:
                state[child] = ON_STACK
                stack.append([child, 0])

    return pruned

def _extract_description_url(description):
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

def _register_repo(repo_map, repo_name, package, version, origin, from_root = True, tagged = False):
    """Merge repository metadata ensuring consistency across lockfiles/tags.

    Root-module registrations (pub_deps.json scans and root pub.package tags)
    take precedence: a conflicting non-root tag — e.g. a ruleset pinning a
    default tooling version — is silently ignored when the root already pinned
    the package. A repository registered through any pub.package tag is marked
    `tagged` (it keeps its fetch-time vendored .pub_cache so it can be
    executed from the repository), regardless of which registration's version
    wins.
    """
    existing = repo_map.get(repo_name)
    if existing:
        if tagged:
            existing["tagged"] = True
        if not from_root and existing["from_root"]:
            return
        if from_root and not existing["from_root"]:
            repo_map[repo_name] = {
                "package": package,
                "version": version,
                "origins": [origin],
                "from_root": True,
                "tagged": existing["tagged"] or tagged,
            }
            return
        if existing["package"] != package:
            fail(
                "Repository '{}' resolves to multiple packages: '{}' from {} vs '{}' from {}".format(
                    repo_name,
                    existing["package"],
                    ", ".join(existing["origins"]),
                    package,
                    origin,
                ),
            )
        if version and existing["version"] and version != existing["version"]:
            fail(
                "Repository '{}' has conflicting versions: '{}' from {} vs '{}' from {}".format(
                    repo_name,
                    existing["version"],
                    ", ".join(existing["origins"]),
                    version,
                    origin,
                ),
            )
        if version and not existing["version"]:
            existing["version"] = version
        existing["origins"].append(origin)
        return

    repo_map[repo_name] = {
        "package": package,
        "version": version,
        "origins": [origin],
        "from_root": from_root,
        "tagged": tagged,
    }

def _pub_extension(module_ctx):
    """Extension implementation for pub.dev packages."""
    repos = {}
    scanned_roots = {}
    dep_edges = {}

    for mod in module_ctx.modules:
        if not mod.is_root:
            continue
        root = _module_root(module_ctx, mod)
        root_key = str(root)
        if root_key in scanned_roots:
            continue
        scanned_roots[root_key] = True
        deps_files = _execute_deps_scan(module_ctx, root)
        for deps_file in deps_files:
            module_ctx.watch(deps_file)
            packages = _parse_pub_deps_json(module_ctx.read(deps_file))
            for package, info in packages.items():
                repo_name = _sanitize_repo_name(package)
                origin = "{} (pub_deps.json)".format(str(deps_file))
                _register_repo(
                    repos,
                    repo_name,
                    package,
                    info.get("version"),
                    origin,
                )
                merged = {dep: True for dep in dep_edges.get(package, [])}
                for dep in info.get("dependencies", []):
                    merged[dep] = True
                dep_edges[package] = sorted(merged.keys())

    for mod in module_ctx.modules:
        for pkg in mod.tags.package:
            origin = "{}/MODULE.bazel:{}".format(mod.name or "root", pkg.name)
            _register_repo(
                repos,
                pkg.name,
                pkg.package,
                pkg.version,
                origin,
                from_root = mod.is_root,
                tagged = True,
            )

    # Restrict recorded edges to hosted packages that actually have repos and
    # break dependency cycles so the generated target graph is a DAG.
    known_packages = {meta["package"]: True for meta in repos.values()}
    hosted_edges = {
        package: [dep for dep in deps if dep in known_packages]
        for package, deps in dep_edges.items()
    }
    pruned_edges = _prune_dependency_cycles(hosted_edges)

    for repo_name in sorted(repos.keys()):
        meta = repos[repo_name]
        package = meta["package"]
        if package in pruned_edges:
            pub_dev_repository(
                name = repo_name,
                package = package,
                version = meta["version"],
                hosted_deps = pruned_edges[package],
                hosted_deps_explicit = True,
                keep_vendored_cache = meta["tagged"],
                resolve_deps = meta["tagged"],
            )
        else:
            pub_dev_repository(
                name = repo_name,
                package = package,
                version = meta["version"],
                keep_vendored_cache = meta["tagged"],
                resolve_deps = meta["tagged"],
            )

pub = module_extension(
    implementation = _pub_extension,
    tag_classes = {"package": pub_package},
)
