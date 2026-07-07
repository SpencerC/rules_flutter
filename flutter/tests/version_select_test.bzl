"""Unit tests for the semver-aware toolchain version selection helpers.

See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:version_select.bzl", "highest_version", "version_sort_key")

def _sort_key_impl(ctx):
    env = unittest.begin(ctx)

    # Plain semver parses to a list of ints.
    asserts.equals(env, [3, 24, 0], version_sort_key("3.24.0"))
    asserts.equals(env, [3, 38, 10], version_sort_key("3.38.10"))

    # Pre-release / build suffix compares on the numeric prefix.
    asserts.equals(env, [3, 24, 0], version_sort_key("3.24.0-1.2.pre"))
    asserts.equals(env, [9, 99, 0], version_sort_key("9.99.0-unlisted"))

    return unittest.end(env)

def _ordering_impl(ctx):
    env = unittest.begin(ctx)

    # The two orderings that raw-string (lexicographic) sorting gets wrong:
    #   "3.9.0" > "3.35.0" lexically ("9" > "3"), but 3.35.0 is newer.
    asserts.equals(env, "3.35.0", highest_version(["3.9.0", "3.35.0"]))

    #   "3.38.10" < "3.38.9" lexically (char '1' < '9'), but 3.38.10 is newer.
    asserts.equals(env, "3.38.10", highest_version(["3.38.9", "3.38.10"]))

    # Larger mixed set.
    asserts.equals(
        env,
        "3.44.5",
        highest_version(["3.24.0", "3.44.5", "3.38.10", "3.41.9", "3.5.0"]),
    )

    # Single element and empty.
    asserts.equals(env, "3.24.0", highest_version(["3.24.0"]))
    asserts.equals(env, None, highest_version([]))

    return unittest.end(env)

_sort_key_test = unittest.make(_sort_key_impl)
_ordering_test = unittest.make(_ordering_impl)

def version_select_test_suite(name):
    unittest.suite(name, _sort_key_test, _ordering_test)
