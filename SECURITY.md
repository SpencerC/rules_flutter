# Security Policy

## Supported versions

`rules_flutter` is pre-1.0 and evolving quickly. Security fixes are applied to
`main` and released in the next version; there is no long-term support branch
yet. Always test against the latest release.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

- Preferred: use GitHub's private vulnerability reporting —
  [open a draft advisory](https://github.com/SpencerC/rules_flutter/security/advisories/new).
- Alternatively, email **spencer@ggx.trade** with the details.

Include enough to reproduce: the affected version/commit, a minimal
`MODULE.bazel`/`BUILD.bazel`, and the observed vs. expected behavior. You will
get an acknowledgment within a few business days and an estimated timeline for
a fix. Please give a reasonable window to address the issue before any public
disclosure.

## Scope

This ruleset downloads the Flutter SDK and pub.dev packages with integrity
verification and runs the vendored toolchain hermetically (see
[docs/hermeticity.md](docs/hermeticity.md)). Reports of particular interest:

- Integrity/verification gaps in SDK or package fetching.
- Ways a build action or run helper can escape the sandbox or write into the
  sealed SDK repository.
- Supply-chain concerns in the module extensions or generated repositories.
