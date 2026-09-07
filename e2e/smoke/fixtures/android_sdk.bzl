"""Load a populated Android SDK package without depending on a host SDK."""

def _android_sdk_fixture_impl(ctx):
    # Use the same BUILD template and helper as SDK discovery. An empty SDK
    # repository skips these loads and hides incompatible language providers.
    ctx.template(
        "BUILD.bazel",
        Label("@rules_android//rules/android_sdk_repository:template.bzl"),
        substitutions = {
            # Preserve the helper's own repository mapping for its loads.
            ":helper.bzl": str(Label("@rules_android//rules/android_sdk_repository:helper.bzl")),
            "__repository_name__": ctx.name,
            "__build_tools_version__": "35.0.0",
            "__build_tools_directory__": "35.0.0",
            "__api_levels__": '"35"',
            "__default_api_level__": "35",
            "__system_image_dirs__": "",
        },
    )

    # Build an exported SDK file to verify package loading without executing
    # Android tools or traversing sdk_path's directory artifact.
    ctx.file("platform-tools/adb", "analysis-only Android SDK fixture\n", executable = False)

android_sdk_fixture = repository_rule(
    implementation = _android_sdk_fixture_impl,
)
