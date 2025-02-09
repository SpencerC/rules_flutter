"""This module implements the language-specific toolchain rule.
"""

load("//flutter:providers.bzl", "FlutterToolchainInfo")

def _flutter_toolchain_impl(ctx):
    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "FLUTTER_BIN": "TODO",
    })

    flutter = FlutterToolchainInfo(
        flutter = ctx.executable.flutter_tool,
        dart = ctx.executable.dart_tool,
        deps = depset(
            [
                ctx.executable.flutter_tool,
                ctx.executable.dart_tool,
                ctx.files.runner_template[0],
            ] + ctx.files.bin + ctx.files.packages,
        ),
        internal = struct(
            runner_template = ctx.files.runner_template[0],
        ),
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        flutter = flutter,
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
        "bin": attr.label(
            doc = "The files in the bin directory.",
            mandatory = True,
        ),
        "packages": attr.label(
            doc = "The files in the packages directory.",
            mandatory = True,
        ),
        "runner_template": attr.label(
            doc = "The template file for the runner.",
            allow_single_file = True,
        ),
    },
    doc = """Defines a flutter compiler/runtime toolchain.

For usage see https://docs.bazel.build/versions/main/toolchains.html#defining-toolchains.
""",
)
