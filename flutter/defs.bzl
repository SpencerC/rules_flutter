"Public API re-exports"

load("//flutter:providers.bzl", "FlutterPackageInfo")
load("//flutter/private:package.bzl", "make_flutter_runner", _flutter_package = "flutter_package")

flutter_package = _flutter_package

def _flutter_test_impl(ctx):
    runner, files = make_flutter_runner(
        ctx = ctx,
        args = ["test", "--reporter", "expanded"],
        inputs = ctx.files.srcs + ctx.files.deps,
        executable = True,
    )
    return DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(files = files.to_list() + ctx.files.data),
        executable = runner,
    )

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "package": attr.label(
            doc = "The package with which to run the test command.",
            providers = [FlutterPackageInfo],
            mandatory = True,
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional files to include in the test run.",
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
        "package": attr.label(
            doc = "The package with which to run the command.",
            providers = [FlutterPackageInfo],
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
        "package": attr.label(
            doc = "The package with which to run the build command.",
            providers = [FlutterPackageInfo],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)
