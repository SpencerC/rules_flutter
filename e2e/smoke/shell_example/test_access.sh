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

# The @flutter_sdk repository provides platform-agnostic symlinks at stable paths.
# These symlinks point to the actual platform-specific binaries, allowing scripts
# to use a simple rlocation call without platform-specific logic.

DART_BIN=$(rlocation "rules_flutter++flutter+flutter_sdk/bin/dart")
FLUTTER_BIN=$(rlocation "rules_flutter++flutter+flutter_sdk/bin/flutter")

if [[ -z "$DART_BIN" || ! -f "$DART_BIN" ]]; then
    echo "ERROR: Failed to locate dart binary"
    echo "Expected path: rules_flutter++flutter+flutter_sdk/bin/dart"
    exit 1
fi

echo "Found dart at: $DART_BIN"
"$DART_BIN" --version

if [[ -z "$FLUTTER_BIN" ]]; then
    echo "ERROR: Failed to locate flutter binary"
    exit 1
fi

echo "Found flutter at: $FLUTTER_BIN"
"$FLUTTER_BIN" --version

echo "Success! Both dart and flutter binaries are accessible."
