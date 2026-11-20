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
    # The runfiles symlink resolves to the real source file's parent: the
    # e2e/smoke workspace root.
    return Path(__file__).resolve().parent


def nested_env():
    # Inherited TEST_TMPDIR redirects the nested repo cache outside its sandbox;
    # *RUNFILES point at the outer runfiles tree.
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


class CoverageReportContractTest(unittest.TestCase):
    def test_coverage_report_contract(self):
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
            blocks = {}
            for block in reports[0].read_text().split("end_of_record"):
                sf_lines = [line for line in block.splitlines() if line.startswith("SF:")]
                if sf_lines:
                    blocks[sf_lines[0][3:]] = block.splitlines()
            self.assertTrue(blocks, "coverage report has no record blocks")

            for source in blocks:
                self.assertFalse(source.startswith("/"), f"absolute SF path leaked: {source}")
                self.assertTrue(
                    source.startswith(("lib/", "test/")),
                    f"SF path is not package-relative: {source}",
                )
                self.assertTrue(source.endswith(".dart"), f"non-Dart record leaked: {source}")

            fn_blocks = [
                lines for lines in blocks.values() if any(line.startswith("FN:") for line in lines)
            ]
            self.assertTrue(fn_blocks, "no FN records: function coverage passthrough missing")
            self.assertTrue(
                any(line.startswith("FNDA:") for lines in fn_blocks for line in lines),
                "no FNDA records: function coverage passthrough missing",
            )
            main_block = blocks.get("lib/main.dart") or []
            self.assertTrue(main_block, "lib/main.dart missing from the coverage report")
            self.assertTrue(
                any(line.startswith("FN:") and line.endswith(",branchLabel") for line in main_block),
                "branchLabel not covered by FN records: function-coverage passthrough broken",
            )

            # flutter#171580: 3.24.x BRDA values are not faithful; presence only.
            self.assertTrue(
                any(line.startswith("BRDA:") for lines in blocks.values() for line in lines),
                "no BRDA records: branch coverage passthrough missing",
            )


if __name__ == "__main__":
    unittest.main()
