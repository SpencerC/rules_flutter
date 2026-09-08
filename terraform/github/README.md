# GitHub repository settings

This Terraform root manages `SpencerC/rules_flutter` and adopts its existing
`Main` ruleset (ID `9014601`). It enables:

- Required checks for every test and example matrix job in
  `.github/workflows/ci.yaml`, plus `docs`, `pre-commit`, and `conclusion`.
  Checks must come from GitHub Actions; no actor has a bypass.
- Pull requests with squash merges, linear history, and protection against
  deleting or force-pushing the default branch. The existing zero-review
  approval requirement and non-strict base-update policy are preserved.
- Automatic deletion of PR head branches after merge.

## Apply settings

Run the pinned Terraform CLI through Bazel. Authenticate `gh` with repository
administration permissions, or supply `GITHUB_TOKEN` in the environment.
The wrapper obtains the existing `gh` credential without writing it to files.

```sh
bazel run //terraform/github:terraform -- init
bazel run //terraform/github:terraform -- fmt -check
bazel run //terraform/github:terraform -- validate
bazel run //terraform/github:terraform -- plan -out=/tmp/rules-flutter-settings.tfplan
bazel run //terraform/github:terraform -- apply /tmp/rules-flutter-settings.tfplan
```

Review the plan before applying. Import blocks adopt the existing resources;
`prevent_destroy` protects both resources. A subsequent plan should report no
changes. Commit `.terraform.lock.hcl` to retain the provider checksums.

State and provider data live under `terraform/github/` in the clone's shared
Git directory, obtained with `git rev-parse --path-format=absolute --git-common-dir`.
They persist when an individual Codex worktree is removed and are shared by all
worktrees in this clone. State is local to this clone, not a remote backend:
use this clone to administer the repository, and back up that directory when
moving to a different machine. Do not commit state or saved plans. The checked-in
import blocks also allow a new administrator to adopt the resources again.

When changing the CI matrix, review and apply the updated Terraform plan with
that change. The required check names are derived from the workflow, rather
than a separate version list. The explicit final CI gate rejects failed,
cancelled, skipped, or missing job results.

## Local tracking references

GitHub cannot change developers' local Git configuration. Run
`git config --local fetch.prune true` once per clone (Codex setup does this
automatically). Subsequent fetches remove references to deleted remote
branches. This does not delete local working branches or worktrees.
