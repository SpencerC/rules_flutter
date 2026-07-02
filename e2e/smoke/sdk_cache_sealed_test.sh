#!/bin/bash
# Asserts the hermeticity guarantee: the Flutter SDK's bin/cache is sealed
# read-only at fetch time, so no build action or run helper can mutate the
# external repository.
set -euo pipefail

FLUTTER_BIN="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*flutter_sdk/bin/flutter" 2>/dev/null | head -n 1)"
if [ -z "$FLUTTER_BIN" ]; then
    echo "✗ flutter binary not found in runfiles" >&2
    exit 1
fi

PYTHON_BIN="$(command -v python3 || command -v python)"
REAL_BIN="$("$PYTHON_BIN" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$FLUTTER_BIN")"
CACHE_DIR="$(dirname "$REAL_BIN")/cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "✗ SDK cache directory not found at $CACHE_DIR" >&2
    exit 1
fi

if touch "$CACHE_DIR/.rules_flutter_mutation_probe" 2>/dev/null; then
    rm -f "$CACHE_DIR/.rules_flutter_mutation_probe"
    echo "✗ SDK bin/cache is writable; expected it to be sealed read-only at fetch time" >&2
    exit 1
fi

if [ -w "$CACHE_DIR/lockfile" ]; then
    echo "✗ SDK bin/cache/lockfile is writable; expected read-only" >&2
    exit 1
fi

echo "✓ SDK bin/cache is sealed read-only"
