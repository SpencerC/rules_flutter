#!/usr/bin/env bash
set -euo pipefail
gate="$1"

bash "$gate" success success success success
for result in failure cancelled skipped pending ""; do
    for position in 0 1 2 3; do
        results=(success success success success)
        results[$position]="$result"
        if bash "$gate" "${results[@]}" >/dev/null 2>&1; then
            echo "CI gate accepted '$result' at position $position" >&2
            exit 1
        fi
    done
done
if bash "$gate" >/dev/null 2>&1; then
    echo "CI gate accepted missing results" >&2
    exit 1
fi
