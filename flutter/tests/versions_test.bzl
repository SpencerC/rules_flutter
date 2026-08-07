"""Unit tests for starlark helpers
See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:toolchains_repo.bzl", "PLATFORMS")
load("//flutter/private:versions.bzl", "TOOL_VERSIONS")

# Platforms that download a sibling's release archive and are re-architected
# after unpacking, so they verify against that sibling's integrity and have no
# entry of their own. Mirrors _ARCHIVE_ALIASES in repositories.bzl.
_ARCHIVE_ALIASES = {
    "linux_arm64": "linux",
}

def _smoke_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.24.0", TOOL_VERSIONS.keys()[0])
    return unittest.end(env)

def _every_platform_has_integrity_test_impl(ctx):
    """Every registered platform must be fetchable.

    Registering a platform in PLATFORMS without adding its hashes here yields a
    toolchain that resolves and then fails at fetch with "provide integrity" —
    and only on that platform's own host, which in practice means only in
    someone else's CI. Catch it at analysis time instead.
    """
    env = unittest.begin(ctx)

    expected = sorted({
        _ARCHIVE_ALIASES.get(platform, platform): None
        for platform in PLATFORMS.keys()
    }.keys())

    for version, hashes in TOOL_VERSIONS.items():
        # A version predating a platform's first release legitimately has no
        # entry for it; the generator omits the key rather than inventing one.
        # What must never happen is a version covering nothing, or a key that
        # no registered platform would ever look up.
        asserts.true(
            env,
            len(hashes) > 0,
            "Flutter {} has no integrity for any platform".format(version),
        )
        for key, sri in hashes.items():
            asserts.true(
                env,
                key in expected,
                "Flutter {} lists unknown platform '{}' — register it in PLATFORMS or drop it".format(version, key),
            )
            asserts.true(
                env,
                sri.startswith("sha256-") and len(sri) > len("sha256-"),
                "Flutter {} has a malformed integrity for {}: '{}'".format(version, key, sri),
            )

    # The newest pin must cover every platform we register, so a newly added
    # platform cannot ship with its hashes forgotten.
    latest = TOOL_VERSIONS.keys()[-1]
    asserts.equals(
        env,
        expected,
        sorted(TOOL_VERSIONS[latest].keys()),
        "the newest version ({}) must cover every registered platform".format(latest),
    )
    return unittest.end(env)

# The unittest library requires that we export the test cases as named test rules,
# but their names are arbitrary and don't appear anywhere.
_t0_test = unittest.make(_smoke_test_impl)
_t1_test = unittest.make(_every_platform_has_integrity_test_impl)

def versions_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test)
