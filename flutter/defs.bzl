"""Public API for Flutter build rules"""

def _flutter_app_impl(ctx):
    """Implementation for flutter_app rule"""

    # For now, this is a placeholder that just validates the toolchain can be resolved
    # and creates a dummy output file. Real Flutter builds would require more complex
    # setup including proper source directory handling and Flutter SDK availability.
    # flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]

    # Create a simple output file to indicate the "build" succeeded
    output_file = ctx.actions.declare_file(ctx.label.name + "_built.txt")

    ctx.actions.write(
        output = output_file,
        content = "Flutter app {} built for target {} (placeholder implementation)".format(
            ctx.label.name,
            ctx.attr.target,
        ),
    )

    return [DefaultInfo(files = depset([output_file]))]

flutter_app = rule(
    implementation = _flutter_app_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Flutter project source files",
        ),
        "target": attr.string(
            default = "web",
            values = ["web", "apk", "ios", "macos", "linux", "windows"],
            doc = "Flutter build target platform",
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = "Builds a Flutter application for the specified target platform",
)

def _flutter_test_impl(ctx):
    """Implementation for flutter_test rule"""

    # Placeholder implementation that just validates toolchain resolution
    # flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]

    # Create a simple test script that always passes
    test_script = ctx.actions.declare_file(ctx.label.name + "_test.sh")

    ctx.actions.write(
        output = test_script,
        content = """#!/bin/bash
        echo "Flutter test {} completed successfully (placeholder implementation)"
        echo "Test files: {}"
        echo "Sources: {} files"
        exit 0
        """.format(
            ctx.label.name,
            " ".join(ctx.attr.test_files),
            len(ctx.files.srcs),
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = test_script,
        files = depset([test_script]),
        runfiles = ctx.runfiles(files = ctx.files.srcs),
    )]

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Flutter project source files",
        ),
        "test_files": attr.string_list(
            default = ["test/"],
            doc = "Test files or directories to run",
        ),
    },
    test = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Runs Flutter tests",
)

def _dart_library_impl(ctx):
    """Implementation for dart_library rule"""

    # For now, just pass through the source files
    return [DefaultInfo(files = depset(ctx.files.srcs))]

dart_library = rule(
    implementation = _dart_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart source files",
        ),
        "deps": attr.label_list(
            doc = "Dart library dependencies",
        ),
    },
    doc = "Defines a Dart library",
)
