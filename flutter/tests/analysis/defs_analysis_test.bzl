"""Analysis tests for flutter_app build customization attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_BUILD_MNEMONICS = ["FlutterBuild", "FlutterBuildAndroid", "FlutterBuildIos"]

def _flutter_build_script(env):
    """Return the flutter build action's shell script for the target under test."""
    for action in analysistest.target_actions(env):
        if action.mnemonic not in _BUILD_MNEMONICS:
            continue
        return " ".join(action.argv)
    return None

def _build_command_test_impl(ctx):
    env = analysistest.begin(ctx)

    script = _flutter_build_script(env)
    asserts.true(env, script != None, "expected a FlutterBuild action")

    if script != None:
        for expected in ctx.attr.expected_substrings:
            asserts.true(
                env,
                expected in script,
                "expected FlutterBuild command to contain '{}'".format(expected),
            )
        for absent in ctx.attr.absent_substrings:
            asserts.false(
                env,
                absent in script,
                "expected FlutterBuild command to NOT contain '{}'".format(absent),
            )

    return analysistest.end(env)

build_command_test = analysistest.make(
    _build_command_test_impl,
    attrs = {
        "expected_substrings": attr.string_list(
            doc = "Substrings that must appear in the FlutterBuild action script.",
        ),
        "absent_substrings": attr.string_list(
            doc = "Substrings that must not appear in the FlutterBuild action script.",
        ),
    },
)

def _embed_guard_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "assemble_dep_caches = False")
    return analysistest.end(env)

# Embedding a library without an assembled dependency cache (as generated
# package repositories are) must fail at analysis time, not silently produce
# a runtime package config that drops every hosted dependency.
embed_guard_test = analysistest.make(
    _embed_guard_test_impl,
    expect_failure = True,
)
