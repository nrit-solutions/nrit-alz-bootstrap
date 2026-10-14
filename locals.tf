resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = false
}

locals {
  # Resource names ----------------------------------------------------------
  resource_group_state    = "rg-cicd-state-${var.location_short}"
  resource_group_identity = "rg-cicd-identity-${var.location_short}"
  resource_group_runners  = "rg-cicd-runners-${var.location_short}"

  # Storage account names are globally unique, 3 to 24 chars, lower case
  # alphanumeric only. The random suffix keeps it unique across customers.
  storage_account_name = "stcicd${var.location_short}${random_string.suffix.result}"
  state_container_name = "tfstate"

  managed_identities = {
    plan  = "id-cicd-plan-${var.location_short}"
    apply = "id-cicd-apply-${var.location_short}"
  }

  # Deploy identity scope ---------------------------------------------------
  management_group_scope_id = coalesce(
    var.management_group_scope_id,
    "/providers/Microsoft.Management/managementGroups/${var.tenant_id}"
  )

  # Network posture ---------------------------------------------------------
  use_private_networking = var.network_posture == "self_hosted_private"

  # Customer repository settings -------------------------------------------
  allow_unreviewed_apply = !var.require_approved_pr || var.required_approving_review_count == 0

  infracost_enabled = nonsensitive(var.infracost_api_key != null) || var.infracost_api_key_unmanaged
  tfpr_extra_tools = concat(
    local.use_private_networking ? [] : ["conftest", "checkov"],
    local.infracost_enabled ? ["infracost"] : [],
  )

  # live/ in the template takes the plain management group name, not the full
  # resource id this root uses.
  tenant_root_id = basename(local.management_group_scope_id)

  customer_hcl = <<-EOT
    # customer.hcl
    #
    # Customer values for this live tree, written once by nrit-alz-bootstrap.
    # This repository owns the file from here on: edit it freely, the bootstrap
    # never writes it again.

    locals {
      # Management group the ALZ hierarchy is created under, as the plain name
      # (the tenant root group's name is the tenant id).
      tenant_root_id = ${jsonencode(local.tenant_root_id)}

      # Primary region of the foundation.
      location       = ${jsonencode(var.location)}
      location_short = ${jsonencode(var.location_short)}

      # Value of the businessunit tag on the platform resources.
      business_unit = ${jsonencode(coalesce(var.business_unit, var.customer_name))}

      # Monitored inbox every Azure Monitor Baseline Alert routes to.
      amba_action_group_email = ${jsonencode(var.amba_action_group_email)}
    }
  EOT

  codeowners_owner = length(var.apply_approvers) > 0 ? "@${var.github_organization}/${github_team.approvers[0].slug}" : null

  codeowners = <<-EOT
    # Code owners for this infrastructure-live repository, written once by
    # nrit-alz-bootstrap. This repository owns the file from here on.
    #
    # With require_code_owner_review on in the bootstrap's ruleset, a pull
    # request touching a path below needs an approval from its owner.

    # The engine callers, runner workflows, invariants script, and this file.
    /.github/       ${local.codeowners_owner}

    # Engine discovery and the gate hooks.
    /projects.yml   ${local.codeowners_owner}
  EOT

  # Bootstrap GitHub auth ---------------------------------------------------
  github_app_private_key = (
    var.github_app_id == null ? null
    : var.github_app_private_key != null ? var.github_app_private_key
    : file(pathexpand(var.github_app_pem_file))
  )

  # Runner auth -------------------------------------------------------------
  runners_use_app = var.github_runners_app_id != null

  # Runner image ------------------------------------------------------------
  # Default: import the prebuilt signed image from GHCR by digest
  # (runner-image.tf). Fallback: runner_image_commit switches to the in-tenant
  # ACR build tasks (build from source).
  runner_image_from_source = var.runner_image_commit != null
  runner_image_import      = local.use_private_networking && !local.runner_image_from_source

  # Registry names are globally unique, alphanumeric only. Built from vars,
  # not the random suffix: the module gates its AcrPull role assignment on
  # custom_container_registry_id being non-null, so the id must be known at
  # plan time or every plan fails with "Invalid count argument".
  runner_registry_name = replace("acrcicd${var.location_short}${var.customer_name}", "-", "")

  # ghcr.io/nrit-solutions/alz-runner -> registry uri and repository path, the
  # shape the importImage action wants them in.
  runner_image_registry_uri    = split("/", var.runner_image_repository)[0]
  runner_image_repository_path = join("/", slice(split("/", var.runner_image_repository), 1, length(split("/", var.runner_image_repository))))

  # GitHub OIDC -------------------------------------------------------------
  github_issuer = "https://token.actions.githubusercontent.com"
  oidc_audience = "api://AzureADTokenExchange"

  environments = {
    plan  = "plan"
    apply = "apply"
  }

  # Federated credential subjects bind two claims: the customer repository and
  # the deployment environment. The identity works for any pipeline version, so a
  # tag bump needs no re-bootstrap; the trust boundary is the repository plus the
  # environment (apply is gated by the engine's review-decision check, not by the
  # environment). Plan and drift both run in the plan environment on the Reader
  # identity, so one credential covers both; drift no longer needs its own.
  #
  # GitHub renders the repository in OIDC sub claims of newly created repositories
  # with immutable ids (org@id/repo@id); repositories created before that rollout
  # keep the legacy name-only form. oidc_subject_uses_repo_ids selects the format.
  org_database_id = jsondecode(data.http.github_org.response_body).id
  subject_repository = (
    var.oidc_subject_uses_repo_ids
    ? "${var.github_organization}@${local.org_database_id}/${var.customer_repository_name}@${github_repository.live.repo_id}"
    : "${var.github_organization}/${var.customer_repository_name}"
  )

  federated_credentials = {
    plan = {
      identity_key = "plan"
      subject      = "repo:${local.subject_repository}:environment:${local.environments.plan}"
    }
    apply = {
      identity_key = "apply"
      subject      = "repo:${local.subject_repository}:environment:${local.environments.apply}"
    }
  }
}
