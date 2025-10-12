import difflib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from bazel_tools.tools.python.runfiles import runfiles


def load_runfile(path: str, workspace: str = None) -> Path:
    r = runfiles.Create()
    candidates = [path]
    if workspace:
        candidates.append(os.path.join(workspace, path))
    candidates.append(os.path.join("__main__", path))

    for candidate in candidates:
        resolved = r.Rlocation(candidate)
        if resolved:
            candidate_path = Path(resolved)
            if candidate_path.exists():
                return candidate_path

    runfiles_dir = os.environ.get("RUNFILES_DIR")
    if runfiles_dir:
        pattern = f"**/{path}"
        matches = list(Path(runfiles_dir).glob(pattern))
        if matches:
            return matches[0]

    raise FileNotFoundError(f"Runfile {path} not found in runfiles search")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gazelle_generation_test.py <gazelle_bin>", file=sys.stderr)
        return 1

    workspace = os.environ.get("TEST_WORKSPACE", "__main__")

    gazelle_bin = load_runfile(sys.argv[1], workspace)

    tmp_root = Path(tempfile.mkdtemp(prefix="gazelle_fixture_"))
    try:
        project_dir = tmp_root / "gazelle_app"

        fixture_files = [
            "BUILD.bazel.golden",
            "MODULE.bazel",
            "lib/main.dart",
            "pub_deps.json",
            "pubspec.yaml",
        ]
        for rel in fixture_files:
            src = load_runfile(f"gazelle_app/{rel}", workspace)
            dest = project_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)

        try:
            subprocess.run(
                [
                    str(gazelle_bin),
                    f"-repo_root={project_dir}",
                    "-build_file_name=BUILD.bazel",
                    "-mode=fix",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=project_dir,
            )
        except subprocess.CalledProcessError as err:
            sys.stderr.write(err.stdout or "")
            sys.stderr.write(err.stderr or "")
            raise

        generated = (project_dir / "BUILD.bazel").read_text()
        golden = (project_dir / "BUILD.bazel.golden").read_text()

        if generated != golden:
            diff = "".join(
                difflib.unified_diff(
                    golden.splitlines(keepends=True),
                    generated.splitlines(keepends=True),
                    fromfile="BUILD.bazel.golden",
                    tofile="BUILD.bazel",
                )
            )
            sys.stderr.write("Gazelle output did not match golden BUILD file:\n")
            sys.stderr.write(diff)
            return 1
    finally:
        shutil.rmtree(tmp_root)

    return 0


if __name__ == "__main__":
    sys.exit(main())
