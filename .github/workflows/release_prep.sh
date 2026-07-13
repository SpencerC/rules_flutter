#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG=$1
VERSION="${TAG:1}"
# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_flutter-${VERSION}"
ARCHIVE="rules_flutter-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix=${PREFIX}/ ${TAG} > "${ARCHIVE%.gz}"

# Stamp the release version into both modules' MODULE.bazel (main carries
# 0.0.0 between releases) so the shipped archive is self-consistent for
# archive_override consumers and matches the BCR entry.
STAMP_DIR=$(mktemp -d)
tar -xf "${ARCHIVE%.gz}" -C "$STAMP_DIR"
for module in "$STAMP_DIR/$PREFIX/MODULE.bazel" "$STAMP_DIR/$PREFIX/gazelle/MODULE.bazel"; do
    if ! grep -q 'version = "0.0.0"' "$module"; then
        echo "ERROR: expected version 0.0.0 placeholder in $module" >&2
        exit 1
    fi
    sed -i.bak "s/version = \"0.0.0\"/version = \"${VERSION}\"/" "$module"
    rm "$module.bak"
done
# GNU tar (CI) gets deterministic output so re-runs produce identical bytes.
if tar --version 2>/dev/null | grep -q GNU; then
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="UTC 2000-01-01" \
        -cf "${ARCHIVE%.gz}" -C "$STAMP_DIR" "$PREFIX"
else
    tar -cf "${ARCHIVE%.gz}" -C "$STAMP_DIR" "$PREFIX"
fi
rm -rf "$STAMP_DIR"

gzip -n "${ARCHIVE%.gz}"
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')
INTEGRITY=$(python3 -c "import base64; print('sha256-' + base64.b64encode(bytes.fromhex('${SHA}')).decode())")

cat << EOF
## Using Bzlmod

rules_flutter requires Bazel 8 or newer.

Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "rules_flutter", version = "${VERSION}")
\`\`\`

Until the release is available in the Bazel Central Registry, reference the
archive directly:

\`\`\`starlark
bazel_dep(name = "rules_flutter", version = "${VERSION}")
archive_override(
    module_name = "rules_flutter",
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}",
    urls = ["https://github.com/SpencerC/rules_flutter/releases/download/${TAG}/${ARCHIVE}"],
)
\`\`\`

The Gazelle plugin ships as a second module from the same archive:

\`\`\`starlark
bazel_dep(name = "rules_flutter_gazelle", version = "${VERSION}", dev_dependency = True)
archive_override(
    module_name = "rules_flutter_gazelle",
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}/gazelle",
    urls = ["https://github.com/SpencerC/rules_flutter/releases/download/${TAG}/${ARCHIVE}"],
)
\`\`\`

See the [README](https://github.com/SpencerC/rules_flutter#readme) for
toolchain registration and usage.
EOF
