"""This module implements the language-specific toolchain rule.
"""

FlutterInfo = provider(
    doc = "Information about how to invoke the tool executable.",
    fields = {
        "flutter": "The Flutter executable.",
        "dart": "The Dart executable.",
        "cache": "The cache folder.",
        "internal": "The internal folder.",
    },
)

def _flutter_toolchain_impl(ctx):
    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "FLUTTER_BIN": "TODO",
    })
    default = DefaultInfo(
        runfiles = ctx.runfiles(
            files = [
                ctx.files.flutter_tool[0],
                ctx.files.dart_tool[0],
                ctx.files.cache_folder[0],
                ctx.files.internal_folder[0],
            ],
        ),
    )
    flutterinfo = FlutterInfo(
        flutter = ctx.attr.flutter_tool,
        dart = ctx.attr.dart_tool,
        cache = ctx.attr.cache_folder,
        internal = ctx.attr.internal_folder,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        flutterinfo = flutterinfo,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
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
            executable = True,
            cfg = "exec",
        ),
        "dart_tool": attr.label(
            doc = "The Dart tool executable.",
            allow_single_file = True,
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
        "cache_folder": attr.label(
            doc = "The cache folder.",
            allow_single_file = True,
            mandatory = True,
        ),
        "internal_folder": attr.label(
            doc = "The internal folder.",
            allow_single_file = True,
            mandatory = True,
        ),
    },
    doc = """Defines a flutter compiler/runtime toolchain.

For usage see https://docs.bazel.build/versions/main/toolchains.html#defining-toolchains.
""",
)
