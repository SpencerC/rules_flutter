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

def _flutter_build_action(env):
    """Return the flutter build action for the target under test."""
    for action in analysistest.target_actions(env):
        if action.mnemonic in _BUILD_MNEMONICS:
            return action
    return None

def _android_offline_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = _flutter_build_action(env)
    asserts.true(env, action != None, "expected a FlutterBuild action")

    if action != None:
        script = " ".join(action.argv)
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

        # The assertion that actually carries the hermeticity claim. Mentioning
        # the mirror in the script proves only that a path got interpolated;
        # what makes the action's key describe its result -- and what justifies
        # dropping requires-network -- is those files being *inputs*.
        input_paths = [f.path for f in action.inputs.to_list()]
        for expected in ctx.attr.expected_inputs:
            asserts.true(
                env,
                [p for p in input_paths if p.endswith(expected)] != [],
                "expected '{}' among the FlutterBuild action's {} inputs".format(
                    expected,
                    len(input_paths),
                ),
            )

    return analysistest.end(env)

_ANDROID_OFFLINE_TEST_ATTRS = {
    "expected_substrings": attr.string_list(
        doc = "Substrings that must appear in the FlutterBuild action script.",
    ),
    "expected_inputs": attr.string_list(
        doc = "Path suffixes that must each match at least one action input.",
    ),
    "absent_substrings": attr.string_list(
        doc = "Substrings that must not appear in the FlutterBuild action script.",
    ),
}

# Same body, two rules: analysistest bakes the build settings into the rule via
# config_settings, so "offline on" and "offline off" cannot be one rule with a
# parameter.
android_offline_test = analysistest.make(
    _android_offline_test_impl,
    attrs = _ANDROID_OFFLINE_TEST_ATTRS,
    config_settings = {
        str(Label("//flutter:android_gradle_offline")): True,
    },
)

android_online_test = analysistest.make(
    _android_offline_test_impl,
    attrs = _ANDROID_OFFLINE_TEST_ATTRS,
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
