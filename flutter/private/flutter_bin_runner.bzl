"""
Runs an executable in the Flutter SDK.
"""

load("//flutter:toolchain.bzl", "FlutterInfo")

def _flutter_bin_runner(ctx):
    info = ctx.attr.toolchain[FlutterInfo]
    tool = getattr(info, ctx.attr.tool).files.to_list()[0]
    exe = ctx.actions.declare_file(ctx.attr.tool)
    ctx.actions.symlink(
        output = exe,
        target_file = tool,
        is_executable = True,
    )
    cache = ctx.actions.declare_directory("cache")
    ctx.actions.run(
        outputs = [cache],
        inputs = [info.cache.files.to_list()[0]],
        executable = "cp",
        arguments = ["-r", info.cache.files.to_list()[0].path + "/.", cache.path],
    )
    internal = ctx.actions.declare_directory("internal")
    ctx.actions.run(
        outputs = [internal],
        inputs = [info.internal.files.to_list()[0]],
        executable = "cp",
        arguments = ["-r", info.internal.files.to_list()[0].path + "/.", internal.path],
    )
    return [
        DefaultInfo(
            runfiles = ctx.runfiles(
                files = [cache, internal],
            ),
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
