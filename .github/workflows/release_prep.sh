#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG=$1
# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_flutter-${TAG:1}"
ARCHIVE="rules_flutter-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix=${PREFIX}/ ${TAG} | gzip > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')
INTEGRITY=$(python3 -c "import base64; print('sha256-' + base64.b64encode(bytes.fromhex('${SHA}')).decode())")

cat << EOF
## Using Bzlmod

rules_flutter requires Bazel 7.1 or newer.

Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "rules_flutter", version = "${TAG:1}")
\`\`\`

Until the release is available in the Bazel Central Registry, reference the
archive directly:

\`\`\`starlark
bazel_dep(name = "rules_flutter", version = "${TAG:1}")
archive_override(
    module_name = "rules_flutter",
    integrity = "${INTEGRITY}",
    strip_prefix = "${PREFIX}",
    urls = ["https://github.com/SpencerC/rules_flutter/releases/download/${TAG}/${ARCHIVE}"],
)
\`\`\`

See the [README](https://github.com/SpencerC/rules_flutter#readme) for
toolchain registration and usage.
EOF
