"""
Runs an executable in the Flutter SDK.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//flutter:providers.bzl", "FlutterContextInfo")

def _flutter_context(ctx):
    pub_cache = ctx.actions.declare_directory("pub_cache")
    info = FlutterContextInfo(
        pub_cache = pub_cache,
        pubspec = ctx.files.pubspec[0],
        pubspec_lock = ctx.files.pubspec_lock[0],
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
    )

    return info

flutter_context = rule(
    implementation = _flutter_context,
    attrs = {
        "pubspec": attr.label(
            doc = "The pubspec.yaml file .",
            allow_single_file = True,
            mandatory = True,
        ),
        "pubspec_lock": attr.label(
            doc = "The pubspec.lock file.",
            allow_single_file = True,
            mandatory = True,
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _make_flutter_runner(ctx, toolchain, flutter_ctx, args, executable, inputs = [], output = None, include_pub_cache = True):
    runner_template = toolchain.flutter.internal.runner_template
    flutter = toolchain.flutter.flutter
    out_ext = ".bash" if runner_template.basename.endswith(".bash.template") else ".bat"
    runner = ctx.actions.declare_file(ctx.label.name + out_ext)

    flutter_path = flutter.short_path if executable else flutter.path
    pub_cache_path = flutter_ctx.pub_cache.short_path if executable else flutter_ctx.pub_cache.path
    substitutions = {
        "@@FLUTTER@@": shell.quote(flutter_path) if out_ext == ".bash" else flutter_path,
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
        [flutter, flutter_ctx.pubspec, flutter_ctx.pubspec_lock] +
        toolchain.flutter.bin + inputs +
        ([flutter_ctx.pub_cache] if include_pub_cache else []),
    )
    return runner, files

def make_flutter_runner(ctx, args, executable, inputs = [], output = None):
    return _make_flutter_runner(
        ctx = ctx,
        flutter_ctx = ctx.attr.context[FlutterContextInfo],
        toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"],
        executable = executable,
        args = args,
        inputs = inputs,
        output = output,
    )
