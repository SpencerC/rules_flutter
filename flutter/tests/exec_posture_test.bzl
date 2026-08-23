"""Unit tests for the execution-posture helpers in flutter_actions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_actions.bzl",
    "TREE_PUB_CACHE",
    "TREE_WORKSPACE",
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

    local_only = {"no-remote-exec": "1", "no-remote-cache": "1"}
    cached = {"no-remote-exec": "1"}

    # "none" (the default): local execution AND no remote-cache upload of
    # either kind of tree (the local disk cache stays eligible for both).
    for kind in [TREE_WORKSPACE, TREE_PUB_CACHE]:
        asserts.equals(
            env,
            local_only,
            tree_output_execution_requirements(False, "none", kind = kind),
            "none must keep %s out of the remote cache" % kind,
        )

    # The workspace kind is the default, so a caller that passes no kind gets
    # the same answer as one that names it.
    asserts.equals(
        env,
        local_only,
        tree_output_execution_requirements(False, "none"),
    )

    # "workspaces" remote-caches the ~100MB workspace trees and leaves the
    # multi-GB pub cache local -- the split the setting exists for.
    asserts.equals(
        env,
        cached,
        tree_output_execution_requirements(False, "workspaces", kind = TREE_WORKSPACE),
    )
    asserts.equals(
        env,
        local_only,
        tree_output_execution_requirements(False, "workspaces", kind = TREE_PUB_CACHE),
    )

    # "all" remote-caches both.
    for kind in [TREE_WORKSPACE, TREE_PUB_CACHE]:
        asserts.equals(
            env,
            cached,
            tree_output_execution_requirements(False, "all", kind = kind),
            "all must remote-cache %s" % kind,
        )

    # Under //flutter:allow_remote_execution nothing is restricted:
    # remotely executed actions must store outputs in the remote CAS, so
    # remote_cache_trees is ignored there.
    for setting in ["none", "workspaces", "all"]:
        for kind in [TREE_WORKSPACE, TREE_PUB_CACHE]:
            asserts.equals(
                env,
                None,
                tree_output_execution_requirements(True, setting, kind = kind),
            )
    return unittest.end(env)

_default_posture_test = unittest.make(_default_posture_test_impl)
_resource_set_test = unittest.make(_resource_set_test_impl)
_tree_output_posture_test = unittest.make(_tree_output_posture_test_impl)

def exec_posture_test_suite(name):
    unittest.suite(name, _default_posture_test, _resource_set_test, _tree_output_posture_test)
