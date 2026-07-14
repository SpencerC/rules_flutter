#!/bin/bash
# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
	source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
	source "$0.runfiles/$f" 2>/dev/null ||
	source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
	source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
	{
		echo >&2 "ERROR: cannot find $f"
		exit 1
	}
f=
set -e
# --- end runfiles.bash initialization v3 ---

echo "Looking for dart and flutter binaries..."

# Direct SDK invocations follow the same contract as the rules' actions
# (docs/hermeticity.md): the launcher must not take the sealed cache's
# lockfile, refresh versions, or write analytics into a read-only HOME.
export FLUTTER_ALREADY_LOCKED=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export HOME="${TEST_TMPDIR:-$(mktemp -d)}"

# The @flutter_sdk repository provides platform-agnostic symlinks at stable
# paths. The runfiles paths are passed as arguments via $(rlocationpath ...)
# expansion, so the script never hardcodes a canonical repository name (which
# differs depending on which module instantiated the flutter extension).

DART_BIN=$(rlocation "$1")
FLUTTER_BIN=$(rlocation "$2")

if [[ -z "$DART_BIN" || ! -f "$DART_BIN" ]]; then
    echo "ERROR: Failed to locate dart binary"
    echo "Expected runfiles path: $1"
    exit 1
fi

echo "Found dart at: $DART_BIN"
"$DART_BIN" --version

if [[ -z "$FLUTTER_BIN" ]]; then
    echo "ERROR: Failed to locate flutter binary"
    exit 1
fi

echo "Found flutter at: $FLUTTER_BIN"
"$FLUTTER_BIN" --no-version-check --version

echo "Success! Both dart and flutter binaries are accessible."
