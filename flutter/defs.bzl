"Public API re-exports"

load("//flutter:providers.bzl", "FlutterContextInfo")
load("//flutter/private:context.bzl", "flutter_context", "make_flutter_runner")

def flutter_app(name, pubspec, pubspec_lock, srcs, test_files = []):
    """Flutter app target."""
    flutter_context(
        name = name + "_flutter_context",
        pubspec = pubspec,
        pubspec_lock = pubspec_lock,
    )
    flutter_test(
        name = name + "_test",
        srcs = srcs + test_files,
        context = ":" + name + "_flutter_context",
    )

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
