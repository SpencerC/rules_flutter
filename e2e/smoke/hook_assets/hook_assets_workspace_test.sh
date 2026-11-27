#!/bin/bash
# Asserts that flutter_library.hook_assets mounts the files into the prepared
# workspace and points the package's hook at them through the workspace
# pubspec.yaml's hooks.user_defines.
set -euo pipefail

# -L: runfiles materialize tree artifacts as symlinked directories.
PUBSPEC="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*hook_assets/lib_prepared_flutter_workspace/pubspec.yaml" -type f 2>/dev/null | head -n 1)"
if [ -z "$PUBSPEC" ]; then
    echo "✗ prepared workspace pubspec.yaml not found" >&2
    exit 1
fi
WORKSPACE="$(dirname "$PUBSPEC")"

MOUNTED="$WORKSPACE/.rules_flutter/hook_assets/fixture/libfixture.x64.linux.so"
if [ "$(cat "$MOUNTED" 2>/dev/null)" != "fixture library bytes" ]; then
    echo "✗ $MOUNTED is missing or has the wrong content" >&2
    exit 1
fi

EXPECTED='hooks:
  user_defines:
    "fixture":
      "directory": ".rules_flutter/hook_assets/fixture/"
      "source": "local"'
ACTUAL="$(sed -n '/^hooks:/,$p' "$PUBSPEC")"
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "✗ unexpected hooks section in the workspace pubspec.yaml:" >&2
    echo "$ACTUAL" >&2
    exit 1
fi

# The source package's own sections survive the append.
grep -q '^name: hook_assets_app$' "$PUBSPEC"

echo "✓ hook assets mounted and user_defines written"
