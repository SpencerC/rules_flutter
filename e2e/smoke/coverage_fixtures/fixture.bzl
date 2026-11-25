"""Use the selected SDK's dependency versions in the compatibility fixtures."""

load("@rules_flutter//flutter:defs.bzl", "FlutterLibraryInfo")

def _sdk_test_deps_impl(ctx):
    report = ctx.attr._sdk[FlutterLibraryInfo].pub_deps
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.run(
        executable = ctx.executable._tool,
        inputs = [report],
        outputs = [output],
        arguments = [report.path, output.path, ctx.attr.package_name],
    )
    return [DefaultInfo(files = depset([output]))]

sdk_test_deps = rule(
    implementation = _sdk_test_deps_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "_sdk": attr.label(default = "@flutter_sdk//flutter/packages/flutter_test"),
        "_tool": attr.label(default = "//coverage_fixtures:sdk_test_deps", executable = True, cfg = "exec"),
    },
)
