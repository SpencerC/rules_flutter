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

# Try to locate binaries using platform-specific canonical repository names.
# The bzlmod canonical name follows the pattern: rules_flutter++flutter+flutter_<platform>
# Where platform is: macos, linux, windows

DART_BIN=""
FLUTTER_BIN=""

# Try macOS first
if [[ -z "$DART_BIN" ]]; then
    DART_BIN=$(rlocation "rules_flutter++flutter+flutter_macos/flutter/bin/dart" 2>/dev/null || true)
    FLUTTER_BIN=$(rlocation "rules_flutter++flutter+flutter_macos/flutter/bin/flutter" 2>/dev/null || true)
fi

# Try Linux
if [[ -z "$DART_BIN" ]]; then
    DART_BIN=$(rlocation "rules_flutter++flutter+flutter_linux/flutter/bin/dart" 2>/dev/null || true)
    FLUTTER_BIN=$(rlocation "rules_flutter++flutter+flutter_linux/flutter/bin/flutter" 2>/dev/null || true)
fi

# Try Windows
if [[ -z "$DART_BIN" ]]; then
    DART_BIN=$(rlocation "rules_flutter++flutter+flutter_windows/flutter/bin/dart.exe" 2>/dev/null || true)
    FLUTTER_BIN=$(rlocation "rules_flutter++flutter+flutter_windows/flutter/bin/flutter.bat" 2>/dev/null || true)
fi

if [[ -z "$DART_BIN" ]]; then
    echo "ERROR: Failed to locate dart binary on any platform"
    echo "Tried: rules_flutter++flutter+flutter_{macos,linux,windows}"
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
