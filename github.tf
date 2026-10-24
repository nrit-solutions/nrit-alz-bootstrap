# Customer repository and CI/CD wiring.
#
# Generates the infrastructure-live repository from the customer template, sets
# the Azure and backend Action variables the pipelines consume, and configures
# the plan and apply environments. The environments are limited to the default
# branch but carry no reviewer rules; the pull-request ruleset gates the merge
# and the engine gates tfpr apply on the same review decision.

resource "github_repository" "live" {
  name        = var.customer_repository_name
  description = "Infrastructure-live for ${var.customer_name}. Generated from ${var.template_repository.owner}/${var.template_repository.repository}."
  visibility  = "private"
  auto_init   = false

  # The scheduled drift workflow reports to GitHub Issues. Repositories generated
  # from a template inherit the template's "has issues" setting, which can be off,
  # so enable it explicitly: without it the drift run fails when it tries to open
  # an issue ("Issues has been disabled in this repository").
  has_issues = true

  # Merged head branches are deleted automatically. The unlock workflow rides
  # the closed event, which the merge itself fires before the deletion; only
  # closing and deleting in one command races it.
  delete_branch_on_merge = true

  # Secret scanning and push protection on the customer repository. Private
  # repositories need GitHub Secret Protection on the organization plan
  # (Team or above); a Free organization sets secret_scanning = false.
  dynamic "security_and_analysis" {
    for_each = var.secret_scanning ? [1] : []
    content {
      secret_scanning {
        status = "enabled"
      }
      secret_scanning_push_protection {
        status = "enabled"
      }
    }
  }

  template {
    owner                = var.template_repository.owner
    repository           = var.template_repository.repository
    include_all_branches = false
  }

  lifecycle {
    # The template is only used at creation; ignore drift afterwards.
    ignore_changes = [template]
  }
}

# Customize the OIDC subject so the token carries repository and environment.
# The federated credentials in identity.tf match on these two. The pipeline tag
# and workflow file are deliberately NOT in the subject: the deploy identities
# trust the customer repository plus the GitHub environment (apply is gated by
# the engine's review-decision check), so bumping the reusable-pipeline tag needs no
# re-bootstrap. Entra's flexible-FIC wildcard cannot hold the full
# repo+environment+workflow_ref+tag subject (it exceeds the 128-character claim
# limit), so the workflow-file pin is dropped rather than wildcarded.
resource "github_actions_repository_oidc_subject_claim_customization_template" "live" {
  repository         = github_repository.live.name
  use_default        = false
  include_claim_keys = ["repository", "environment"]
}

# Approver team for the apply environment.
resource "github_team" "approvers" {
  count       = length(var.apply_approvers) > 0 ? 1 : 0
  name        = "${var.customer_name}-alz-apply-approvers"
  description = "Approvers for the apply environment in ${var.customer_repository_name}."
  privacy     = "closed"
}

resource "github_team_membership" "approvers" {
  for_each = length(var.apply_approvers) > 0 ? toset(var.apply_approvers) : toset([])
  team_id  = github_team.approvers[0].id
  username = each.value
  role     = "member"

  # GitHub reports org owners as maintainer regardless of the requested role.
  lifecycle {
    ignore_changes = [role]
  }
}

resource "github_team_repository" "approvers" {
  count      = length(var.apply_approvers) > 0 ? 1 : 0
  team_id    = github_team.approvers[0].id
  repository = github_repository.live.name
  permission = "push"
}

# The plan and apply environments exist so the OIDC subject (environment:plan,
# environment:apply) matches the federated credential. They carry no reviewer
# rules: GitHub only allows environment required-reviewers on private repositories
# at higher plan tiers, whereas repository rulesets work on Team. So approval is
# enforced in two portable places instead. The engine gates tfpr apply on the pull
# request's review decision, and the ruleset below gates the merge.
#
# Both are limited to the default branch. The subject names only repository and
# environment, so without the limit any writer's branch workflow that binds an
# environment gets that identity's Azure token, and its secrets. Every
# engine job that binds one runs from the default branch.
resource "github_repository_environment" "env" {
  for_each    = local.environments
  repository  = github_repository.live.name
  environment = each.value

  dynamic "deployment_branch_policy" {
    for_each = var.limit_environments_to_default_branch ? [1] : []
    content {
      protected_branches     = false
      custom_branch_policies = true
    }
  }
}

resource "github_repository_environment_deployment_policy" "default_branch" {
  for_each       = var.limit_environments_to_default_branch ? local.environments : {}
  repository     = github_repository.live.name
  environment    = github_repository_environment.env[each.key].environment
  branch_pattern = var.default_branch
}

# Only GitHub-owned actions and the allowed_actions patterns may run; any other action fails the workflow load.
resource "github_actions_repository_permissions" "live" {
  repository      = github_repository.live.name
  enabled         = true
  allowed_actions = "selected"

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = false
    patterns_allowed     = var.allowed_actions
  }
}

# Merge gate: require an approved pull request, plus any configured status checks,
# before anything merges to the default branch. This gates the merge, not the
# apply: the engine applies from a tfpr apply comment on the open PR and checks the
# same review decision itself. Org admins may always bypass for break-glass;
# ruleset_bypass_actors adds more, such as an operator team. A real
# customer's approver team reviews the PR (it carries the plan output); they
# cannot approve their own PR, which is the gate.
resource "github_repository_ruleset" "require_approved_pr" {
  count       = var.require_approved_pr ? 1 : 0
  name        = "require-approved-pr-to-main"
  repository  = github_repository.live.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  dynamic "bypass_actors" {
    for_each = var.ruleset_bypass_actors
    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.team_slug != null ? data.github_team.ruleset_bypass[bypass_actors.value.team_slug].id : bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  rules {
    # Defence in depth: the pull_request rule already blocks direct pushes.
    non_fast_forward = true
    deletion         = true

    pull_request {
      required_approving_review_count   = var.required_approving_review_count
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = var.require_code_owner_review
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    # Apply-before-merge: require the tfpr / merge-gate check green (set by
    # tfpr apply, or success when nothing is affected) before a PR can merge. With
    # checks_app_id set, only that App's check run counts, so a same-named
    # check from a workflow cannot stand in for the engine's gate.
    dynamic "required_status_checks" {
      for_each = length(var.required_status_checks) > 0 ? [1] : []
      content {
        dynamic "required_check" {
          for_each = toset(var.required_status_checks)
          content {
            context        = required_check.value
            integration_id = var.checks_app_id
          }
        }
        strict_required_status_checks_policy = false
      }
    }
  }

  # The files below are pushed straight to the default branch, which this
  # ruleset would block.
  depends_on = [github_repository_file.customer_hcl, github_repository_file.codeowners]
}

data "github_team" "ruleset_bypass" {
  for_each = toset([for actor in var.ruleset_bypass_actors : actor.team_slug if actor.team_slug != null])
  slug     = each.value
}

# With zero required reviews, or no ruleset, GitHub returns an empty
# reviewDecision, and the engine applies on that only when this is set.
resource "github_actions_variable" "allow_unreviewed_apply" {
  count         = local.allow_unreviewed_apply ? 1 : 0
  repository    = github_repository.live.name
  variable_name = "TFPR_ALLOW_UNREVIEWED_APPLY"
  value         = "true"
}

import {
  for_each = var.adopt_allow_unreviewed_apply && local.allow_unreviewed_apply ? [1] : []
  to       = github_actions_variable.allow_unreviewed_apply[0]
  id       = "${var.customer_repository_name}:TFPR_ALLOW_UNREVIEWED_APPLY"
}

# Written once. The customer owns the file after that, and the template reads
# it instead of hand-edited values.
resource "github_repository_file" "customer_hcl" {
  count               = var.write_customer_hcl ? 1 : 0
  repository          = github_repository.live.name
  file                = "live/customer.hcl"
  content             = local.customer_hcl
  commit_message      = "chore: add live/customer.hcl from the bootstrap"
  overwrite_on_create = false

  lifecycle {
    ignore_changes = [content, commit_message]
  }
}

# Written once, like customer.hcl. The approver team has push access, which a
# code owner needs.
resource "github_repository_file" "codeowners" {
  count               = var.write_codeowners ? 1 : 0
  repository          = github_repository.live.name
  file                = ".github/CODEOWNERS"
  content             = local.codeowners
  commit_message      = "chore: add .github/CODEOWNERS from the bootstrap"
  overwrite_on_create = false

  lifecycle {
    ignore_changes = [content, commit_message]
  }

  depends_on = [github_team_repository.approvers]
}

# Repository-level Action variables.
resource "github_actions_variable" "azure_subscription_id" {
  repository    = github_repository.live.name
  variable_name = "AZURE_SUBSCRIPTION_ID"
  value         = var.management_subscription_id
}

resource "github_actions_variable" "azure_tenant_id" {
  repository    = github_repository.live.name
  variable_name = "AZURE_TENANT_ID"
  value         = var.tenant_id
}

resource "github_actions_variable" "backend_resource_group" {
  repository    = github_repository.live.name
  variable_name = "BACKEND_AZURE_RESOURCE_GROUP_NAME"
  value         = azurerm_resource_group.state.name
}

resource "github_actions_variable" "backend_storage_account" {
  repository    = github_repository.live.name
  variable_name = "BACKEND_AZURE_STORAGE_ACCOUNT_NAME"
  value         = azurerm_storage_account.state.name
}

resource "github_actions_variable" "backend_container" {
  repository    = github_repository.live.name
  variable_name = "BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME"
  value         = local.state_container_name
}

# Runner label the consumer workflows pass to the reusable pipelines as runs_on.
# self_hosted_private registers runners with the default self-hosted label and
# requires deploys to run from inside the bootstrap network (default-deny state);
# github_hosted uses GitHub-hosted runners. One flag (network_posture) drives it.
resource "github_actions_variable" "runner_label" {
  repository    = github_repository.live.name
  variable_name = "RUNNER_LABEL"
  value         = local.use_private_networking ? "self-hosted" : "ubuntu-latest"
}

# Tools the engine's setup-tools action installs per run for the post_plan
# gates. The self-hosted runner image already carries conftest and checkov, so
# only infracost is installed per run there; GitHub-hosted runners carry none.
resource "github_actions_variable" "tfpr_extra_tools" {
  count         = length(local.tfpr_extra_tools) > 0 ? 1 : 0
  repository    = github_repository.live.name
  variable_name = "TFPR_EXTRA_TOOLS"
  value         = join(" ", local.tfpr_extra_tools)
}

resource "github_actions_secret" "infracost_api_key" {
  count       = nonsensitive(var.infracost_api_key != null) ? 1 : 0
  repository  = github_repository.live.name
  secret_name = "INFRACOST_API_KEY"
  value       = var.infracost_api_key
}

# tfpr license: the engine plans without these and applies only with both.
# Repository variables, because private repositories on GitHub Free cannot
# read organization variables.
resource "github_actions_variable" "tfpr_license" {
  count         = nonsensitive(var.tfpr_license != null) ? 1 : 0
  repository    = github_repository.live.name
  variable_name = "TFPR_LICENSE"
  value         = var.tfpr_license
}

resource "github_actions_variable" "tfpr_entitlement" {
  count         = nonsensitive(var.tfpr_entitlement != null) ? 1 : 0
  repository    = github_repository.live.name
  variable_name = "TFPR_ENTITLEMENT"
  value         = var.tfpr_entitlement
}

import {
  for_each = contains(var.adopt_tfpr_variables, "TFPR_LICENSE") && nonsensitive(var.tfpr_license != null) ? [1] : []
  to       = github_actions_variable.tfpr_license[0]
  id       = "${var.customer_repository_name}:TFPR_LICENSE"
}

import {
  for_each = contains(var.adopt_tfpr_variables, "TFPR_ENTITLEMENT") && nonsensitive(var.tfpr_entitlement != null) ? [1] : []
  to       = github_actions_variable.tfpr_entitlement[0]
  id       = "${var.customer_repository_name}:TFPR_ENTITLEMENT"
}

# Checks GitHub App: owns every engine-authored check run, the merge gate
# included. scripts/create-github-app.sh -p checks creates it once per
# organization; the bootstrap wires the client id and key the engine reads.
resource "github_actions_variable" "checks_app_client_id" {
  count         = var.checks_app_client_id == "" ? 0 : 1
  repository    = github_repository.live.name
  variable_name = "TFPR_CHECKS_APP_CLIENT_ID"
  value         = var.checks_app_client_id
}

# Repository level only where environments cannot hold it (a GitHub Free org):
# any branch workflow can read a repository secret.
resource "github_actions_secret" "checks_app_private_key" {
  count       = !var.limit_environments_to_default_branch && var.checks_app_private_key != null ? 1 : 0
  repository  = github_repository.live.name
  secret_name = "TFPR_CHECKS_APP_PRIVATE_KEY"
  value       = var.checks_app_private_key
}

# Only default-branch runs can read an environment secret.
resource "github_actions_environment_secret" "checks_app_private_key" {
  for_each    = var.limit_environments_to_default_branch && nonsensitive(var.checks_app_private_key != null) ? local.environments : {}
  repository  = github_repository.live.name
  environment = github_repository_environment.env[each.key].environment
  secret_name = "TFPR_CHECKS_APP_PRIVATE_KEY"
  value       = var.checks_app_private_key
}

# Adding a repository to another App's installation needs a user token, which
# the bootstrap App cannot be. The checks App is installed on all repositories
# instead. Forget the old resource without uninstalling anything.
removed {
  from = github_app_installation_repository.checks_app

  lifecycle {
    destroy = false
  }
}

# Per-environment client id: the plan environment uses the plan identity, the
# apply environment uses the apply identity.
resource "github_actions_environment_variable" "azure_client_id" {
  for_each      = local.environments
  repository    = github_repository.live.name
  environment   = github_repository_environment.env[each.key].environment
  variable_name = "AZURE_CLIENT_ID"
  value         = azurerm_user_assigned_identity.cicd[each.key].client_id
}

# Unauthenticated org metadata read; only the numeric id is used, for the
# immutable-id OIDC subject format.
data "http" "github_org" {
  url = "https://api.github.com/orgs/${var.github_organization}"
}
