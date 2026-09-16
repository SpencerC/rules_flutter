#!/usr/bin/env bash
set -euo pipefail

# Bazel runs from the runfiles workspace; resolve the declared tool before cd.
terraform_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
cd "${BUILD_WORKSPACE_DIRECTORY:?Run this tool with bazel run}/terraform/github"

# Keep state across Codex worktree removal, shared by this clone's worktrees.
state_dir="$(git rev-parse --path-format=absolute --git-common-dir)/terraform/github"
mkdir -p "$state_dir"
export TF_DATA_DIR="$state_dir/data"

if [[ "${1:-}" == "init" ]]; then
    shift
    exec "$terraform_bin" init "-backend-config=path=$state_dir/terraform.tfstate" "$@"
fi

# Provider credentials remain in the process environment, never in source/state.
case "${1:-}" in
    plan|apply|import|refresh)
        if [[ -z "${GITHUB_TOKEN:-}" ]]; then
            export GITHUB_TOKEN
            GITHUB_TOKEN="$(gh auth token --hostname github.com)"
        fi
        ;;
esac
exec "$terraform_bin" "$@"
