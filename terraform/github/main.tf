# Adopt the existing repository and ruleset; never recreate either one.
import {
  to = github_repository.rules_flutter
  id = "rules_flutter"
}

import {
  to = github_repository_ruleset.main
  id = "rules_flutter:9014601"
}

resource "github_repository" "rules_flutter" {
  name                   = "rules_flutter"
  visibility             = "public"
  has_issues             = true
  has_projects           = true
  has_wiki               = true
  allow_merge_commit     = true
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_auto_merge       = false
  allow_update_branch    = false
  delete_branch_on_merge = true

  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"

  lifecycle {
    prevent_destroy = true
    # Security features remain under their existing GitHub configuration.
    ignore_changes = [security_and_analysis, template]
  }
}

locals {
  # Read the workflow itself so a matrix version/runner change cannot leave
  # Terraform requiring checks that CI no longer produces.
  ci             = yamldecode(file("${path.module}/../../.github/workflows/ci.yaml"))
  test_matrix    = local.ci.jobs.test.strategy.matrix
  example_matrix = local.ci.jobs.example.strategy.matrix
  required_checks = toset(concat(
    [for axes in setproduct(local.test_matrix.os, local.test_matrix.bazel, local.test_matrix.folder) :
      format("test (%s, %s, %s)", axes[0], axes[1], axes[2])
    ],
    [for axes in setproduct(local.example_matrix.os, local.example_matrix.bazel) :
      format("example (%s, %s)", axes[0], axes[1])
    ],
    ["docs", "pre-commit", "conclusion"],
  ))
}

resource "github_repository_ruleset" "main" {
  name        = "Main"
  repository  = github_repository.rules_flutter.name
  target      = "branch"
  enforcement = "active"

  # No bypass actors: administrators must pass the same checks.
  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false
      dynamic "required_check" {
        for_each = local.required_checks
        content {
          context        = required_check.value
          integration_id = 15368 # GitHub Actions, verified from the CI check runs.
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "required_checks" {
  value = sort(tolist(local.required_checks))
}
