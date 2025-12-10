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

# The platform-agnostic targets @flutter_sdk//:dart_binary and @flutter_sdk//:flutter_binary
# resolve to the correct platform-specific binary via select() in the sdk_repo.bzl.
# We can find them using the rlocation helper with the canonical repo path.

DART_BIN=""
FLUTTER_BIN=""

# Try to find the binaries via the platform-specific canonical names.
# The @flutter_sdk aliases resolve via select() but runfiles look up the actual file path.
# We try each platform in order since only one will exist.

for platform in macos linux windows; do
    if [[ "$platform" == "windows" ]]; then
        dart_path="rules_flutter++flutter+flutter_${platform}/flutter/bin/dart.exe"
        flutter_path="rules_flutter++flutter+flutter_${platform}/flutter/bin/flutter.bat"
    else
        dart_path="rules_flutter++flutter+flutter_${platform}/flutter/bin/dart"
        flutter_path="rules_flutter++flutter+flutter_${platform}/flutter/bin/flutter"
    fi

    DART_BIN=$(rlocation "$dart_path" 2>/dev/null || true)
    if [[ -n "$DART_BIN" && -f "$DART_BIN" ]]; then
        FLUTTER_BIN=$(rlocation "$flutter_path" 2>/dev/null || true)
        echo "Detected platform: $platform"
        break
    fi
    DART_BIN=""
done

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
