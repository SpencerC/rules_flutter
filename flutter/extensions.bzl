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
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = "Explicit version of flutter.", mandatory = True),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(toolchain.flutter_version)
    for name, versions in registrations.items():
        if len(versions) > 1:
            # TODO: should be semver-aware, using MVS
            selected = sorted(versions, reverse = True)[0]

            # buildifier: disable=print
            print("NOTE: flutter toolchain {} has multiple versions {}, selected {}".format(name, versions, selected))
        else:
            selected = versions[0]

        flutter_register_toolchains(
            name = name,
            flutter_version = selected,
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

_LOCKFILE_DISCOVERY_SCRIPT = """
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
    if "pubspec.lock" in filenames:
        results.append(os.path.join(dirpath, "pubspec.lock"))

for path in sorted(results):
    print(path)
"""

def _module_root(module_ctx, mod):
    """Return the filesystem root for the given module."""
    module_name = mod.name or ""
    label = "@@{}//:MODULE.bazel".format(module_name)
    module_file = module_ctx.path(Label(label))
    return module_file.dirname

def _execute_lockfile_scan(module_ctx, root):
    """Run a python helper to locate pubspec.lock files under the module root."""
    python = module_ctx.which("python3") or module_ctx.which("python")
    if not python:
        fail("Unable to locate python3 or python on PATH while scanning pubspec.lock files")

    result = module_ctx.execute([
        python,
        "-c",
        _LOCKFILE_DISCOVERY_SCRIPT,
        str(root),
    ], quiet = True)

    if result.return_code != 0:
        fail(
            "pub extension failed to scan {} for pubspec.lock files (code {}):\nstdout: {}\nstderr: {}".format(
                str(root),
                result.return_code,
                result.stdout,
                result.stderr,
            ),
        )

    lockfiles = [line for line in result.stdout.splitlines() if line]
    return [module_ctx.path(path) for path in lockfiles]

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

def _commit_package(packages, package, source, version, url):
    if package and source == "hosted" and version:
        packages[package] = {
            "version": version,
            "url": url or "https://pub.dev",
        }

def _parse_pubspec_lock(content):
    """Return mapping of package -> (version, url) from a pubspec.lock payload."""
    packages = {}
    in_packages = False
    current_pkg = None
    current_source = None
    current_version = None
    current_url = None

    for raw_line in content.splitlines():
        if not in_packages:
            if raw_line.strip() == "packages:":
                in_packages = True
            continue

        if raw_line and not raw_line.startswith(" "):
            _commit_package(packages, current_pkg, current_source, current_version, current_url)
            in_packages = False
            current_pkg = None
            current_source = None
            current_version = None
            current_url = None
            continue

        if raw_line.startswith("  ") and not raw_line.startswith("    "):
            _commit_package(packages, current_pkg, current_source, current_version, current_url)
            current_pkg = raw_line.strip().rstrip(":")
            current_source = None
            current_version = None
            current_url = None
            continue

        if not current_pkg:
            continue

        stripped = raw_line.strip()
        if stripped.startswith("source:"):
            current_source = stripped.split(":", 1)[1].strip().strip('"\'')
        elif stripped.startswith("version:"):
            current_version = stripped.split(":", 1)[1].strip().strip('"\'')
        elif stripped.startswith("url:"):
            current_url = stripped.split(":", 1)[1].strip().strip('"\'')

    _commit_package(packages, current_pkg, current_source, current_version, current_url)
    return packages

def _register_repo(repo_map, repo_name, package, version, origin):
    """Merge repository metadata ensuring consistency across lockfiles/tags."""
    existing = repo_map.get(repo_name)
    if existing:
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
    }

def _pub_extension(module_ctx):
    """Extension implementation for pub.dev packages."""
    repos = {}
    scanned_roots = {}

    for mod in module_ctx.modules:
        root = _module_root(module_ctx, mod)
        root_key = str(root)
        if root_key in scanned_roots:
            continue
        scanned_roots[root_key] = True
        lockfiles = _execute_lockfile_scan(module_ctx, root)
        for lockfile in lockfiles:
            module_ctx.watch(lockfile)
            packages = _parse_pubspec_lock(module_ctx.read(lockfile))
            for package, info in packages.items():
                repo_name = _sanitize_repo_name(package)
                origin = "{} (pubspec.lock)".format(str(lockfile))
                _register_repo(
                    repos,
                    repo_name,
                    package,
                    info.get("version"),
                    origin,
                )

    for mod in module_ctx.modules:
        for pkg in mod.tags.package:
            origin = "MODULE.bazel:{}".format(pkg.name)
            _register_repo(
                repos,
                pkg.name,
                pkg.package,
                pkg.version,
                origin,
            )

    for repo_name in sorted(repos.keys()):
        meta = repos[repo_name]
        pub_dev_repository(
            name = repo_name,
            package = meta["package"],
            version = meta["version"],
        )

pub = module_extension(
    implementation = _pub_extension,
    tag_classes = {"package": pub_package},
)
