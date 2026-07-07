<!--
Thanks for contributing to rules_flutter! Please keep PRs focused and include
tests where it makes sense. See CONTRIBUTING.md.
-->

## What & why

<!-- What does this change do, and why is it needed? Link any related issue. -->

## Checklist

- [ ] `bazel test //flutter/tests:all_tests //docs:update_tests` passes
- [ ] `cd e2e/smoke && bazel test //:integration_tests` passes (if behavior changed)
- [ ] Ran `bazel run //docs:update` if any rule/macro API changed
- [ ] `pre-commit run --all-files` (buildifier + prettier) is clean
- [ ] Updated docs/README for user-facing changes
