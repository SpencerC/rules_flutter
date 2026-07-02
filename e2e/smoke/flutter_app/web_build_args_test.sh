#!/bin/bash
# Asserts that flutter_app dart_defines and build_args reach the web bundle:
# the SMOKE_DEFINE value must be compiled into main.dart.js and --source-maps
# must emit main.dart.js.map alongside it.
set -euo pipefail

# -L: runfiles materialize tree artifacts as symlinked directories.
MAIN_JS="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*app.web_build_artifacts/main.dart.js" -type f 2>/dev/null | head -n 1)"
if [ -z "$MAIN_JS" ]; then
    echo "✗ main.dart.js not found in app.web build artifacts" >&2
    exit 1
fi

if ! grep -q "smoke-define-e2e-value" "$MAIN_JS"; then
    echo "✗ dart_defines value 'smoke-define-e2e-value' missing from main.dart.js" >&2
    exit 1
fi

if grep -q "smoke-define-unset" "$MAIN_JS"; then
    echo "✗ main.dart.js contains the dart_defines fallback value; --dart-define was not applied" >&2
    exit 1
fi

if [ ! -f "$MAIN_JS.map" ]; then
    echo "✗ main.dart.js.map missing; --source-maps build arg was not applied" >&2
    exit 1
fi

echo "✓ dart_defines and build_args reached the web bundle"
