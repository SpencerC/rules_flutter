# Template for Bazel rules

Copy this template to create a Bazel ruleset.

Features:

- follows the official style guide at https://bazel.build/rules/deploying
- allows for both WORKSPACE.bazel and bzlmod (MODULE.bazel) usage
- includes Bazel formatting as a pre-commit hook (using [buildifier])
- includes stardoc API documentation generator
- includes typical toolchain setup
- CI configured with GitHub Actions
- release using GitHub Actions just by pushing a tag
- the release artifact doesn't need to be built by Bazel, but can still exclude files and stamp the version

Ready to get started? Copy this repo, then

1. search for "rules_flutter" and replace with the name you'll use for your workspace
1. search for "spencerc" and replace with GitHub org
1. search for "flutter", "Flutter", "FLUTTER" and replace with the language/tool your rules are for
1. rename directory "flutter" similarly
1. run `pre-commit install` to get lints (see CONTRIBUTING.md)
1. if you don't need to fetch platform-dependent tools, then remove anything toolchain-related.
1. (optional) install the [Renovate app](https://github.com/apps/renovate) to get auto-PRs to keep the dependencies up-to-date.
1. delete this section of the README (everything up to the SNIP).

Optional: if you write tools for your rules to call, you should avoid toolchain dependencies for those tools leaking to all users.
For example, https://github.com/aspect-build/rules_py actions rely on a couple of binaries written in Rust, but we don't want users to be forced to
fetch a working Rust toolchain. Instead we want to ship pre-built binaries on our GH releases, and the ruleset fetches these as toolchains.
See https://blog.aspect.build/releasing-bazel-rulesets-rust for information on how to do this.
Note that users who _do_ want to build tools from source should still be able to do so, they just need to register a different toolchain earlier.

---- SNIP ----

# Bazel rules for flutter

## Installation

From the release you wish to use:
<https://github.com/spencerc/rules_flutter/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.

To use a commit rather than a release, you can point at any SHA of the repo.

For example to use commit `abc123`:

1. Replace `url = "https://github.com/spencerc/rules_flutter/releases/download/v0.1.0/rules_flutter-v0.1.0.tar.gz"` with a GitHub-provided source archive like `url = "https://github.com/spencerc/rules_flutter/archive/abc123.tar.gz"`
1. Replace `strip_prefix = "rules_flutter-0.1.0"` with `strip_prefix = "rules_flutter-abc123"`
1. Update the `sha256`. The easiest way to do this is to comment out the line, then Bazel will
   print a message with the correct value. Note that GitHub source archives don't have a strong
   guarantee on the sha256 stability, see
   <https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes/>
