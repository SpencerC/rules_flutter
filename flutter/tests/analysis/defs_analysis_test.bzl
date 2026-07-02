"""Analysis tests for flutter_app build customization attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _flutter_build_script(env):
    """Return the FlutterBuild action's shell script for the target under test."""
    for action in analysistest.target_actions(env):
        if action.mnemonic != "FlutterBuild":
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
