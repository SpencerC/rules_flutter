"""This module implements the language-specific toolchain rule.
"""

FlutterInfo = provider(
    doc = "Information about how to invoke the tool executable.",
    fields = {
        "target_tool_path": "Path to the tool executable for the target platform.",
        "flutter": "The Flutter executable.",
        "dart": "The Dart executable.",
        "flutter_dev": "The Flutter dev executable.",
    },
)

# Avoid using non-normalized paths (workspace/../other_workspace/path)
def _to_manifest_path(ctx, file):
    if file.short_path.startswith("../"):
        return "external/" + file.short_path[3:]
    else:
        return ctx.workspace_name + "/" + file.short_path

def _flutter_toolchain_impl(ctx):
    tool_files = ctx.attr.flutter_tool.files.to_list()
    target_tool_path = _to_manifest_path(ctx, tool_files[0])

    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "FLUTTER_BIN": target_tool_path,
    })
    flutterinfo = FlutterInfo(
        target_tool_path = target_tool_path,
        flutter = ctx.attr.flutter_tool,
        dart = ctx.attr.dart_tool,
        flutter_dev = ctx.attr.flutter_dev_tool,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        flutterinfo = flutterinfo,
        template_variables = template_variables,
    )
    return [
        toolchain_info,
        template_variables,
    ]

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
    attrs = {
        "flutter_tool": attr.label(
            doc = "The Flutter tool executable.",
            allow_single_file = True,
            mandatory = True,
            cfg = "exec",
        ),
        "dart_tool": attr.label(
            doc = "The Dart tool executable.",
            allow_single_file = True,
            mandatory = True,
            cfg = "exec",
        ),
        "flutter_dev_tool": attr.label(
            doc = "The Flutter dev tool executable.",
            allow_single_file = True,
            mandatory = True,
            cfg = "exec",
        ),
    },
    doc = """Defines a flutter compiler/runtime toolchain.

For usage see https://docs.bazel.build/versions/main/toolchains.html#defining-toolchains.
""",
)
