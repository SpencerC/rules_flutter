"""Android SDK toolchain for Flutter Android build targets.

The SDK is provisioned hermetically by the `flutter.android_sdk` module
extension tag (see flutter/private/android_sdk_repo.bzl), which downloads
pinned command-line tools plus a Temurin JDK and installs the requested
platform/build-tools/NDK packages at repository fetch time.
"""

AndroidSdkInfo = provider(
    doc = "Information about a Bazel-provisioned Android SDK.",
    fields = {
        "sdk_root_marker": "Marker file at the SDK root; ANDROID_HOME is its directory.",
        "java_home_marker": "Marker file inside the bundled JDK home; JAVA_HOME is its directory.",
        "files": "Depset of all SDK and JDK files.",
        "api_level": "Installed platforms;android-<api_level>.",
        "build_tools_version": "Installed build-tools version.",
        "ndk_version": "Installed NDK version, or empty when not requested.",
    },
)

def _android_sdk_toolchain_impl(ctx):
    info = AndroidSdkInfo(
        sdk_root_marker = ctx.file.sdk_root_marker,
        java_home_marker = ctx.file.java_home_marker,
        files = depset(transitive = [target[DefaultInfo].files for target in ctx.attr.files]),
        api_level = ctx.attr.api_level,
        build_tools_version = ctx.attr.build_tools_version,
        ndk_version = ctx.attr.ndk_version,
    )
    return [
        platform_common.ToolchainInfo(androidsdkinfo = info),
    ]

android_sdk_toolchain = rule(
    implementation = _android_sdk_toolchain_impl,
    attrs = {
        "sdk_root_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Marker file located at the SDK root.",
        ),
        "java_home_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Marker file located inside the bundled JDK home.",
        ),
        "files": attr.label_list(
            allow_files = True,
            doc = "All SDK and JDK files needed at build time.",
        ),
        "api_level": attr.string(),
        "build_tools_version": attr.string(),
        "ndk_version": attr.string(),
    },
    doc = "Defines an Android SDK toolchain provisioned by rules_flutter.",
)
