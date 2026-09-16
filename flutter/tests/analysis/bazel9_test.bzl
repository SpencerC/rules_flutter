"""Regressions for Bazel 9 execution groups and workspace manifests."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "dart_format_test", "flutter_analyze_test", "flutter_library", "flutter_test")
load("//flutter:toolchain.bzl", "flutter_toolchain")

def _test_sdk_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runner = target[DefaultInfo].files_to_run.executable
    scripts = [
        action.content
        for action in analysistest.target_actions(env)
        if runner in action.outputs.to_list()
    ]
    asserts.equals(env, 1, len(scripts))
    if scripts:
        asserts.true(env, "test_sdk.sh" in scripts[0], "runner must use the test execution group's SDK")
        asserts.false(env, "build_sdk.sh" in scripts[0], "runner must not use the build execution group's SDK")

    runfiles = [f.basename for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(env, "test_sdk.sh" in runfiles, "the selected test SDK must be present in runfiles")
    return analysistest.end(env)

_test_sdk_test = analysistest.make(
    _test_sdk_test_impl,
    config_settings = {
        "//command_line_option:extra_execution_platforms": [
            "//flutter/tests/analysis:bazel9_build_platform",
            "//flutter/tests/analysis:bazel9_test_platform",
        ],
        "//command_line_option:extra_toolchains": [
            "//flutter/tests/analysis:bazel9_build_toolchain",
            "//flutter/tests/analysis:bazel9_test_toolchain",
        ],
    },
)

def _workspace_manifest_test_impl(ctx):
    env = analysistest.begin(ctx)
    manifests = [
        action.content
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FlutterWorkspaceManifest"
    ]
    asserts.equals(env, 1, len(manifests), "workspace manifests must have their own action mnemonic")
    if manifests:
        entries = manifests[0].splitlines()
        asserts.equals(env, ["lib/main.dart", "pubspec.yaml"], [entry.split("|")[0] for entry in entries])
        asserts.equals(env, 1, len([entry for entry in entries if "lib/main.dart" in entry]))
    return analysistest.end(env)

_workspace_manifest_test = analysistest.make(_workspace_manifest_test_impl)

def bazel9_test_suite(name):
    """Exercise separate build/test SDKs and stable deduplicated manifests.

    Args:
        name: Name of the test suite.
    """
    native.constraint_setting(name = "bazel9_execution")
    for kind in ["build", "test"]:
        native.constraint_value(
            name = "bazel9_" + kind + "_execution",
            constraint_setting = ":bazel9_execution",
        )
        native.platform(
            name = "bazel9_" + kind + "_platform",
            constraint_values = [":bazel9_" + kind + "_execution"],
        )
        flutter_toolchain(
            name = "bazel9_" + kind + "_sdk",
            target_tool = kind + "_sdk.sh",
        )
        native.toolchain(
            name = "bazel9_" + kind + "_toolchain",
            exec_compatible_with = [":bazel9_" + kind + "_execution"],
            toolchain = ":bazel9_" + kind + "_sdk",
            toolchain_type = "//flutter:toolchain_type",
        )

    tests = []
    for kind, test_rule in [("flutter", flutter_test), ("analyze", flutter_analyze_test), ("format", dart_format_test)]:
        target_name = name + "_" + kind + "_fixture_test"
        kwargs = {"srcs": ["lib/main.dart"]} if kind == "format" else {"embed": [":fixture_lib"]}
        test_rule(
            name = target_name,
            exec_compatible_with = [":bazel9_build_execution"],
            exec_group_compatible_with = {"test": [":bazel9_test_execution"]},
            tags = ["manual"],
            **kwargs
        )
        test_name = name + "_" + kind + "_sdk_test"
        _test_sdk_test(name = test_name, target_under_test = ":" + target_name)
        tests.append(":" + test_name)

    flutter_library(
        name = name + "_manifest_fixture",
        srcs = ["lib/main.dart"],
        data = ["lib/main.dart"],
        pubspec = "pubspec.yaml",
        tags = ["manual"],
    )
    _workspace_manifest_test(
        name = name + "_manifest_test",
        target_under_test = ":" + name + "_manifest_fixture",
    )
    tests.append(":" + name + "_manifest_test")
    native.test_suite(name = name, tests = tests)
