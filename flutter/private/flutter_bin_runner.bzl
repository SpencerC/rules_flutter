"""
Runs an executable in the Flutter SDK.
"""

load("//flutter:toolchain.bzl", "FlutterInfo")

def _flutter_bin_runner(ctx):
    tool = getattr(ctx.attr.toolchain[FlutterInfo], ctx.attr.tool).files.to_list()[0]
    exe = ctx.actions.declare_file(ctx.attr.tool)
    ctx.actions.symlink(
        output = exe,
        target_file = tool,
        is_executable = True,
    )
    return [
        DefaultInfo(
            runfiles = ctx.runfiles(files = [tool]),
            executable = exe,
        ),
    ]

flutter_bin_runner = rule(
    implementation = _flutter_bin_runner,
    attrs = {
        "tool": attr.string(
            doc = "The tool to run.",
        ),
        "toolchain": attr.label(
            doc = "The toolchain to use.",
        ),
    },
    executable = True,
)
