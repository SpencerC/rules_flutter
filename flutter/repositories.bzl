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
    # Not constrained to TOOL_VERSIONS.keys(): unlisted versions are allowed
    # when the caller supplies `integrity` for the platform (escape hatch). The
    # version/integrity consistency check lives in _flutter_repo_impl so it can
    # fail lazily, per-platform, with an actionable message.
    "flutter_version": attr.string(mandatory = True),
    "platform": attr.string(mandatory = True, values = PLATFORMS.keys()),
    "integrity": attr.string(
        default = "",
        doc = """SRI integrity of the stable release archive for this platform.
Required only when `flutter_version` is not in the built-in version table
(the escape hatch surfaced as `flutter.toolchain(integrity = {...})`). When
empty and the version is known, the built-in integrity is used.""",
    ),
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
# already present in the extracted archive. "{arch}" is substituted with the
# repository platform's Flutter arch suffix (x64 or arm64).
_PRECACHE_SENTINELS = {
    "android": "artifacts/engine/android-arm64-release",
    "ios": "artifacts/engine/ios-release",
    "linux": "artifacts/engine/linux-{arch}-release",
    "macos": "artifacts/engine/darwin-x64-release",
    "web": "flutter_web_sdk",
    "windows": "artifacts/engine/windows-x64-release",
}

# Platforms that reuse another platform's release archive. Flutter publishes no
# linux-arm64 SDK tarball, but the framework sources, flutter_tools snapshot and
# templates in the x64 archive are architecture-independent — only bin/cache
# holds native code, and that is replaced by _strip_foreign_arch_artifacts plus
# the fetch-time precache below.
_ARCHIVE_ALIASES = {
    "linux_arm64": "linux",
}

# Flutter's own arch suffix for each platform (see bin/internal/update_dart_sdk.sh).
_PLATFORM_ARCH = {
    "linux_arm64": "arm64",
}

def _archive_platform(platform):
    """Release-archive platform whose tarball this platform downloads."""
    return _ARCHIVE_ALIASES.get(platform, platform)

def _platform_arch(platform):
    """Flutter arch suffix used in bin/cache artifact paths."""
    return _PLATFORM_ARCH.get(platform, "x64")

def _sentinel_path(group, platform):
    return _PRECACHE_SENTINELS[group].replace("{arch}", _platform_arch(platform))

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

def _host_is_arm64(repository_ctx):
    return repository_ctx.os.arch.lower() in ["aarch64", "arm64"]

def _host_is_os(repository_ctx, os_family):
    """True when the host OS is os_family, ignoring architecture.

    Distinct from _host_matches_platform: artifact *groups* (see
    _PRECACHE_GROUP_HOSTS) are named after operating systems, so routing them
    through the arch-aware platform check would disable e.g. the `linux` group
    on an arm64 Linux host.
    """
    os_name = repository_ctx.os.name.lower()
    if os_family == "macos":
        return os_name.startswith("mac") or os_name.startswith("darwin")
    return os_name.startswith(os_family)

def _host_matches_platform(repository_ctx, platform):
    if platform == "macos":
        return _host_is_os(repository_ctx, "macos")
    if not _host_is_os(repository_ctx, _archive_platform(platform)):
        return False

    # Linux distinguishes architectures: an arm64 SDK repo can only be
    # completed on an arm64 host (the fetch-time precache below runs the
    # launcher, which downloads native artifacts for the machine it is on),
    # and the x64 repo must not claim an arm64 host.
    if _archive_platform(platform) == "linux":
        return _host_is_arm64(repository_ctx) == (_platform_arch(platform) == "arm64")
    return True

def _ensure_precached_artifacts(repository_ctx):
    """Verify requested artifact groups exist; precache them if fetchable."""
    missing = [
        group
        for group in repository_ctx.attr.precache
        if not repository_ctx.path(
            "flutter/bin/cache/" + _sentinel_path(group, repository_ctx.attr.platform),
        ).exists
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

    # The ios-usb artifacts are declared universal, but their downloads are
    # skipped on non-macOS hosts — so the tool's up-to-date probe (artifact
    # directory + expected executables) can never pass there, and EVERY
    # invocation rewrites their stamps. Materialize the directories and probe
    # files before the warm-up: precache then records matching stamps, the
    # up-to-date check passes forever after, and the sealed cache stays
    # untouched. (On macOS the real artifacts exist; nothing to do.)
    if not _host_is_os(repository_ctx, "macos"):
        # Union of the artifact names across Flutter generations: older
        # releases (e.g. 3.24) name the usbmuxd artifact without the lib
        # prefix and probe iproxy inside it; newer releases use libusbmuxd
        # and add libimobiledeviceglue. Extra directories are harmless — the
        # tool only probes the artifacts its own version declares.
        ios_usb_probe_files = {
            "ios-deploy": [],
            "libimobiledevice": ["idevicescreenshot", "idevicesyslog"],
            "libimobiledeviceglue": [],
            "libplist": [],
            "libusbmuxd": ["iproxy"],
            "openssl": [],
            "usbmuxd": ["iproxy"],
        }
        for artifact, executables in ios_usb_probe_files.items():
            artifact_dir = "flutter/bin/cache/artifacts/" + artifact
            repository_ctx.file(artifact_dir + "/.rules_flutter_placeholder", "")
            for executable in executables:
                repository_ctx.file(artifact_dir + "/" + executable, "", executable = True)

    enabled = [
        group
        for group in repository_ctx.attr.precache
        if _PRECACHE_GROUP_HOSTS.get(group) == None or
           _host_is_os(repository_ctx, _PRECACHE_GROUP_HOSTS[group])
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

def _relative_uri(uri, root_uri, base_dir):
    """Rewrite `uri` as a reference relative to `base_dir`, or None.

    `base_dir` is the repository-relative directory holding the
    package_config.json that carries the URI. Returns None when the URI is
    already relative or points outside the repository, both of which the
    caller leaves alone.
    """
    if not uri.startswith(root_uri + "/"):
        return None

    target_parts = uri[len(root_uri) + 1:].rstrip("/").split("/")
    base_parts = base_dir.split("/")

    shared = 0
    for i in range(min(len(target_parts), len(base_parts))):
        if target_parts[i] != base_parts[i]:
            break
        shared = i + 1

    # A directory URI needs the trailing slash: package_config resolves each
    # package's `packageUri` (typically "lib/") against it, and without it the
    # last segment would be dropped as a sibling.
    return "/".join([".."] * (len(base_parts) - shared) + target_parts[shared:]) + "/"

def _resolves_outside_repo(repository_ctx, uri):
    """Does `uri` name an absolute path that exists outside this repository?

    Such a path makes the repository machine-specific -- see the caller. A
    `file:` URI that resolves to nothing does not: it is already broken here
    and would be no more broken elsewhere.
    """
    if not uri.startswith("file://"):
        return False
    return repository_ctx.path(uri[len("file://"):]).exists

def _relocate_package_configs(repository_ctx):
    """Make the SDK's package_config.json files independent of the fetch path.

    `pub get` records every package's `rootUri` as an absolute file:// URI, so
    the SDK it writes only resolves at the path it was fetched into. Bazel's
    repo contents cache breaks precisely that assumption: the repository is
    moved out of the output base it was built in and later served to a
    different one, on a different machine.

    The tool notices. PubDependencies.isUpToDate walks the recorded roots and
    checks each pubspec.yaml exists; with dead absolute paths it reports the
    artifact stale, and Cache.updateAll then instantiates the artifact updater,
    whose constructor creates bin/cache/downloads -- inside the tree
    _seal_sdk_cache just made read-only. Every `flutter analyze` and `flutter
    test` action dies with a FileSystemException before running.

    Rewriting the roots as relative references fixes it at the source: the
    paths resolve against the config file's own location, so they are correct
    wherever the repository ends up. This is what makes the repository
    genuinely relocatable, which is the property `reproducible` promises --
    hence the boolean return, which gates it.

    Only `rootUri` is touched. The `flutterRoot` and `pubCache` metadata keys
    are pub's own bookkeeping, read by pub to decide whether a re-resolve is
    needed and dereferenced as absolute paths when it is; a stale value there
    biases toward re-resolving, which is the safe direction, whereas a
    relative one would be parsed as a file path and mislead it.
    """
    if repository_ctx.os.name.lower().startswith("windows"):
        return False

    result = repository_ctx.execute([
        "find",
        "flutter",
        "-type",
        "f",
        "-path",
        "*/.dart_tool/package_config.json",
    ])
    if result.return_code != 0:
        fail("rules_flutter: locating the SDK's package_config.json files failed: " + result.stderr)

    root_uri = "file://" + str(repository_ctx.path("."))
    relocatable = True
    for config_path in result.stdout.split("\n"):
        config_path = config_path.strip()
        if not config_path:
            continue

        config = json.decode(repository_ctx.read(config_path))
        base_dir = config_path.rsplit("/", 1)[0]

        rewrote = False
        for package in config.get("packages", []):
            relative = _relative_uri(package.get("rootUri", ""), root_uri, base_dir)
            if relative != None:
                package["rootUri"] = relative
                rewrote = True
            elif _resolves_outside_repo(repository_ctx, package.get("rootUri", "")):
                # An absolute root outside the repository that exists on this
                # machine -- a PUB_CACHE somewhere else, say. Nothing to
                # rewrite it to, so the tree is tied to this machine and must
                # not be cached as reproducible.
                #
                # Only when it exists. The release archive ships its own
                # flutter/.dart_tool/package_config.json full of paths from
                # Flutter's build bot (/b/s/w/ir/...), dead on every machine
                # including the one that fetched. Those are stale archive junk,
                # equally broken wherever the repository sits, so they say
                # nothing about whether it can be moved.
                relocatable = False

        if rewrote:
            repository_ctx.file(config_path, json.encode_indent(config, indent = "  ") + "\n")

    return relocatable

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

def _resolve_integrity(repository_ctx):
    """Pick the SRI to verify the SDK archive against.

    A caller-supplied `integrity` (the escape hatch for unlisted versions) wins;
    otherwise the built-in version table is consulted. Fails with an actionable
    message when the version is unknown and no integrity was provided for this
    platform — this runs lazily per-platform, so cross-OS repos that are never
    fetched never trip on it.
    """
    # Platforms that reuse another platform's archive verify against that
    # archive's integrity — it is literally the same download.
    platform = _archive_platform(repository_ctx.attr.platform)
    version = repository_ctx.attr.flutter_version
    override = repository_ctx.attr.integrity
    if override:
        return override
    known = TOOL_VERSIONS.get(version)
    if known and platform in known:
        return known[platform]
    fail(("rules_flutter: Flutter {version} is not in the built-in version table and no " +
          "integrity was provided for platform {platform}. Register it with " +
          "flutter.toolchain(flutter_version = \"{version}\", integrity = {{\"{platform}\": \"sha256-...\"}}). " +
          "Compute the SRI from the stable archive URL below, e.g. " +
          "`curl -sL <url> | openssl dgst -sha256 -binary | openssl base64 -A` prefixed with 'sha256-'.").format(
        version = version,
        platform = platform,
    ))

def _strip_foreign_arch_artifacts(repository_ctx):
    """Remove native artifacts belonging to the archive's architecture.

    Only reached for platforms in _ARCHIVE_ALIASES, which download another
    architecture's release archive. Deleting the native pieces (and the stamps
    that mark them current) makes the fetch-time precache in
    _warm_first_run_stamps refetch them for the host: the launcher's
    update_dart_sdk.sh picks the Dart SDK by `uname -m`, and flutter_tools
    resolves engine artifacts through its own host-platform detection. Both
    then land on the arm64 downloads Flutter publishes per engine revision,
    even though it ships no arm64 SDK tarball.

    Note this has to invalidate the tool snapshot as well as the artifacts.
    The refetch is a side effect of the launcher's bootstrap, and the
    bootstrap is gated on the snapshot being stale -- so deleting artifacts
    without deleting the snapshot produces an SDK that skips the bootstrap and
    then cannot run at all.
    """
    archive_arch = _platform_arch(_archive_platform(repository_ctx.attr.platform))

    stale = [
        # Native Dart SDK (dart, dartaotruntime, and the AOT snapshots).
        "flutter/bin/cache/dart-sdk",
        "flutter/bin/cache/engine-dart-sdk.stamp",
        # The tool snapshot and its stamp, which are what gate the launcher's
        # bootstrap. shared.sh only calls update_dart_sdk.sh from inside the
        # "is flutter_tools.snapshot stale?" branch, so leaving a valid
        # snapshot and matching stamp behind means the launcher decides it has
        # nothing to do, skips the bootstrap, and execs the Dart SDK that was
        # just deleted two lines above -- `flutter precache` then dies with
        # "bin/cache/dart-sdk/bin/dart: No such file or directory" (code 127)
        # before it can refetch anything. A git checkout of the SDK has no
        # snapshot, which is why this only bites the re-architected archives.
        # The snapshot is a portable Dart kernel file, so discarding it costs
        # a rebuild at fetch time and nothing else.
        "flutter/bin/cache/flutter_tools.snapshot",
        "flutter/bin/cache/flutter_tools.stamp",
        # Host engine artifacts: flutter_tester, gen_snapshot, impellerc.
        "flutter/bin/cache/artifacts/engine/linux-{}".format(archive_arch),
        "flutter/bin/cache/artifacts/engine/linux-{}-profile".format(archive_arch),
        "flutter/bin/cache/artifacts/engine/linux-{}-release".format(archive_arch),
        # font-subset ships per-arch alongside the engine artifacts.
        "flutter/bin/cache/artifacts/engine/font-subset.stamp",
        "flutter/bin/cache/font-subset.stamp",
    ]
    for path in stale:
        target = repository_ctx.path(path)
        if target.exists:
            repository_ctx.delete(target)

def _verify_rearchitected(repository_ctx):
    """Fail at fetch time if the host-arch native artifacts are still missing.

    _strip_foreign_arch_artifacts relies on the fetch-time precache to refetch
    the Dart SDK and host engine artifacts for the host architecture. If a
    future Flutter release stops doing that as a side effect of `precache`, the
    SDK would still assemble and only break much later inside a build action,
    with an exec-format error or a missing flutter_tester. Check here instead.
    """
    arch = _platform_arch(repository_ctx.attr.platform)
    required = [
        ("Dart SDK", "flutter/bin/cache/dart-sdk/bin/dart"),
        ("engine artifacts", "flutter/bin/cache/artifacts/engine/linux-{}/flutter_tester".format(arch)),
    ]
    missing = [name for name, path in required if not repository_ctx.path(path).exists]
    if missing:
        fail(
            ("rules_flutter: the {} SDK is missing {} after the fetch-time precache. " +
             "The x64 release archive was re-architected but Flutter did not refetch the " +
             "host-arch replacements. Check that Flutter {} still publishes " +
             "dart-sdk-linux-{}.zip and linux-{}/artifacts.zip for its engine revision.").format(
                repository_ctx.attr.platform,
                " and ".join(missing),
                repository_ctx.attr.flutter_version,
                arch,
                arch,
            ),
        )

def _flutter_repo_impl(repository_ctx):
    # Flutter SDK download URLs from Google Cloud Storage. Platforms without
    # their own release archive (see _ARCHIVE_ALIASES) download a sibling
    # architecture's and are re-architected below.
    platform = repository_ctx.attr.platform
    archive_platform = _archive_platform(platform)
    extension = "zip" if archive_platform == "windows" else ("zip" if archive_platform == "macos" else "tar.xz")
    url = "https://storage.googleapis.com/flutter_infra_release/releases/stable/{0}/flutter_{0}_{1}-stable.{2}".format(
        archive_platform,
        repository_ctx.attr.flutter_version,
        extension,
    )

    # Download and verify Flutter SDK with integrity checking enabled
    repository_ctx.download_and_extract(
        url = url,
        integrity = _resolve_integrity(repository_ctx),
    )

    _patch_engine_version_script(repository_ctx)
    if platform in _ARCHIVE_ALIASES:
        if not _host_matches_platform(repository_ctx, platform):
            fail(
                ("rules_flutter: the {} SDK reuses the {} release archive and must refetch native " +
                 "artifacts for the host, so it can only be fetched on a matching host. " +
                 "Build this target on a {} machine.").format(platform, archive_platform, platform),
            )
        _strip_foreign_arch_artifacts(repository_ctx)
    _ensure_precached_artifacts(repository_ctx)
    _warm_first_run_stamps(repository_ctx)
    if platform in _ARCHIVE_ALIASES:
        _verify_rearchitected(repository_ctx)

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

    # After the last pub invocation, so no `pub get` can reintroduce absolute
    # roots, and before the seal, which makes these files unwritable.
    relocatable = _relocate_package_configs(repository_ctx)

    # Last step: package BUILD files (written into bin/cache/pkg above) exist
    # by now, so the cache can be sealed.
    _seal_sdk_cache(repository_ctx)

    # Let Bazel keep the *materialized* repository in the repo contents cache
    # (--repo_contents_cache), so a fresh output base reuses the unpacked SDK
    # instead of rebuilding it. This is the difference between a 145s and a 10s
    # cold build here: unpacking the xz archive and running the fetch-time
    # precache is ~70s of serial work that is otherwise repeated for every new
    # output base -- every CI runner, and every reboot on a machine whose
    # output base sits on tmpfs. The repository cache does not help, because it
    # caches the downloaded archive rather than the tree derived from it.
    #
    # Cacheable only when the repository was built the "complete" way: the
    # archive is pinned by version and checked against its integrity hash, and
    # the patching, stripping and BUILD generation are deterministic. The host
    # check is the subtle part. _ensure_precached_artifacts and
    # _warm_first_run_stamps are skipped when the host does not match the
    # repository platform, so the same attributes can yield either a precached
    # or a not-precached tree depending on the machine -- and the host is not
    # part of the cache key. Marking only the matching-host case reproducible
    # means a cache entry always denotes the fully-populated variant, and any
    # host that would hit it produces exactly that.
    #
    # And cacheable only when the tree can survive being served from somewhere
    # other than where it was built, which is what the contents cache does to
    # it -- see _relocate_package_configs.
    return repository_ctx.repo_metadata(
        reproducible = relocatable and _host_matches_platform(repository_ctx, platform),
    )

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
def flutter_register_toolchains(name, register = True, integrity = None, **kwargs):
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
        integrity: optional dict mapping platform (macos, linux, windows) to the
            SRI integrity of that platform's stable Flutter archive. Required for
            versions outside the built-in table; only the platforms you build on
            need an entry. See flutter.toolchain(integrity = {...}).
        **kwargs: passed to each flutter_repositories call (e.g. flutter_version, precache)
    """
    integrity = integrity or {}
    for platform in PLATFORMS.keys():
        flutter_repositories(
            name = name + "_" + platform,
            platform = platform,
            integrity = integrity.get(platform, ""),
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
