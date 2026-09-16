#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Expected results for test, example, docs, and pre-commit" >&2
    exit 1
fi
for result in "$@"; do
    if [[ "$result" != success ]]; then
        echo "Required CI job did not succeed: $result" >&2
        exit 1
    fi
done
