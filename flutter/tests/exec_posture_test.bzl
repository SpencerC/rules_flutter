"""Unit tests for the execution-posture helpers in flutter_actions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_actions.bzl",
    "heavy_action_execution_requirements",
    "heavy_action_resource_set",
    "host_bound_action_execution_requirements",
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

    # Under //flutter:allow_remote_execution nothing is restricted:
    # remotely executed actions must store outputs in the remote CAS, so
    # remote_cache_trees is ignored there.
    asserts.equals(env, None, tree_output_execution_requirements(True, False))
    asserts.equals(env, None, tree_output_execution_requirements(True, True))

    # host_bound wins over both flags. The //flutter:build_runner_cache
    # opt-in hands the action an absolute path outside the sandbox and lets
    # it inherit the client env, so its result describes one machine and must
    # not reach a shared cache — nor a remote executor that cannot see the
    # directory at all.
    for allow_remote_exec in [False, True]:
        for remote_cache_trees in [False, True]:
            asserts.equals(
                env,
                {"no-remote-cache": "1", "no-remote-exec": "1"},
                tree_output_execution_requirements(
                    allow_remote_exec,
                    remote_cache_trees,
                    host_bound = True,
                ),
                "build_runner_cache must stay unshareable (allow_remote_exec=%s, remote_cache_trees=%s)" % (
                    allow_remote_exec,
                    remote_cache_trees,
                ),
            )
    return unittest.end(env)

def _host_bound_posture_test_impl(ctx):
    env = unittest.begin(ctx)

    # The android/ios builds read host toolchains and the network, neither of
    # which is an input. Their results must never be uploaded to a cache
    # shared with a machine holding a different Xcode/Gradle/Maven view.
    #
    # dependencies_declared covers the network half only: with the Maven closure
    # and the Gradle distribution declared as inputs there is nothing left to
    # fetch, but the Android SDK is still a path reference to a host install, so
    # no-sandbox and no-remote-cache do not move.
    for dependencies_declared, expected in [
        (
            False,
            {
                "no-remote-cache": "1",
                "no-remote-exec": "1",
                "no-sandbox": "1",
                "requires-network": "1",
            },
        ),
        (
            True,
            {
                "no-remote-cache": "1",
                "no-remote-exec": "1",
                "no-sandbox": "1",
            },
        ),
    ]:
        asserts.equals(
            env,
            expected,
            host_bound_action_execution_requirements(
                dependencies_declared = dependencies_declared,
            ),
            "dependencies_declared = {}".format(dependencies_declared),
        )

    # Extra requirements merge in without dropping any of the restrictions.
    ios = host_bound_action_execution_requirements({"requires-darwin": "1"})
    asserts.equals(env, "1", ios["requires-darwin"])
    asserts.equals(env, "1", ios["no-remote-cache"])
    asserts.equals(env, "1", ios["no-remote-exec"])
    asserts.equals(env, "1", ios["requires-network"])

    # Declaring the dependencies must not disturb a caller's extras.
    offline_ios = host_bound_action_execution_requirements(
        {"requires-darwin": "1"},
        dependencies_declared = True,
    )
    asserts.equals(env, "1", offline_ios["requires-darwin"])
    asserts.false(
        env,
        "requires-network" in offline_ios,
        "requires-network survived dependencies_declared",
    )

    # The default argument must not accumulate across calls.
    asserts.false(
        env,
        "requires-darwin" in host_bound_action_execution_requirements(),
        "the shared default dict leaked a caller's extra requirement",
    )
    return unittest.end(env)

_default_posture_test = unittest.make(_default_posture_test_impl)
_resource_set_test = unittest.make(_resource_set_test_impl)
_tree_output_posture_test = unittest.make(_tree_output_posture_test_impl)
_host_bound_posture_test = unittest.make(_host_bound_posture_test_impl)

def exec_posture_test_suite(name):
    unittest.suite(
        name,
        _default_posture_test,
        _resource_set_test,
        _tree_output_posture_test,
        _host_bound_posture_test,
    )
