#!/bin/bash

# URLs of the JSON files
URLS=(
  "https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json"
  "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"
  "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
)

# Temporary files to store the downloaded JSON data
TEMP_FILES=()
for URL in "${URLS[@]}"; do
  TEMP_FILE=$(mktemp)
  curl -s "$URL" -o "$TEMP_FILE"
  TEMP_FILES+=("$TEMP_FILE")
done

# jq command to reorganize and merge the JSON data
RESULT=$(jq -s 'reduce .[] as $item (
  {};
  reduce $item.releases[] as $release (
    .;
    if $release.version != null and $release.archive != null and $release.channel != null then
      .[$release.channel][$release.version] += {($release.archive | if test("macos_arm64") then "macos_arm64" elif test("macos") then "macos" elif test("windows") then "windows" elif test("linux") then "linux" else . end): $release.sha256}
    else
      .
    end
  )
)' "${TEMP_FILES[@]}")

# Clean up temporary files
for TEMP_FILE in "${TEMP_FILES[@]}"; do
  rm "$TEMP_FILE"
done

# Write the result to the versions.bzl file
cat <<EOF > flutter/private/versions.bzl
"""Mirror of release info

TODO: generate this file from GitHub API"""

# To update, run `bazel build update_tool_versions`, then `./bazel-bin/update_tool_versions`
TOOL_VERSIONS = $RESULT
EOF