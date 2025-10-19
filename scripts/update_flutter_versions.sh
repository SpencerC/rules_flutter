#!/bin/bash
set -euo pipefail

# Update Flutter SDK versions and integrity hashes for rules_flutter
# This script fetches the latest Flutter release information from Google Cloud Storage
# and generates the versions.bzl file with real SHA-384 integrity hashes.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Flutter release API URLs
URLS=(
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json"
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
)

# Platform mapping from Flutter's naming to our internal naming
# Note: Using simple approach since associative arrays may not be available in all shells

# Minimum Flutter version that we include when auto-detecting releases.
# Versions below this threshold are ignored unless explicitly provided as arguments.
MIN_SUPPORTED_VERSION="3.24.4"

# Versions that must always be present in the generated metadata regardless of
# the detected releases. Keep older toolchains working while auto-expanding to
# newer stable releases.
ALWAYS_INCLUDED_VERSIONS=("3.24.0")

# User can optionally supply explicit versions as script arguments.
SUPPORTED_VERSIONS=("$@")

info "Fetching Flutter release information..."

# Temporary files to store the downloaded JSON data
TEMP_FILES=()
cleanup() {
    for TEMP_FILE in "${TEMP_FILES[@]}"; do
        if [[ -f "$TEMP_FILE" ]]; then
            rm "$TEMP_FILE"
        fi
    done
}
trap cleanup EXIT

# Download release data for each platform
for URL in "${URLS[@]}"; do
    info "Downloading $(basename "$URL")..."
    TEMP_FILE=$(mktemp)
    if ! curl -sf "$URL" -o "$TEMP_FILE"; then
        error "Failed to download $URL"
        exit 1
    fi
    TEMP_FILES+=("$TEMP_FILE")
done

info "Processing release data..."

# Determine which versions to process.
if [[ ${#SUPPORTED_VERSIONS[@]} -eq 0 ]]; then
    info "Auto-detecting stable Flutter versions >= ${MIN_SUPPORTED_VERSION}..."
    PYTHON_OUTPUT=$(python3 - "$MIN_SUPPORTED_VERSION" "${TEMP_FILES[@]}" <<'PY'
import json
import sys

def parse_version(raw: str):
    parts = []
    for segment in raw.split("."):
        # Stop split on pre-release or build metadata.
        if "-" in segment:
            segment = segment.split("-", 1)[0]
        if segment.isdigit():
            parts.append(int(segment))
        else:
            return None
    return tuple(parts)

def main(argv) -> None:
    if len(argv) < 2:
        sys.exit("minimum version and at least one JSON path are required")

    min_version_raw = argv[0]
    min_version = parse_version(min_version_raw)
    if not min_version:
        sys.exit(f"invalid minimum version: {min_version_raw}")

    versions = set()
    for path in argv[1:]:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        for release in data.get("releases", []):
            if release.get("channel") != "stable":
                continue
            version_raw = release.get("version")
            if not isinstance(version_raw, str):
                continue
            parsed = parse_version(version_raw)
            if not parsed:
                continue
            if parsed >= min_version:
                versions.add((parsed, version_raw))

    for _, version_raw in sorted(versions):
        print(version_raw)

if __name__ == "__main__":
    main(sys.argv[1:])
PY
    )
    if [[ $? -ne 0 ]]; then
        error "Failed to determine supported versions from release metadata"
        exit 1
    fi
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            SUPPORTED_VERSIONS+=("$version")
        fi
    done <<< "$PYTHON_OUTPUT"
fi

# Always include pinned versions and normalize the final list (sorted, deduplicated).
CANDIDATE_VERSIONS=("${ALWAYS_INCLUDED_VERSIONS[@]}")
CANDIDATE_VERSIONS+=("${SUPPORTED_VERSIONS[@]}")

SORTED_VERSIONS_OUTPUT=$(python3 - "${CANDIDATE_VERSIONS[@]}" <<'PY'
import sys

def parse_version(raw: str):
    parts = []
    for segment in raw.split("."):
        if "-" in segment:
            segment = segment.split("-", 1)[0]
        if segment.isdigit():
            parts.append(int(segment))
        else:
            return None
    return tuple(parts)

def main(argv):
    versions = set()
    for version_raw in argv:
        parsed = parse_version(version_raw)
        if not parsed:
            continue
        versions.add((parsed, version_raw))
    for _, version_raw in sorted(versions):
        print(version_raw)

if __name__ == "__main__":
    main(sys.argv[1:])
PY
)
if [[ $? -ne 0 ]]; then
    error "Failed to normalize Flutter version list"
    exit 1
fi

SUPPORTED_VERSIONS=()
while IFS= read -r version; do
    if [[ -n "$version" ]]; then
        SUPPORTED_VERSIONS+=("$version")
    fi
done <<< "$SORTED_VERSIONS_OUTPUT"

if [[ ${#SUPPORTED_VERSIONS[@]} -eq 0 ]]; then
    error "No supported versions were found. Provide explicit versions as arguments."
    exit 1
fi

# Function to convert SHA-256 to SHA-384 SRI format
# Note: Flutter provides SHA-256, but Bazel expects SHA-384 for integrity checking
# We'll use the SHA-256 values but convert them to proper SRI format
sha256_to_sri() {
    local sha256_hex="$1"
    if [[ -n "$sha256_hex" ]]; then
        # Convert hex to base64 and format as SHA-256 SRI
        echo "sha256-$(echo "$sha256_hex" | xxd -r -p | base64 -w0)"
    else
        echo ""
    fi
}

# Generate the versions.bzl file header
cat > flutter/private/versions.bzl << 'EOF'
"""Mirror of Flutter SDK release info

This file is automatically generated by scripts/update_flutter_versions.sh
To update: bazel run //tools:update_flutter_versions

Flutter SDK releases are available at:
https://storage.googleapis.com/flutter_infra_release/releases/stable/{platform}/
"""

# The integrity hashes are computed from Flutter's official SHA-256 checksums
# and converted to SRI format for Bazel integrity checking
TOOL_VERSIONS = {
EOF

# Process JSON data and extract version information
for version in "${SUPPORTED_VERSIONS[@]}"; do
    info "Processing Flutter $version..."
    echo "    \"$version\": {" >> flutter/private/versions.bzl
    
    # Extract hashes for this version from each platform
    for i in "${!URLS[@]}"; do
        platform_file="${TEMP_FILES[$i]}"
        platform_name=""
        archive_path=""
        
        # Determine platform name from URL
        case "${URLS[$i]}" in
            *macos*)
                platform_name="macos"
                archive_path="stable/macos/flutter_macos_${version}-stable.zip"
                ;;
            *linux*)
                platform_name="linux"
                archive_path="stable/linux/flutter_linux_${version}-stable.tar.xz"
                ;;
            *windows*)
                platform_name="windows"
                archive_path="stable/windows/flutter_windows_${version}-stable.zip"
                ;;
        esac
        
        # Extract SHA-256 hash for this version and platform (stable channel only)
        sha256_hash=$(jq -r ".releases[] | select(.version == \"$version\" and .channel == \"stable\" and (\"${archive_path}\" == \"\" or .archive == \"${archive_path}\")) | .sha256" "$platform_file" 2>/dev/null | head -1)
        
        if [[ "$sha256_hash" != "null" && -n "$sha256_hash" ]]; then
            sri_hash=$(sha256_to_sri "$sha256_hash")
            echo "        \"$platform_name\": \"$sri_hash\"," >> flutter/private/versions.bzl
            info "  Found $platform_name: ${sha256_hash:0:16}..."
        else
            warn "  No hash found for $platform_name"
            # Use a placeholder for missing hashes
            echo "        \"$platform_name\": \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"," >> flutter/private/versions.bzl
        fi
    done
    
    echo "    }," >> flutter/private/versions.bzl
done

# Close the TOOL_VERSIONS dictionary
echo "}" >> flutter/private/versions.bzl

info "Successfully updated flutter/private/versions.bzl"
info "Supported versions: ${SUPPORTED_VERSIONS[*]}"

# Validate the generated file
if ! python3 -c "
import ast
with open('flutter/private/versions.bzl', 'r') as f:
    content = f.read()
    # Extract just the TOOL_VERSIONS dictionary
    start = content.find('TOOL_VERSIONS = {')
    end = content.rfind('}') + 1
    dict_content = content[start+len('TOOL_VERSIONS = '):]
    try:
        ast.literal_eval(dict_content)
        print('✓ Generated versions.bzl is valid Python/Starlark syntax')
    except SyntaxError as e:
        print(f'✗ Syntax error in generated file: {e}')
        exit(1)
"; then
    error "Generated file has syntax errors"
    exit 1
fi

info "Done! You can now re-enable integrity checking in flutter/repositories.bzl"
