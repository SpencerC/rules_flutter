"""Unit tests for the execution-posture helpers in flutter_actions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_actions.bzl",
    "TREE_PUB_CACHE",
    "TREE_WORKSPACE",
    "heavy_action_execution_requirements",
    "heavy_action_resource_set",
    "prepare_deps_tree_kind",
    "tree_output_execution_requirements",
)

# The two postures tree_output_execution_requirements can return under local
# execution.
_LOCAL_ONLY = {"no-remote-exec": "1", "no-remote-cache": "1"}
_REMOTE_CACHED = {"no-remote-exec": "1"}

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

    # "none" (the default): local execution AND no remote-cache upload of
    # either kind of tree (the local disk cache stays eligible for both).
    for kind in [TREE_WORKSPACE, TREE_PUB_CACHE]:
        asserts.equals(
            env,
            _LOCAL_ONLY,
            tree_output_execution_requirements(False, "none", kind = kind),
            "none must keep %s out of the remote cache" % kind,
        )

    # The workspace kind is the default, so a caller that passes no kind gets
    # the same answer as one that names it.
    asserts.equals(
        env,
        _LOCAL_ONLY,
        tree_output_execution_requirements(False, "none"),
    )

    # "workspaces" remote-caches the ~100MB workspace trees and leaves the
    # multi-GB pub cache local -- the split the setting exists for.
    asserts.equals(
        env,
        _REMOTE_CACHED,
        tree_output_execution_requirements(False, "workspaces", kind = TREE_WORKSPACE),
    )
    asserts.equals(
        env,
        _LOCAL_ONLY,
        tree_output_execution_requirements(False, "workspaces", kind = TREE_PUB_CACHE),
    )

    # "all" remote-caches both.
    for kind in [TREE_WORKSPACE, TREE_PUB_CACHE]:
        asserts.equals(
            env,
            _REMOTE_CACHED,
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

def _prepare_deps_kind_test_impl(ctx):
    env = unittest.begin(ctx)

    # FlutterPrepareDeps declares its own pub cache tree unless it consumes a
    # preassembled one, and an action carries a single posture for all of its
    # outputs. Classifying it as a workspace in that case would let
    # `workspaces` upload a merged pub cache -- the exact split the setting
    # exists to make.
    asserts.equals(
        env,
        TREE_PUB_CACHE,
        prepare_deps_tree_kind(True),
        "a prepare action that emits a pub cache must be classified as one",
    )
    asserts.equals(
        env,
        _LOCAL_ONLY,
        tree_output_execution_requirements(
            False,
            "workspaces",
            kind = prepare_deps_tree_kind(True),
        ),
        "workspaces must not remote-cache a prepare action carrying a pub cache",
    )

    # With a preassembled cache the action produces workspace trees only.
    asserts.equals(
        env,
        TREE_WORKSPACE,
        prepare_deps_tree_kind(False),
    )
    asserts.equals(
        env,
        _REMOTE_CACHED,
        tree_output_execution_requirements(
            False,
            "workspaces",
            kind = prepare_deps_tree_kind(False),
        ),
    )
    return unittest.end(env)

_default_posture_test = unittest.make(_default_posture_test_impl)
_resource_set_test = unittest.make(_resource_set_test_impl)
_tree_output_posture_test = unittest.make(_tree_output_posture_test_impl)
_prepare_deps_kind_test = unittest.make(_prepare_deps_kind_test_impl)

def exec_posture_test_suite(name):
    unittest.suite(
        name,
        _default_posture_test,
        _prepare_deps_kind_test,
        _resource_set_test,
        _tree_output_posture_test,
    )
