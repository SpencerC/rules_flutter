"Public API re-exports"

load("//flutter:providers.bzl", "FlutterContextInfo")
load("//flutter/private:context.bzl", "make_flutter_runner", _flutter_context = "flutter_context")

flutter_context = _flutter_context

def _flutter_test_impl(ctx):
    runner, files = make_flutter_runner(
        ctx = ctx,
        args = ["test", "--reporter", "expanded"],
        inputs = ctx.files.srcs + ctx.files.deps,
        executable = True,
    )
    return DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(files = files.to_list()),
        executable = runner,
    )

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "context": attr.label(
            doc = "The context to run the test command.",
            providers = [FlutterContextInfo],
            mandatory = True,
        ),
    },
    test = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _flutter_packages_run_impl(ctx):
    runner, files = make_flutter_runner(
        ctx = ctx,
        args = ["packages", "run"] + ctx.attr.cmd,
        executable = True,
        run_in_workspace = True,
    )
    return DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(files = files.to_list()),
        executable = runner,
    )

flutter_packages_run = rule(
    implementation = _flutter_packages_run_impl,
    attrs = {
        "cmd": attr.string_list(mandatory = True),
        "context": attr.label(
            doc = "The context to run the command.",
            providers = [FlutterContextInfo],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _flutter_build_impl(ctx):
    runner, files = make_flutter_runner(
        ctx = ctx,
        args = ["build"] + ctx.attr.cmd,
        executable = True,
        run_in_workspace = True,
    )
    return DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(files = files.to_list()),
        executable = runner,
    )

flutter_build = rule(
    implementation = _flutter_build_impl,
    attrs = {
        "cmd": attr.string_list(mandatory = True),
        "context": attr.label(
            doc = "The context to run the build command.",
            providers = [FlutterContextInfo],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)
