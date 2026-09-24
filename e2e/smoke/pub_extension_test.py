"""Exercise the production pub extension with real Bazel input invalidation.

Repository fetching is stubbed: these tests inspect declarations, not SDKs or
pub.dev archives. An empty bazel_tools module and registry keep the fixture
independent of the network and of the host's installed toolchains.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from python.runfiles import runfiles


RUNFILES = runfiles.Create()


def runfile(path):
    if path.startswith("../"):
        path = path[3:]
    return Path(RUNFILES.Rlocation(path)).resolve()


BAZEL = runfile(sys.argv.pop(1))
EXTENSION = runfile(sys.argv.pop(1))


class PubExtensionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.install_temp = tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"])
        cls.addClassCleanup(cls.install_temp.cleanup)
        # The executable's embedded JDK is immutable. Share its extraction while
        # keeping each case's server and extension cache isolated.
        cls.install_base = str(Path(cls.install_temp.name) / "install")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.write("BUILD.bazel", "")
        self.write("MODULE.bazel", '''module(name = "pub_extension_test")
pub = use_extension("//flutter:extensions.bzl", "pub")
use_repo(pub, "pub_alpha")
''')
        self.write("tools/MODULE.bazel", 'module(name = "bazel_tools")\n')
        self.write("flutter/BUILD.bazel", "")
        self.write("flutter/private/BUILD.bazel", "")
        shutil.copyfile(EXTENSION, self.workspace / "flutter/extensions.bzl")
        self.write("flutter/private/versions.bzl", "TOOL_VERSIONS = {}\n")
        self.write("flutter/private/version_select.bzl", '''def highest_version(versions):
    fail("The pub extension must not select an SDK")
''')
        self.write("flutter/repositories.bzl", '''def flutter_register_toolchains(**kwargs):
    fail("The pub extension must not fetch an SDK")
''')
        self.write("flutter/private/pub_repository.bzl", '''def _impl(ctx):
    fail("Inspect repository declarations without fetching packages")

pub_dev_repository = repository_rule(
    implementation = _impl,
    attrs = {
        "package": attr.string(),
        "version": attr.string(),
        "hosted_deps": attr.string_list(),
        "hosted_deps_explicit": attr.bool(),
        "keep_vendored_cache": attr.bool(),
        "resolve_deps": attr.bool(),
    },
)
''')
        (self.root / "registry").mkdir()
        self.startup = [
            str(BAZEL),
            "--ignore_all_rc_files",
            "--install_base=" + self.install_base,
            "--output_user_root=" + str(self.root / "bazel"),
            "--host_jvm_args=-XX:ActiveProcessorCount=2",
        ]
        self.env = dict(os.environ)
        # A nested Bazel is not running the outer test's binaries/runfiles.
        for name in ("RUNFILES_DIR", "RUNFILES_MANIFEST_FILE", "JAVA_RUNFILES",
                     "TEST_SRCDIR", "TEST_TMPDIR", "TEST_WORKSPACE"):
            self.env.pop(name, None)
        self.addCleanup(self.shutdown)

    def shutdown(self):
        subprocess.run(self.startup + ["shutdown"], cwd=self.workspace,
                       env=self.env, capture_output=True, timeout=60, check=True)

    def write(self, relative, content):
        path = self.workspace / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def declare(self, *labels):
        """Replace the scan with pub.from_file tags for the given reports."""
        tags = "".join('pub.from_file(pub_deps = "{}")\n'.format(label) for label in labels)
        self.write("MODULE.bazel", '''module(name = "pub_extension_test")
pub = use_extension("//flutter:extensions.bzl", "pub")
''' + tags + '''use_repo(pub, "pub_alpha")
''')

    def report(self, relative, package="alpha", version="1.0.0"):
        return self.write(relative, json.dumps({"packages": [{
            "name": package,
            "version": version,
            "source": "hosted",
            "dependencies": [],
        }]}))

    def show(self, package="alpha", version="1.0.0", mode="update", expected_error=None):
        # Bazel 9 resolves embedded bazel_tools before MODULE.bazel overrides.
        # Override the canonical repository to keep this fixture offline.
        result = subprocess.run(
            self.startup + ["mod", "show_repo", "@@+pub+pub_" + package,
                            "--override_repository=bazel_tools=" + str(self.workspace / "tools"),
                            "--registry=" + (self.root / "registry").as_uri(),
                            "--lockfile_mode=" + mode, "--color=no", "--curses=no"],
            cwd=self.workspace, env=self.env, capture_output=True, text=True,
            timeout=90,
        )
        if expected_error:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(expected_error, result.stderr)
        elif version is None:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("no such repo", result.stderr)
            self.assertIn("pub_" + package, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('version = "' + version + '"', result.stdout)
        return result.stdout

    def test_dependency_changes_do_not_change_lockfile(self):
        self.report("app/pub_deps.json")
        self.show()
        lock = self.workspace / "MODULE.bazel.lock"
        original = lock.read_bytes() if lock.exists() else None
        self.assertFalse(json.loads(original or "{}").get("moduleExtensions"))

        self.report("app/pub_deps.json", version="2.0.0")
        self.show(version="2.0.0")
        self.assertEqual(original, lock.read_bytes() if lock.exists() else None)

        self.report("app/pub_deps.json", version="3.0.0")
        self.show(version="3.0.0", mode="error")
        self.assertEqual(original, lock.read_bytes() if lock.exists() else None)

        # A fresh server must also accept the lockfile without extension state.
        self.shutdown()
        self.show(version="3.0.0", mode="error")
        self.assertEqual(original, lock.read_bytes() if lock.exists() else None)

    def test_upgrade_removes_existing_extension_lock_entry(self):
        extension = self.workspace / "flutter/extensions.bzl"
        production = extension.read_text()
        extension.write_text(production.replace("reproducible = True", "reproducible = False"))
        self.report("app/pub_deps.json")
        self.show()
        lock = self.workspace / "MODULE.bazel.lock"
        self.assertTrue(json.loads(lock.read_text())["moduleExtensions"])

        extension.write_text(production)
        self.show()
        self.assertFalse(json.loads(lock.read_text()).get("moduleExtensions"))

    def test_discovery_tracks_files_and_ignored_directories(self):
        self.report("app/pub_deps.json")
        (self.workspace / "existing").mkdir()
        self.show()

        # No known report changes: only the watched directory listing changes.
        added = self.report("existing/pub_deps.json", package="beta")
        self.show(package="beta")
        added.unlink()
        self.show(package="beta", version=None)
        self.report("new/nested/pub_deps.json", package="beta", version="2.0.0")
        self.show(package="beta", version="2.0.0")

        # Removing a report must stop its old pin from conflicting with a new one.
        (self.workspace / "new/nested/pub_deps.json").unlink()
        self.report("existing/pub_deps.json", package="beta", version="3.0.0")
        self.show(package="beta", version="3.0.0")

        # Creating, editing, then deleting .bazelignore must change discovery.
        ignore = self.write(".bazelignore", "existing/ # omit stale pins\n")
        self.show(package="beta", version=None)
        ignore.write_text("# include all reports again\n")
        self.show(package="beta", version="3.0.0")
        ignore.write_text("existing\n")
        self.show(package="beta", version=None)
        ignore.unlink()
        self.show(package="beta", version="3.0.0")

    def test_deleted_directory_recovery_on_bazel_9_2(self):
        self.report("app/pub_deps.json")
        self.report("removed/nested/pub_deps.json", package="beta")
        self.show(package="beta")
        shutil.rmtree(self.workspace / "removed")
        self.report("app/replacement/pub_deps.json", package="beta", version="2.0.0")

        # Bazel 9.2 checks cached directory listings before their existence.
        # Keep this failure explicit until the 9.3 backport ships:
        # https://github.com/bazelbuild/bazel/issues/30884
        self.show(package="beta", expected_error="is no longer an existing directory")
        subprocess.run(self.startup + ["clean", "--expunge"], cwd=self.workspace,
                       env=self.env, capture_output=True, timeout=60, check=True)
        self.show(package="beta", version="2.0.0")

    def test_declared_reports_replace_the_scan(self):
        self.write("app/BUILD.bazel", "")
        self.report("app/pub_deps.json")
        self.report("other/pub_deps.json", package="beta")
        self.declare("//app:pub_deps.json")
        self.show()
        self.show(package="beta", version=None)

        self.report("app/pub_deps.json", version="2.0.0")
        self.show(version="2.0.0")

        # No directory listing is watched, so the Bazel 9.2 failure above
        # cannot happen when a directory is deleted.
        shutil.rmtree(self.workspace / "other")
        self.show(version="2.0.0")

    def test_declaring_reports_recovers_from_deleted_directory_on_bazel_9_2(self):
        self.write("app/BUILD.bazel", "")
        self.report("app/pub_deps.json")
        self.report("removed/nested/pub_deps.json", package="beta")
        (self.workspace / "later").mkdir()
        self.show(package="beta")
        shutil.rmtree(self.workspace / "removed")
        self.show(expected_error="is no longer an existing directory")

        # The changed usages rerun the extension instead of rechecking the
        # stale directory listings, so no clean --expunge is needed.
        self.declare("//app:pub_deps.json")
        self.show()

        # From then on no listing is watched.
        (self.workspace / "later").rmdir()
        self.show()

    def test_scan_exclusions_and_directory_symlinks(self):
        self.report("app/pub_deps.json")
        for directory in (".git", ".hg", ".svn", ".dart_tool", "bazel-out",
                          "nested/.dart_tool", "nested/bazel-generated"):
            self.report(directory + "/pub_deps.json", version="9.0.0")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "pub_deps.json").write_text("invalid report must not be read")
        (self.workspace / "external-link").symlink_to(outside, target_is_directory=True)
        (self.workspace / "loop").symlink_to(self.workspace, target_is_directory=True)
        self.show()


if __name__ == "__main__":
    unittest.main()
