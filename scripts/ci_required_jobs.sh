#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Expected results for test, example, docs, pre-commit, and coverage" >&2
    exit 1
fi
for result in "$@"; do
    if [[ "$result" != success ]]; then
        echo "Required CI job did not succeed: $result" >&2
        exit 1
    fi
done
