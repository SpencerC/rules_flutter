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

    _tool_runner(
        name = name + ".dart",
        tool = "dart",
        package = ":package",
    )

    _tool_runner(
        name = name + ".flutter",
        tool = "flutter",
        package = ":package",
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

    runner, files = _make_tool_runner(
        ctx = ctx,
        package = info,
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

def _make_tool_runner(
        ctx,
        toolchain,
        package,
        args,
        executable,
        tool = "flutter",
        run_in_workspace = False,
        use_host_pub_cache = False,
        inputs = [],
        output = None,
        include_pub_cache = True):
    if tool not in ["flutter", "dart"]:
        fail("Invalid tool: %s" % tool)

    runner_template = toolchain.flutter.internal.runner_template
    tool = toolchain.flutter.flutter if tool == "flutter" else toolchain.flutter.dart
    out_ext = ".bash" if runner_template.basename.endswith(".bash.template") else ".bat"
    runner = ctx.actions.declare_file(ctx.label.name + out_ext)

    flutter_path = tool.short_path if executable else tool.path
    pub_cache_path = package.pub_cache.short_path if executable else package.pub_cache.path
    substitutions = {
        "@@TOOL@@": shell.quote(flutter_path) if out_ext == ".bash" else flutter_path,
        "@@RUN_IN_WORKSPACE@@": "1" if run_in_workspace else "0",
        "@@APP_DIR@@": package.pubspec.dirname,
        "@@ARGS@@": shell.array_literal(args) if out_ext == ".bash" else shell.array_literal(args)[1:][:-1].replace("'", ""),
        "@@OUTPUT_PATH@@": output.path if output else "''",
        "@@PUB_CACHE@@": "''",
    }
    if not use_host_pub_cache:
        substitutions["@@PUB_CACHE@@"] = shell.quote(pub_cache_path) if out_ext == ".bash" else pub_cache_path

    ctx.actions.expand_template(
        template = runner_template,
        output = runner,
        substitutions = substitutions,
        is_executable = True,
    )
    files = depset(
        inputs,
        transitive = [toolchain.flutter.deps, package.deps if include_pub_cache else package.pre_pub_cache_deps],
    )
    return runner, files

def make_tool_runner(
        ctx,
        args,
        executable,
        tool = "flutter",
        use_host_pub_cache = False,
        run_in_workspace = False,
        inputs = [],
        output = None):
    return _make_tool_runner(
        ctx = ctx,
        tool = tool,
        package = ctx.attr.package[FlutterPackageInfo],
        toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"],
        executable = executable,
        use_host_pub_cache = use_host_pub_cache,
        run_in_workspace = run_in_workspace,
        args = args,
        inputs = inputs,
        output = output,
    )

def _tool_runner_impl(ctx):
    runner, files = make_tool_runner(
        ctx = ctx,
        args = ctx.attr.args,
        executable = True,
        tool = ctx.attr.tool,
        use_host_pub_cache = True,
        run_in_workspace = True,
    )
    return DefaultInfo(
        files = files,
        runfiles = ctx.runfiles(files = files.to_list()),
        executable = runner,
    )

_tool_runner = rule(
    implementation = _tool_runner_impl,
    attrs = {
        "tool": attr.string(values = ["flutter", "dart"]),
        "package": attr.label(
            doc = "The package with which to run the command.",
            providers = [FlutterPackageInfo],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)
