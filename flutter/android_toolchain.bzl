"""Hermetic Android execution toolchain used by flutter_app."""

AndroidToolchainInfo = provider(
    doc = "Pinned Android SDK, optional NDK, and Gradle distribution.",
    fields = {
        "build_tools_version": "Android build-tools version.",
        "files": "All files required by an Android build action.",
        "gradle_home": "Exec-root-relative extracted Gradle distribution root.",
        "gradle_version": "Pinned Gradle version.",
        "ndk_path": "Exec-root-relative NDK root, or None.",
        "ndk_version": "Declared NDK version, or empty string.",
        "sdk_path": "Exec-root-relative Android SDK root.",
        "sdk_version": "Android SDK/API version.",
    },
)

def _root(files, name):
    values = files.to_list()
    if not values:
        fail("Android toolchain {} resolved to no files".format(name))
    if len(values) == 1 and values[0].is_directory:
        return values[0].path
    first = values[0]
    parts = first.path.split("/")
    if parts[0] == "external" and len(parts) > 1:
        return "external/{}".format(parts[1])
    return first.dirname

def _android_toolchain_impl(ctx):
    sdk = ctx.attr.sdk[DefaultInfo].files
    gradle = ctx.attr.gradle[DefaultInfo].files
    transitive = [sdk, gradle]
    ndk_path = None
    if ctx.attr.ndk:
        ndk = ctx.attr.ndk[DefaultInfo].files
        transitive.append(ndk)
        ndk_path = _root(ndk, "NDK")

    info = AndroidToolchainInfo(
        sdk_version = ctx.attr.sdk_version,
        build_tools_version = ctx.attr.build_tools_version,
        ndk_version = ctx.attr.ndk_version,
        sdk_path = _root(sdk, "SDK"),
        ndk_path = ndk_path,
        gradle_home = _root(gradle, "Gradle distribution"),
        gradle_version = ctx.attr.gradle_version,
        files = depset(transitive = transitive),
    )
    return [platform_common.ToolchainInfo(android = info)]

android_toolchain = rule(
    implementation = _android_toolchain_impl,
    attrs = {
        "sdk": attr.label(mandatory = True, allow_files = True),
        "gradle": attr.label(mandatory = True, allow_files = True),
        "ndk": attr.label(allow_files = True),
        "sdk_version": attr.string(mandatory = True),
        "build_tools_version": attr.string(mandatory = True),
        "ndk_version": attr.string(),
        "gradle_version": attr.string(mandatory = True),
    },
)
