"""Repository utilities for Flutter toolchains used via bzlmod."""

load("//flutter/private:package_generation.bzl", "generate_package_build")
load("//flutter/private:sdk_repo.bzl", "flutter_sdk_repo")
load("//flutter/private:toolchains_repo.bzl", "PLATFORMS", "toolchains_repo")
load("//flutter/private:versions.bzl", "TOOL_VERSIONS")

########
# Repository rules used by the module extension to support toolchains.
########
_DOC = "Fetch external tools needed for flutter toolchain"
_ATTRS = {
    "flutter_version": attr.string(mandatory = True, values = TOOL_VERSIONS.keys()),
    "platform": attr.string(mandatory = True, values = PLATFORMS.keys()),
    "precache": attr.string_list(
        default = [],
        doc = """Artifact groups that must exist in the SDK cache after fetch
(any of: web, android, ios, macos, linux, windows). Stable release archives
already ship all of these except cross-OS desktop artifacts, so this normally
verifies sentinel paths without running anything. When a sentinel is missing
and the repository platform matches the host, `flutter precache` runs at fetch
time (network is available to repository rules).""",
    ),
}

# Sentinel paths (relative to flutter/bin/cache) proving an artifact group is
# already present in the extracted archive.
_PRECACHE_SENTINELS = {
    "android": "artifacts/engine/android-arm64-release",
    "ios": "artifacts/engine/ios-release",
    "linux": "artifacts/engine/linux-x64-release",
    "macos": "artifacts/engine/darwin-x64-release",
    "web": "flutter_web_sdk",
    "windows": "artifacts/engine/windows-x64-release",
}

# The tail of bin/internal/update_engine_version.sh that unconditionally
# rewrites engine.stamp/engine.realm on every launcher invocation. Replaced at
# fetch time so `flutter` never writes into the Bazel external repository.
_ENGINE_VERSION_WRITE_ORIGINAL = """# Write the engine version out so downstream tools know what to look for.
echo $ENGINE_VERSION >"$FLUTTER_ROOT/bin/cache/engine.stamp"

# The realm on CI is passed in.
if [ -n "${FLUTTER_REALM}" ]; then
  echo $FLUTTER_REALM >"$FLUTTER_ROOT/bin/cache/engine.realm"
else
  echo "" >"$FLUTTER_ROOT/bin/cache/engine.realm"
fi"""

_ENGINE_VERSION_WRITE_PATCHED = """# Write the engine version out so downstream tools know what to look for.
# Patched by rules_flutter: skip writes when the content is already correct so
# launcher invocations never mutate the Bazel external repository.
if [ "$(cat "$FLUTTER_ROOT/bin/cache/engine.stamp" 2>/dev/null)" != "$ENGINE_VERSION" ]; then
  echo $ENGINE_VERSION >"$FLUTTER_ROOT/bin/cache/engine.stamp"
fi

# The realm on CI is passed in.
FLUTTER_REALM="${FLUTTER_REALM:-}"
if [ "$(cat "$FLUTTER_ROOT/bin/cache/engine.realm" 2>/dev/null)" != "$FLUTTER_REALM" ]; then
  echo $FLUTTER_REALM >"$FLUTTER_ROOT/bin/cache/engine.realm"
fi"""

def _patch_engine_version_script(repository_ctx):
    """Make the launcher's engine-version refresh write-free when unchanged."""
    script_path = "flutter/bin/internal/update_engine_version.sh"
    if not repository_ctx.path(script_path).exists:
        return
    content = repository_ctx.read(script_path)
    if _ENGINE_VERSION_WRITE_ORIGINAL not in content:
        # Layout changed upstream; fail loudly rather than silently shipping a
        # mutating launcher. Update the patch alongside new Flutter versions.
        fail("rules_flutter: unable to patch {} for Flutter {}: unexpected script content. ".format(
            script_path,
            repository_ctx.attr.flutter_version,
        ) + "Update _ENGINE_VERSION_WRITE_ORIGINAL in flutter/repositories.bzl.")
    repository_ctx.file(
        script_path,
        content.replace(_ENGINE_VERSION_WRITE_ORIGINAL, _ENGINE_VERSION_WRITE_PATCHED),
        executable = True,
        legacy_utf8 = False,
    )

def _host_matches_platform(repository_ctx, platform):
    os_name = repository_ctx.os.name.lower()
    if platform == "macos":
        return os_name.startswith("mac") or os_name.startswith("darwin")
    return os_name.startswith(platform)

def _ensure_precached_artifacts(repository_ctx):
    """Verify requested artifact groups exist; precache them if fetchable."""
    missing = [
        group
        for group in repository_ctx.attr.precache
        if not repository_ctx.path("flutter/bin/cache/" + _PRECACHE_SENTINELS[group]).exists
    ]
    if not missing:
        return

    if not _host_matches_platform(repository_ctx, repository_ctx.attr.platform):
        # buildifier: disable=print
        print("rules_flutter: cannot run 'flutter precache --{}' for the {} SDK on this host; ".format(
            " --".join(missing),
            repository_ctx.attr.platform,
        ) + "builds needing those artifacts will fail. (Stable archives normally ship them.)")
        return

    # buildifier: disable=print
    print("rules_flutter: archive for Flutter {} is missing {} artifacts; running 'flutter precache' at fetch time. ".format(
        repository_ctx.attr.flutter_version,
        ", ".join(missing),
    ) + "Note: precached artifacts are engine-revision-pinned but not integrity-checked.")

    result = repository_ctx.execute(
        [
            "flutter/bin/flutter",
            "--no-version-check",
            "precache",
            "--force",
        ] + ["--" + group for group in missing],
        environment = {
            "CI": "true",
            "FLUTTER_SUPPRESS_ANALYTICS": "true",
            "PUB_ENVIRONMENT": "flutter_tool:bazel_fetch",
        },
        timeout = 1800,
    )
    if result.return_code != 0:
        fail("rules_flutter: flutter precache failed (code {}):\nstdout: {}\nstderr: {}".format(
            result.return_code,
            result.stdout,
            result.stderr,
        ))

# Host OS each artifact group's precache can run on (None = any host).
_PRECACHE_GROUP_HOSTS = {
    "android": None,
    "ios": "macos",
    "linux": "linux",
    "macos": "macos",
    "web": None,
    "windows": "windows",
}

def _warm_first_run_stamps(repository_ctx):
    """Write the tool's first-run artifact stamps before the cache is sealed.

    Release archives do not ship every universal artifact stamp on all
    platforms (the Linux archive lacks e.g. libimobiledevice.stamp), so the
    first tool invocation after fetch would try to write into the sealed
    cache and fail. Every `flutter precache` run refreshes the universal
    artifacts regardless of group flags; run one at fetch time scoped to the
    host-supported requested groups so all stamps exist before sealing.
    """
    if not _host_matches_platform(repository_ctx, repository_ctx.attr.platform):
        return

    enabled = [
        group
        for group in repository_ctx.attr.precache
        if _PRECACHE_GROUP_HOSTS.get(group) == None or
           _host_matches_platform(repository_ctx, _PRECACHE_GROUP_HOSTS[group])
    ]
    args = ["flutter/bin/flutter", "--no-version-check", "precache"]
    for group in _PRECACHE_GROUP_HOSTS:
        if group in enabled:
            args.append("--" + group)
        else:
            args.append("--no-" + group)

    result = repository_ctx.execute(
        args,
        environment = {
            "CI": "true",
            "FLUTTER_SUPPRESS_ANALYTICS": "true",
            "PUB_ENVIRONMENT": "flutter_tool:bazel_fetch",
        },
        timeout = 1800,
    )
    if result.return_code != 0:
        fail("rules_flutter: fetch-time flutter precache warm-up failed (code {}):\nstdout: {}\nstderr: {}".format(
            result.return_code,
            result.stdout,
            result.stderr,
        ))

def _seal_sdk_cache(repository_ctx):
    """Make bin/cache read-only so any residual write attempt fails loudly.

    Build actions and run helpers set FLUTTER_ALREADY_LOCKED and
    --no-version-check, and the launcher is patched above, so nothing should
    write here after fetch time.
    """
    if repository_ctx.os.name.lower().startswith("windows"):
        return
    repository_ctx.execute(["chmod", "-R", "a-w", "flutter/bin/cache"])

    # Keep owner-write on the iOS/macOS engine frameworks: `flutter build ios`
    # copies them into the app's build directory with permissions preserved,
    # then codesigns the copy in place — a read-only source makes that copy
    # unsignable. The tool never writes these files in place, so the sealing
    # guarantee is unaffected.
    result = repository_ctx.execute([
        "sh",
        "-c",
        "find flutter/bin/cache/artifacts/engine -maxdepth 1 " +
        "\\( -name 'ios*' -o -name 'darwin*' \\) " +
        "-exec chmod -R u+w {} + 2>/dev/null || true",
    ])
    if result.return_code != 0:
        fail("rules_flutter: unsealing engine frameworks failed: " + result.stderr)

def _flutter_repo_impl(repository_ctx):
    # Flutter SDK download URLs from Google Cloud Storage
    platform = repository_ctx.attr.platform
    extension = "zip" if platform == "windows" else ("zip" if platform == "macos" else "tar.xz")
    url = "https://storage.googleapis.com/flutter_infra_release/releases/stable/{0}/flutter_{0}_{1}-stable.{2}".format(
        platform,
        repository_ctx.attr.flutter_version,
        extension,
    )

    # Download and verify Flutter SDK with integrity checking enabled
    repository_ctx.download_and_extract(
        url = url,
        integrity = TOOL_VERSIONS[repository_ctx.attr.flutter_version][repository_ctx.attr.platform],
    )

    _patch_engine_version_script(repository_ctx)
    _ensure_precached_artifacts(repository_ctx)
    _warm_first_run_stamps(repository_ctx)

    # Drop transient download staging shipped in (or created by) the archive.
    downloads = repository_ctx.path("flutter/bin/cache/downloads")
    if downloads.exists:
        repository_ctx.delete(downloads)

    package_labels = _generate_flutter_packages(repository_ctx)

    package_group = ""
    if package_labels:
        package_group = """
filegroup(
    name = "flutter_sdk_packages",
    srcs = [
{package_srcs}
    ],
    visibility = ["//visibility:public"],
)
""".format(
            package_srcs = "\n".join(['        "{}",'.format(label) for label in sorted(package_labels)]),
        )

    build_content = """# Generated by flutter/repositories.bzl
load("@rules_flutter//flutter:toolchain.bzl", "flutter_toolchain")

# Create file targets for Flutter binaries
filegroup(
    name = "flutter_binary_unix",
    srcs = ["flutter/bin/flutter"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "flutter_binary_windows", 
    srcs = ["flutter/bin/flutter.bat"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dart_binary_unix",
    srcs = ["flutter/bin/dart"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dart_binary_windows", 
    srcs = ["flutter/bin/dart.exe"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "flutter_sdk",
    srcs = glob(["flutter/**/*"]) + [{sdk_packages}],
    visibility = ["//visibility:public"],
)

flutter_toolchain(
    name = "flutter_toolchain",
    target_tool = select({{
        "@platforms//os:windows": ":flutter_binary_windows",
        "//conditions:default": ":flutter_binary_unix",
    }}),
    sdk_files = ":flutter_sdk",
)
{package_group}
""".format(
        sdk_packages = '":flutter_sdk_packages"' if package_labels else "",
        package_group = package_group,
    )

    repository_ctx.file("BUILD.bazel", build_content)

    # Last step: package BUILD files (written into bin/cache/pkg above) exist
    # by now, so the cache can be sealed.
    _seal_sdk_cache(repository_ctx)

def _generate_flutter_packages(repository_ctx):
    """Generate BUILD files for packages bundled within the Flutter SDK."""

    package_roots = [
        "flutter/packages",
        "flutter/bin/cache/pkg",
    ]

    package_labels = []

    for root in package_roots:
        root_path = repository_ctx.path(root)
        if not root_path.exists or not root_path.is_dir:
            continue

        for entry in root_path.readdir():
            if not entry.is_dir:
                continue

            package_dir = "{}/{}".format(root, entry.basename)
            pubspec_path = repository_ctx.path(package_dir + "/pubspec.yaml")
            if not pubspec_path.exists:
                continue

            package_name = entry.basename
            generate_package_build(
                repository_ctx,
                package_name = package_name,
                package_dir = package_dir,
                include_hosted_deps = False,
                include_pub_cache_data = True,
            )

            package_labels.append("//{}:{}_files".format(package_dir, package_name))

    return package_labels

flutter_repositories = repository_rule(
    _flutter_repo_impl,
    doc = _DOC,
    attrs = _ATTRS,
)

# Wrapper macro around everything above, this is the primary API
def flutter_register_toolchains(name, register = True, **kwargs):
    """Convenience macro for users which does typical setup.

    - create a repository for each built-in platform like "flutter_linux_amd64"
    - create a convenience repository exposing the host SDK as "<name>_sdk"
    - create a repository exposing toolchains for each platform like "flutter_platforms"
    - register a toolchain pointing at each platform
    Users can avoid this macro and do these steps themselves, if they want more control.
    Args:
        name: base name for all created repos, like "flutter1_14"
        register: whether to call through to native.register_toolchains.
            Set this to False when toolchain registration is handled elsewhere (for example by a module extension).
        **kwargs: passed to each flutter_repositories call
    """
    for platform in PLATFORMS.keys():
        flutter_repositories(
            name = name + "_" + platform,
            platform = platform,
            **kwargs
        )
        if register:
            native.register_toolchains("@%s_toolchains//:%s_toolchain" % (name, platform))

    toolchains_repo(
        name = name + "_toolchains",
        user_repository_name = name,
    )

    flutter_sdk_repo(
        name = name + "_sdk",
        user_repository_name = name,
    )
