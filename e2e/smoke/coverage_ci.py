"""Uncached CI driver; repository fetching happens outside native Bazel tests."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from python.runfiles import runfiles

TARGETS = ["//coverage_fixtures/a:lib_test", "//coverage_fixtures/b:lib_test"]


def verify_report(path):
    blocks = {}
    for block in path.read_text().split("end_of_record"):
        lines = block.strip().splitlines()
        sources = [line[3:] for line in lines if line.startswith("SF:")]
        if sources:
            if len(sources) != 1 or sources[0] in blocks:
                raise AssertionError("Duplicate coverage source record")
            blocks[sources[0]] = lines
    expected = {f"coverage_fixtures/{name}/lib/main.dart" for name in ("a", "b")}
    if set(blocks) != expected:
        raise AssertionError(f"Expected distinct workspace source paths {expected}, got {set(blocks)}")
    for name in ("a", "b"):
        lines = blocks[f"coverage_fixtures/{name}/lib/main.dart"]
        hits = dict(line[3:].split(",")[:2] for line in lines if line.startswith("DA:"))
        if int(hits.get("1", "0")) <= 0 or hits.get("2") != "0":
            raise AssertionError(f"Incorrect individual line hits for {name}: {hits}")
        if name == "b" and not any(line.startswith("BRDA:") for line in lines):
            raise AssertionError("Missing opt-in branch coverage")
        for prefix in ("FN:", "FNDA:"):
            if not any(line.startswith(prefix) and line.endswith(",covered" + name.upper()) for line in lines):
                raise AssertionError(f"Missing {prefix} function coverage for {name}")


def cache_results(path):
    results = {}
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if "testResult" in event.get("id", {}):
            label = event["id"]["testResult"]["label"]
            result = event["testResult"]
            if result["status"] != "PASSED":
                raise AssertionError(f"{label} failed: {result['status']}")
            results[label] = result.get("cachedLocally", False)
    if set(results) != set(TARGETS):
        raise AssertionError(f"Missing test results: {results}")
    return results


def main():
    bazel = Path(runfiles.Create().Rlocation(sys.argv[1].removeprefix("../"))).resolve()
    selector = sys.argv[2] if len(sys.argv) > 2 else "pinned"
    repo = Path(os.environ["BUILD_WORKSPACE_DIRECTORY"]).resolve().parents[1]
    module = (repo / "e2e/smoke/MODULE.bazel").read_text()
    pinned = re.search(r'flutter_version = "([^"]+)"', module).group(1)
    versions = re.findall(r'^    "([0-9.]+)":', (repo / "flutter/private/versions.bzl").read_text(), re.M)
    documented = re.search(r'flutter_version = "([^"]+)"', (repo / "README.md").read_text()).group(1)
    latest = max(versions, key=lambda s: tuple(map(int, s.split('.'))))
    version = {"pinned": pinned, "documented": documented, "latest": latest}.get(selector, selector)
    if version not in versions:
        raise ValueError(f"Unsupported fixture SDK version: {version}")
    print(f"Checking Flutter coverage with SDK {version}", flush=True)
    # This is a CLI, not a cached test. Stage tracked and new source files so local
    # changes are included, and mutations never touch the developer's checkout.
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo).decode().split("\0")
    with tempfile.TemporaryDirectory(prefix="rf-coverage-") as temp:
        temp = Path(temp)
        staged = temp / "repo"
        for relative in files:
            source = repo / relative
            if not relative or not source.is_file():
                continue
            destination = staged / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        workspace = staged / "e2e/smoke"
        (workspace / "MODULE.bazel").write_text(module.replace(f'flutter_version = "{pinned}"', f'flutter_version = "{version}"'))
        startup = [str(bazel), "--nosystem_rc", "--nohome_rc", f"--output_base={temp / 'output'}"]
        env = {k: v for k, v in os.environ.items() if not k.startswith(("TEST_", "RUNFILES_", "JAVA_RUNFILES", "PYTHON_RUNFILES", "COVERAGE_"))}

        def coverage(name, expected_cache):
            events = temp / f"{name}.json"
            proc = subprocess.run(startup + ["coverage", "--combined_report=lcov", "--test_output=errors", "--keep_going", f"--build_event_json_file={events}"] + TARGETS, cwd=workspace, env=env)
            reports = list((temp / "output/execroot").glob("*/bazel-out/_coverage/_coverage_report.dat"))
            errors = []
            if proc.returncode:
                errors.append(f"coverage exited {proc.returncode}")
            try:
                if len(reports) != 1:
                    raise AssertionError("Coverage report missing")
                verify_report(reports[0])
            except AssertionError as error:
                errors.append(str(error))
            if errors:
                raise AssertionError("; ".join(errors))
            cached = cache_results(events)
            if cached != expected_cache:
                raise AssertionError(f"{name}: expected cache results {expected_cache}, got {cached}")
            print(f"PASS: {name}", flush=True)

        try:
            coverage("initial", dict.fromkeys(TARGETS, False))
            coverage("unchanged", dict.fromkeys(TARGETS, True))
            source = workspace / "coverage_fixtures/a/lib/main.dart"
            source.write_text(source.read_text() + "\n// Source invalidation probe.\n")
            coverage("source_change", {TARGETS[0]: False, TARGETS[1]: True})
            rules = staged / "flutter/defs.bzl"
            content = rules.read_text()
            marker = '\nCMD=("$FLUTTER_BIN_ABS"'
            if marker not in content:
                raise AssertionError("Runner invalidation probe marker missing")
            rules.write_text(content.replace(marker, '\n# Runner invalidation probe.' + marker))
            coverage("runner_change", dict.fromkeys(TARGETS, False))
        finally:
            subprocess.run(startup + ["shutdown"], cwd=workspace, env=env, timeout=60, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
