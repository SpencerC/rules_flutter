"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//flutter/private:toolchains_repo.bzl", "PLATFORMS", "toolchains_repo")
load("//flutter/private:versions.bzl", "TOOL_VERSIONS")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

# WARNING: any changes in this function may be BREAKING CHANGES for users
# because we'll fetch a dependency which may be different from one that
# they were previously fetching later in their WORKSPACE setup, and now
# ours took precedence. Such breakages are challenging for users, so any
# changes in this function should be marked as BREAKING in the commit message
# and released only in semver majors.
# This is all fixed by bzlmod, so we just tolerate it for now.
def rules_flutter_dependencies():
    # The minimal version of bazel_skylib we require
    http_archive(
        name = "bazel_skylib",
        sha256 = "bc283cdfcd526a52c3201279cda4bc298652efa898b10b4db0837dc51652756f",
        urls = [
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.7.1/bazel-skylib-1.7.1.tar.gz",
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.7.1/bazel-skylib-1.7.1.tar.gz",
        ],
    )

########
# Remaining content of the file is only used to support toolchains.
########
_DOC = "Fetch external tools needed for flutter toolchain"
_ATTRS = {
    "flutter_channel": attr.string(values = TOOL_VERSIONS.keys(), default = "stable"),
    "flutter_version": attr.string(mandatory = True),
    "platform": attr.string(mandatory = True, values = PLATFORMS.keys()),
}

def _flutter_repo_impl(repository_ctx):
    if repository_ctx.attr.flutter_version not in TOOL_VERSIONS[repository_ctx.attr.flutter_channel]:
        fail("Version %s not found in channel %s" % (repository_ctx.attr.flutter_version, repository_ctx.attr.flutter_channel))

    # Remove the _arm64 suffix from the platform name if present.
    folder = repository_ctx.attr.platform.split("_")[0]
    ext = "tar.xz" if repository_ctx.attr.platform == "linux" else "zip"
    url = "https://storage.googleapis.com/flutter_infra_release/releases/{0}/{1}/flutter_{2}_{3}-stable.{4}".format(
        repository_ctx.attr.flutter_channel,
        folder,
        repository_ctx.attr.platform,
        repository_ctx.attr.flutter_version,
        ext,
    )
    repository_ctx.download_and_extract(
        url = url,
        sha256 = TOOL_VERSIONS[repository_ctx.attr.flutter_channel][repository_ctx.attr.flutter_version][repository_ctx.attr.platform],
    )
    build_content = """# Generated by flutter/repositories.bzl
load("@rules_flutter//flutter:toolchain.bzl", "flutter_toolchain")

flutter_toolchain(
    name = "flutter_toolchain",
    target_tool = select({
        "@bazel_tools//src/conditions:host_windows": "flutter/bin/flutter.bat",
        "//conditions:default": "flutter/bin/flutter",
    }),
)
"""

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

flutter_repositories = repository_rule(
    _flutter_repo_impl,
    doc = _DOC,
    attrs = _ATTRS,
)

# Wrapper macro around everything above, this is the primary API
def flutter_register_toolchains(name, register = True, **kwargs):
    """Convenience macro for users which does typical setup.

    - create a repository for each built-in platform like "flutter_linux_amd64"
    - TODO: create a convenience repository for the host platform like "flutter_host"
    - create a repository exposing toolchains for each platform like "flutter_platforms"
    - register a toolchain pointing at each platform
    Users can avoid this macro and do these steps themselves, if they want more control.
    Args:
        name: base name for all created repos, like "flutter1_14"
        register: whether to call through to native.register_toolchains.
            Should be True for WORKSPACE users, but false when used under bzlmod extension
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
