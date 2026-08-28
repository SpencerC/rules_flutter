"""Execution tests for the package_config reconciliation in flutter_actions.bzl.

The reconciliation is Python that runs inside FlutterPrepareDeps (and inside
the runtime bootstrap), so these run it for real against a fixture pub cache
rather than asserting on the script text. The failure they pin down is the one
that took a Flutter SDK bump to surface: when the cache holds a different
version than pub_deps.json pins, the package used to vanish from
package_config.json without a word, and the build died much later inside
build_runner naming a package nobody had written down.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_actions.bzl", "PACKAGE_CONFIG_RECONCILE_PY")

# The reconciliation expects `missing`, `cache_root`, `os` and `sys`; the
# prepare script supplies them from the declared metadata and the assembled
# cache, this supplies them from the test case.
_DRIVER_PREAMBLE = """import os
import sys

cache_root = sys.argv[1]
hosted = os.path.join(cache_root, "hosted", "pub.dev")
missing = [
{entries}]
"""

_ENTRY = '    ("{name}", "{version}", "{source}", os.path.join(hosted, "{name}-{version}")),\n'

def _reconcile_case_impl(ctx):
    entries = "".join([
        _ENTRY.format(name = name, version = version, source = "hosted")
        for name, version in ctx.attr.pinned.items()
    ] + [
        _ENTRY.format(name = name, version = "0.0.0", source = "sdk")
        for name in ctx.attr.pinned_sdk
    ])

    driver = ctx.actions.declare_file(ctx.label.name + "_driver.py")
    ctx.actions.write(
        output = driver,
        content = _DRIVER_PREAMBLE.format(entries = entries) + PACKAGE_CONFIG_RECONCILE_PY + "\n",
    )

    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    cache_dir = marker.path + ".cache/hosted/pub.dev"

    checks = ['grep -qF -- {} "$STDERR" || fail "expected in stderr: {}"'.format(
        _sh_quote(text),
        _sh_quote(text),
    ) for text in ctx.attr.expect_stderr]
    checks += ['! grep -qF -- {} "$STDERR" || fail "must not be in stderr: {}"'.format(
        _sh_quote(text),
        _sh_quote(text),
    ) for text in ctx.attr.reject_stderr]

    ctx.actions.run_shell(
        inputs = [driver],
        outputs = [marker],
        command = """set -uo pipefail
fail() {{ echo "FAIL({label}): $1" >&2; cat "$STDERR" >&2; exit 1; }}

PYTHON_BIN="$(command -v python3 || command -v python)"
CACHE="{cache_dir}"
STDERR="{marker}.stderr"
rm -rf "$CACHE"
mkdir -p "$CACHE"
for PKG in {cached}; do
    mkdir -p "$CACHE/$PKG"
done

"$PYTHON_BIN" "{driver}" "$(dirname "$(dirname "$CACHE")")" 2> "$STDERR"
RC=$?
if [ "$RC" != "{expect_exit}" ]; then
    fail "exit $RC, expected {expect_exit}"
fi
{checks}
touch "{marker}"
""".format(
            label = str(ctx.label),
            cache_dir = cache_dir,
            cached = " ".join([_sh_quote(pkg) for pkg in ctx.attr.cached]) if ctx.attr.cached else '""',
            driver = driver.path,
            marker = marker.path,
            expect_exit = "1" if ctx.attr.must_fail else "0",
            checks = "\n".join(checks),
        ),
        mnemonic = "PackageConfigReconcileTest",
        progress_message = "Checking package_config reconciliation for %s" % ctx.label.name,
    )

    return [DefaultInfo(files = depset([marker]))]

def _sh_quote(arg):
    return "'" + arg.replace("'", "'\"'\"'") + "'"

_reconcile_case = rule(
    implementation = _reconcile_case_impl,
    attrs = {
        "cached": attr.string_list(
            doc = "hosted/pub.dev/<entry> directories to create in the fixture cache.",
        ),
        "expect_stderr": attr.string_list(
            doc = "Substrings the reconciliation must report.",
        ),
        "must_fail": attr.bool(
            doc = "Whether the reconciliation must reject the cache.",
        ),
        "pinned": attr.string_dict(
            doc = "Hosted packages pub_deps.json pins that are not in the cache.",
        ),
        "pinned_sdk": attr.string_list(
            doc = "SDK-sourced packages that are not on disk.",
        ),
        "reject_stderr": attr.string_list(
            doc = "Substrings the reconciliation must not report.",
        ),
    },
)

def package_config_reconcile_test(
        name,
        pinned = {},
        pinned_sdk = [],
        cached = [],
        expect_failure = False,
        expect_stderr = [],
        reject_stderr = []):
    """Run the package_config reconciliation over a fixture cache.

    Args:
        name: Test target name.
        pinned: Hosted {package: version} pairs declared but absent from the cache.
        pinned_sdk: SDK-sourced package names declared but absent on disk.
        cached: `hosted/pub.dev` entries ("name-version") the fixture cache holds.
        expect_failure: Whether the reconciliation must reject the cache.
        expect_stderr: Substrings the reconciliation must report.
        reject_stderr: Substrings the reconciliation must not report.
    """
    _reconcile_case(
        name = name + "_case",
        cached = cached,
        expect_stderr = expect_stderr,
        must_fail = expect_failure,
        pinned = pinned,
        pinned_sdk = pinned_sdk,
        reject_stderr = reject_stderr,
        tags = ["manual"],
    )
    build_test(
        name = name,
        targets = [":" + name + "_case"],
    )
