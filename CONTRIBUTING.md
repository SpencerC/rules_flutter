# How to Contribute

## Using devcontainers

If you are using [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)
and/or [codespaces](https://github.com/features/codespaces) then you can start
contributing immediately and skip the next step.

## Formatting

Starlark files should be formatted by buildifier.
We suggest using a pre-commit hook to automate this.
First [install pre-commit](https://pre-commit.com/#installation),
then run

```shell
pre-commit install
```

Otherwise later tooling on CI will yell at you about formatting/linting violations.

## Repository settings and branch cleanup

GitHub settings are managed in [terraform/github](terraform/github/README.md).
The default branch requires all CI test/example matrix jobs, docs, pre-commit,
and the final conclusion. GitHub deletes PR head branches after merge.

Enable automatic pruning in each clone so fetches also remove deleted
remote-tracking references such as `origin/feature/example`:

```sh
git config --local fetch.prune true
git fetch origin
```

Codex's environment setup enables this setting automatically. It is shared by
worktrees in the same clone. Local working branches and worktrees are retained.

## Updating BUILD files

Some targets are generated from sources.
Currently this is just the `bzl_library` targets.
Run `bazel run //:gazelle` to keep them up-to-date.

Development uses the pinned Bazel 9.2.0. Before completing a change, run:

```sh
bazel test //flutter/tests:all_tests //docs:update_tests
cd e2e/smoke && bazel test //:integration_tests
```

CI also builds and tests the root, `gazelle/`, `e2e/smoke/`, and the standalone
example with Bazel 9.0.0, the minimum supported version. Use
`USE_BAZEL_VERSION=9.0.0 bazel test ...` to reproduce that coverage locally.
The manual `//docs:update_tests` gate runs only at the pinned version because
Stardoc output varies between Bazel versions; regenerate it with
`bazel run //docs:update` when needed.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another Bazel module, such as
some other ruleset that depends on rules_flutter, or in the nested
`e2e/smoke` module used for integration tests.

To always tell Bazel to use this directory rather than some release
artifact or a version fetched from the internet, run this from this
directory:

```sh
OVERRIDE="--override_repository=rules_flutter=$(pwd)/rules_flutter"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_flutter` on your system will point to this folder.

## Releasing

Releases are automated on a cron trigger.
The new version is determined automatically from the commit history, assuming the commit messages follow conventions, using
https://github.com/marketplace/actions/conventional-commits-versioner-action.
If you do nothing, eventually the newest commits will be released automatically as a patch or minor release.
This automation is defined in .github/workflows/tag.yaml.

Rather than wait for the cron event, you can trigger manually. Navigate to
https://github.com/SpencerC/rules_flutter/actions/workflows/tag.yaml
and press the "Run workflow" button.

If you need control over the next release version, for example when making a release candidate for a new major,
then: tag the repo and push the tag, for example

```sh
% git fetch
% git tag v1.0.0-rc0 origin/main
% git push origin v1.0.0-rc0
```

Then watch the automation run on GitHub actions which creates the release.
