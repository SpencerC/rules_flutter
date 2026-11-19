"""End-to-end test: bazel coverage on a flutter_test yields real Dart lcov.

Runs the pinned nested bazel against the e2e/smoke workspace and asserts the
combined coverage report contains Dart source records. This pins the
COVERAGE_OUTPUT_FILE passthrough in flutter_test's runner: without it, bazel
coverage exits 0 but the report is empty ("There was no coverage found").
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from python.runfiles import runfiles  # pyright: ignore[reportMissingImports]


RUNFILES = runfiles.Create()


def runfile(path):
    if path.startswith("../"):
        path = path[3:]
    return Path(RUNFILES.Rlocation(path)).resolve()


BAZEL = runfile(sys.argv.pop(1))


def workspace_root():
    # Resolving through the runfiles symlink lands on the real source file,
    # whose parent is the e2e/smoke workspace root (with its MODULE.bazel).
    return Path(__file__).resolve().parent


def nested_env():
    # Bazel test harness vars leak into the nested build: an inherited
    # TEST_TMPDIR redirects the nested bazel's repository cache outside its
    # sandbox (unwritable), and *RUNFILES point at the outer runfiles tree.
    return {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("TEST_", "GTEST_", "RUNFILES_", "JAVA_RUNFILES_", "PYTHON_RUNFILES_"))
        and k not in ("BAZEL_TEST", "XML_OUTPUT_FILE", "JAVA_RUNFILES", "RUNFILES_DIR")
    }


class FlutterCoverageE2eTest(unittest.TestCase):
    def test_coverage_report_contains_dart_records(self):
        with tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"]) as temp:
            proc = subprocess.run(
                [
                    str(BAZEL),
                    "--output_base=" + str(Path(temp) / "output-base"),
                    "coverage",
                    "--combined_report=lcov",
                    "--test_output=errors",
                    "//flutter_app:lib_test",
                ],
                cwd=workspace_root(),
                env=nested_env(),
                capture_output=True,
                text=True,
                timeout=1800,
            )
            if proc.returncode != 0:
                self.fail(
                    f"nested bazel coverage failed (exit {proc.returncode}):\n"
                    + (proc.stdout + proc.stderr)[-4000:]
                )
            self.assertTrue(
                bool(reports := list((Path(temp) / "output-base").glob("execroot/*/bazel-out/_coverage/_coverage_report.dat"))),
                "bazel coverage produced no report",
            )
            records = [
                line
                for line in reports[0].read_text().splitlines()
                if line.startswith("SF:") and line.rstrip().endswith(".dart")
            ]
            self.assertTrue(records, "no Dart SF records in the coverage report")
            self.assertTrue(
                any("SF:lib/" in line or "SF:test/" in line for line in records),
                "dart SF paths are not package-relative as expected: {}".format(records[:3]),
            )


if __name__ == "__main__":
    unittest.main()
