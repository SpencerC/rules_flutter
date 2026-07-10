"""Unit tests for the execution-posture helpers in flutter_actions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_actions.bzl",
    "heavy_action_execution_requirements",
    "heavy_action_resource_set",
    "tree_output_execution_requirements",
)

def _default_posture_test_impl(ctx):
    env = unittest.begin(ctx)

    # The default keeps heavy hermetic actions off remote executors while
    # leaving remote caching enabled.
    asserts.equals(
        env,
        {"no-remote-exec": "1"},
        heavy_action_execution_requirements(False),
    )

    # //flutter:allow_remote_execution removes the restriction entirely.
    asserts.equals(env, None, heavy_action_execution_requirements(True))
    return unittest.end(env)

def _resource_set_test_impl(ctx):
    env = unittest.begin(ctx)
    resources = heavy_action_resource_set("darwin", 100)
    asserts.true(env, resources["cpu"] >= 2, "heavy actions must reserve multiple CPUs")
    asserts.true(env, resources["memory"] >= 1024, "heavy actions must reserve real memory")
    return unittest.end(env)

def _tree_output_posture_test_impl(ctx):
    env = unittest.begin(ctx)

    # Default posture: local execution AND no remote-cache upload of the fat
    # tree outputs (the local disk cache stays eligible for both).
    asserts.equals(
        env,
        {"no-remote-exec": "1", "no-remote-cache": "1"},
        tree_output_execution_requirements(False, False),
    )

    # //flutter:remote_cache_trees restores remote caching only.
    asserts.equals(
        env,
        {"no-remote-exec": "1"},
        tree_output_execution_requirements(False, True),
    )

    # //flutter:allow_remote_execution lifts the execution restriction only.
    asserts.equals(
        env,
        {"no-remote-cache": "1"},
        tree_output_execution_requirements(True, False),
    )

    # Both flags: no restrictions at all.
    asserts.equals(env, None, tree_output_execution_requirements(True, True))
    return unittest.end(env)

_default_posture_test = unittest.make(_default_posture_test_impl)
_resource_set_test = unittest.make(_resource_set_test_impl)
_tree_output_posture_test = unittest.make(_tree_output_posture_test_impl)

def exec_posture_test_suite(name):
    unittest.suite(name, _default_posture_test, _resource_set_test, _tree_output_posture_test)
