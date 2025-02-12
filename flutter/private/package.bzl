"""
Runs an executable in the Flutter SDK.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//flutter:providers.bzl", "FlutterPackageInfo")

def flutter_package(name):
    _flutter_package(
        name = name,
        pubspec = "pubspec.yaml",
        pubspec_lock = "pubspec.lock",
        lib = native.glob(["lib/**"]),
        bin = native.glob(["bin/**"], allow_empty = True),
        visibility = ["//visibility:public"],
    )

def _flutter_package_impl(ctx):
    pub_cache = ctx.actions.declare_directory("pub_cache")
    pre_pub_cache_deps = depset(
        ctx.files.pubspec + ctx.files.pubspec_lock + ctx.files.lib + ctx.files.bin,
        transitive = [ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter.deps],
    )
    info = FlutterPackageInfo(
        pub_cache = pub_cache,
        pubspec = ctx.files.pubspec[0],
        pubspec_lock = ctx.files.pubspec_lock[0],
        lib = ctx.files.lib,
        bin = ctx.files.bin,
        pre_pub_cache_deps = pre_pub_cache_deps,
        deps = depset(
            [pub_cache],
            transitive = [pre_pub_cache_deps],
        ),
    )

    runner, files = _make_flutter_runner(
        ctx = ctx,
        flutter_ctx = info,
        toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"],
        executable = False,
        args = ["pub", "get"],
        include_pub_cache = False,
    )

    ctx.actions.run(
        outputs = [pub_cache],
        executable = runner,
        inputs = files,
        mnemonic = "FlutterPubGet",
    )

    return info

_flutter_package = rule(
    implementation = _flutter_package_impl,
    attrs = {
        "pubspec": attr.label(
            doc = "The pubspec.yaml file .",
            allow_single_file = True,
            mandatory = True,
        ),
        "pubspec_lock": attr.label(
            doc = "The pubspec.lock file.",
            allow_single_file = True,
        ),
        "lib": attr.label_list(
            allow_files = True,
            mandatory = True,
        ),
        "bin": attr.label_list(
            allow_files = True,
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _make_flutter_runner(ctx, toolchain, flutter_ctx, args, executable, run_in_workspace = False, inputs = [], output = None, include_pub_cache = True):
    runner_template = toolchain.flutter.internal.runner_template
    flutter = toolchain.flutter.flutter
    out_ext = ".bash" if runner_template.basename.endswith(".bash.template") else ".bat"
    runner = ctx.actions.declare_file(ctx.label.name + out_ext)

    flutter_path = flutter.short_path if executable else flutter.path
    pub_cache_path = flutter_ctx.pub_cache.short_path if executable else flutter_ctx.pub_cache.path
    substitutions = {
        "@@FLUTTER@@": shell.quote(flutter_path) if out_ext == ".bash" else flutter_path,
        "@@RUN_IN_WORKSPACE@@": "1" if run_in_workspace else "0",
        "@@APP_DIR@@": flutter_ctx.pubspec.dirname,
        "@@ARGS@@": shell.array_literal(args) if out_ext == ".bash" else shell.array_literal(args)[1:][:-1].replace("'", ""),
        "@@OUTPUT_PATH@@": output.path if output else "''",
        "@@PUB_CACHE@@": shell.quote(pub_cache_path) if out_ext == ".bash" else pub_cache_path,
    }
    ctx.actions.expand_template(
        template = runner_template,
        output = runner,
        substitutions = substitutions,
        is_executable = True,
    )
    files = depset(
        inputs,
        transitive = [toolchain.flutter.deps, flutter_ctx.deps if include_pub_cache else flutter_ctx.pre_pub_cache_deps],
    )
    return runner, files

def make_flutter_runner(ctx, args, executable, run_in_workspace = False, inputs = [], output = None):
    return _make_flutter_runner(
        ctx = ctx,
        flutter_ctx = ctx.attr.package[FlutterPackageInfo],
        toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"],
        executable = executable,
        run_in_workspace = run_in_workspace,
        args = args,
        inputs = inputs,
        output = output,
    )
