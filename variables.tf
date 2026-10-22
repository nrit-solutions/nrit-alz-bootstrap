# Customer identity ----------------------------------------------------------

variable "customer_name" {
  description = "Customer slug, used in resource names. Lower case, letters and digits and hyphens. For example contoso."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.customer_name))
    error_message = "customer_name must be 2 to 20 characters of lower case letters, digits, or hyphens."
  }
}

variable "location" {
  description = "Azure region for the bootstrap resources."
  type        = string
  default     = "westeurope"
}

variable "location_short" {
  description = "Short region code used in resource names, for example weu."
  type        = string
  default     = "weu"
}

variable "tenant_id" {
  description = "Entra ID tenant of the customer."
  type        = string
}

variable "management_subscription_id" {
  description = "Management subscription. Holds the platform state, the CI/CD identities, and the runners. There is no separate bootstrap subscription."
  type        = string
}

variable "tags" {
  description = "Tags applied to all bootstrap resources."
  type        = map(string)
  default     = {}
}

# Deploy identity scope -------------------------------------------------------

variable "management_group_scope_id" {
  description = "Management group the plan and apply identities operate at (the ALZ parent, or the alz group of a hierarchy rooted at the tenant root), as a full resource id: /providers/Microsoft.Management/managementGroups/<name>. Null means the tenant root group and makes the apply identity Owner of the whole tenant; use that only for a throwaway apply test, never for a production tenant. The management subscription must already sit under the group, or the first foundation apply has no rights on it."
  type        = string
  default     = null
  validation {
    condition     = var.management_group_scope_id == null || can(regex("^/providers/Microsoft\\.Management/managementGroups/[^/]+$", var.management_group_scope_id))
    error_message = "management_group_scope_id must be a full resource id, /providers/Microsoft.Management/managementGroups/<name>, not the plain name. (live/tenant.hcl in the customer repository takes the plain name.)"
  }
}

variable "plan_role_definition_name" {
  description = "Built-in role for the plan identity at the management group scope."
  type        = string
  default     = "Reader"
}

variable "apply_role_definition_name" {
  description = "Built-in role for the apply identity at the management group scope. Owner is required because the foundation creates role assignments and policy."
  type        = string
  default     = "Owner"
}

# GitHub ----------------------------------------------------------------------

variable "github_organization" {
  description = "GitHub organization that owns the customer repository."
  type        = string
}

variable "github_token" {
  description = "GitHub PAT with repo and admin:org scope in the organization that receives the customer repository (the approver team and the ruleset are created there; nothing is needed on nrit-solutions). The fallback when github_app_id is null; ignored by the github provider when it is set. Prefer the GITHUB_TOKEN or TF_VAR_github_token environment variable; never put this in a tfvars file."
  type        = string
  sensitive   = true
  default     = null
}

variable "github_app_id" {
  description = "Numeric App ID of the bootstrap GitHub App (not the Iv... client id). When set, the github provider authenticates as this App's installation on github_organization (app_auth) instead of the PAT. Create the App with scripts/create-github-app.sh -p bootstrap. Null keeps the PAT path."
  type        = string
  default     = null
  validation {
    condition     = var.github_app_id == null || can(regex("^[0-9]+$", var.github_app_id))
    error_message = "github_app_id must be the numeric App ID, not the Iv... client id."
  }
}

variable "github_app_installation_id" {
  description = "Installation id of the bootstrap GitHub App on github_organization. Required when github_app_id is set. Look it up with: gh api orgs/<org>/installations --jq '.installations[] | {id, app_slug}'."
  type        = string
  default     = null
  validation {
    condition     = (var.github_app_id == null) == (var.github_app_installation_id == null)
    error_message = "github_app_id and github_app_installation_id must be set together."
  }
  validation {
    condition     = var.github_app_installation_id == null || can(regex("^[0-9]+$", var.github_app_installation_id))
    error_message = "github_app_installation_id must be numeric."
  }
}

variable "github_app_pem_file" {
  description = "Path to the bootstrap GitHub App's private key (PEM) on the operator's machine. One of this or github_app_private_key is required when github_app_id is set. A path, not the key, so it may sit in a tfvars file; ~ is expanded."
  type        = string
  default     = null
}

variable "github_app_private_key" {
  description = "Private key (PEM) of the bootstrap GitHub App, as an alternative to github_app_pem_file. Provide via TF_VAR_github_app_private_key; never put it in a tfvars file."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.github_app_id == null || ((var.github_app_private_key == null) != (var.github_app_pem_file == null))
    error_message = "With github_app_id set, give exactly one of github_app_pem_file and TF_VAR_github_app_private_key."
  }
}

variable "customer_repository_name" {
  description = "Name of the infrastructure-live repository generated for this customer."
  type        = string
}

variable "template_repository" {
  description = "Template repository the customer repository is generated from. The default is public, so generation works from any organization with no extra access."
  type = object({
    owner      = string
    repository = string
  })
  default = {
    owner      = "nrit-solutions"
    repository = "nrit-alz-customer-template"
  }
}

variable "oidc_subject_uses_repo_ids" {
  description = "GitHub presents the OIDC sub claim of newly created repositories with immutable ids (repo:org@id/repo@id:environment:env). True (default) builds the federated credential subjects in that format. Set false only for customer repositories created before GitHub's immutable-reference rollout, which still present the legacy name-only subject."
  type        = bool
  default     = true
}

variable "checks_app_client_id" {
  description = "Client id (Iv...) of the checks GitHub App. Set on the customer repository as the TFPR_CHECKS_APP_CLIENT_ID variable; since engine v3 every engine-authored check run, the merge gate included, is written under this App. The App is per organization, needs Checks read and write only, webhook off. Create it with scripts/create-github-app.sh -p checks and install it on the organization with all repositories, so every customer repository is covered. Empty skips it, and the check rows then render under an arbitrary Actions heading."
  type        = string
  default     = ""
}

variable "checks_app_private_key" {
  description = "Private key (PEM) of the checks GitHub App. Set as the TFPR_CHECKS_APP_PRIVATE_KEY secret on the plan and apply environments, or on the repository when limit_environments_to_default_branch is false. Supply via TF_VAR_checks_app_private_key; never put it in a tfvars file. Omitting it on a re-run destroys the existing secret."
  type        = string
  sensitive   = true
  default     = null
}

variable "checks_app_id" {
  description = "Numeric App ID of the checks App (not the Iv... client id). When set, every context in required_status_checks is pinned to this App in the pull-request ruleset, so only a check run the engine writes as the App can satisfy the merge gate; a same-named check from a workflow or another App does not count. Null leaves the required checks unpinned. Only applies when require_approved_pr is true and required_status_checks is non-empty."
  type        = number
  default     = null
  validation {
    condition     = var.checks_app_id == null || var.checks_app_client_id != ""
    error_message = "checks_app_id needs checks_app_client_id: a merge gate pinned to an App the engine does not use can never go green."
  }
}

# tfpr license ------------------------------------------------------------------

variable "msp_tenant_id" {
  description = "Entra tenant of the MSP that holds the tfpr license, where the operator signs in to the licensing portal. Read only by scripts/onboard.sh, which requests the entitlement with a token for this tenant. Null means the customer tenant (tenant_id), which is right when the MSP runs its own landing zone."
  type        = string
  default     = null
}

variable "tfpr_license" {
  description = "The MSP's tfpr license, the signed token NRIT issues once per MSP. Set as the TFPR_LICENSE repository variable; a repository variable because private repositories on GitHub Free cannot read organization variables. It is not a secret: it is signed, and the engine accepts it only with an entitlement for the repository's own organization. Engine v9 and later plan without it and refuse to apply. Null writes nothing and removes a variable the bootstrap wrote before."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.tfpr_license == null || can(regex("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", var.tfpr_license))
    error_message = "tfpr_license must be a compact JWS (three base64url parts separated by dots)."
  }
}

variable "tfpr_entitlement" {
  description = "The customer's tfpr entitlement from the licensing portal, bound to tenant_id and the numeric id of github_organization. Set as the TFPR_ENTITLEMENT repository variable. scripts/onboard.sh fetches or issues it and writes it into the tfvars. Not a secret, for the same reason as tfpr_license. Null writes nothing and removes a variable the bootstrap wrote before."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.tfpr_entitlement == null || can(regex("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", var.tfpr_entitlement))
    error_message = "tfpr_entitlement must be a compact JWS (three base64url parts separated by dots)."
  }
}

variable "adopt_tfpr_variables" {
  description = "Repository variables among TFPR_LICENSE and TFPR_ENTITLEMENT that were set by hand before the bootstrap managed them. They are imported instead of failing to create them. Once imported the setting does nothing, so it can stay."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for name in var.adopt_tfpr_variables : contains(["TFPR_LICENSE", "TFPR_ENTITLEMENT"], name)])
    error_message = "adopt_tfpr_variables takes TFPR_LICENSE and TFPR_ENTITLEMENT only."
  }
}

variable "apply_approvers" {
  description = "GitHub usernames that review the customer repository's pull requests. A team is created, added to the members, and given push permission. It is not set as an environment reviewer: the plan and apply environments carry no protection rules, because GitHub does not offer environment protection on private repositories on the Team plan. Approval is enforced by the pull-request ruleset and the engine's review-decision check instead."
  type        = list(string)
  default     = []
}

variable "require_approved_pr" {
  description = "Gate the merge by requiring an approved pull request to the default branch (a branch ruleset). The engine gates /apply separately on the same review decision; there is no push trigger. Uses a ruleset rather than environment required-reviewers because rulesets work on the GitHub Team plan whereas private-repo environment protection does not. Org admins can bypass. Set false to skip the gate entirely."
  type        = bool
  default     = true
}

variable "required_approving_review_count" {
  description = "Approving reviews the pull-request ruleset requires. A single-writer org cannot self-approve on GitHub, so it sets 0 to keep the PR gate without an unmeetable review; a multi-writer org keeps 1 or more. Only applies when require_approved_pr is true. With 0, or with require_approved_pr false, GitHub returns an empty reviewDecision, and the engine applies on an empty decision only when the repository variable TFPR_ALLOW_UNREVIEWED_APPLY is true. The bootstrap sets that variable in exactly those two cases and removes it otherwise."
  type        = number
  default     = 1
}

variable "adopt_allow_unreviewed_apply" {
  description = "Import a TFPR_ALLOW_UNREVIEWED_APPLY variable that was set by hand before the bootstrap managed it. Creating it again would fail, because it already exists. Set true on a repository that has it; once imported the setting does nothing, so it can stay. Leave false for a new repository."
  type        = bool
  default     = false
}

variable "require_code_owner_review" {
  description = "Require an approving review from a code owner (.github/CODEOWNERS) in the pull-request ruleset. A path no CODEOWNERS line covers needs no owner review, so a repository with an empty CODEOWNERS is not blocked. A code owner cannot approve their own pull request, so a single-writer org whose CODEOWNERS names that writer sets false. Only applies when require_approved_pr is true."
  type        = bool
  default     = true
}

variable "ruleset_bypass_actors" {
  description = "Actors that may bypass the pull-request ruleset, on top of the organization admins, who always keep break-glass bypass. For a customer-owned organization, give the MSP operator team pull-request-only bypass: { actor_type = \"Team\", team_slug = \"<slug>\" }. A team is named by its slug in github_organization; every other actor type (RepositoryRole, Integration, User) takes a numeric actor_id. bypass_mode is pull_request (default), always or exempt."
  type = list(object({
    actor_type  = string
    team_slug   = optional(string)
    actor_id    = optional(number)
    bypass_mode = optional(string, "pull_request")
  }))
  default = []
  validation {
    condition     = alltrue([for actor in var.ruleset_bypass_actors : contains(["Team", "RepositoryRole", "Integration", "User"], actor.actor_type)])
    error_message = "ruleset_bypass_actors: actor_type must be Team, RepositoryRole, Integration or User. Organization admins are always added."
  }
  validation {
    condition     = alltrue([for actor in var.ruleset_bypass_actors : actor.actor_type == "Team" ? actor.team_slug != null && actor.actor_id == null : actor.team_slug == null && actor.actor_id != null])
    error_message = "ruleset_bypass_actors: a Team takes team_slug, every other actor type takes actor_id."
  }
  validation {
    condition     = alltrue([for actor in var.ruleset_bypass_actors : contains(["pull_request", "always", "exempt"], actor.bypass_mode)])
    error_message = "ruleset_bypass_actors: bypass_mode must be pull_request, always or exempt."
  }
}

variable "required_status_checks" {
  description = "Status-check contexts the pull-request ruleset requires green before merge. The default is [\"tf-pr-ops / merge-gate\"], the apply-before-merge model: a PR cannot merge until /apply has run (the engine seeds it success when nothing is affected). Only applies when require_approved_pr is true."
  type        = list(string)
  default     = ["tf-pr-ops / merge-gate"]
}

variable "allowed_actions" {
  description = "Action patterns the customer repository may run, next to GitHub-owned actions (github_actions_repository_permissions, allowed_actions = selected). The default covers the engine's reusable workflows and composite actions under both the current name tf-pr-ops and the coming name tfpr (the path form owner/repo/* is what matches them) and the third-party actions those workflows use: jdx/mise-action, azure/login, hashicorp/setup-terraform and asdf-vm/actions. A workflow that uses any other action fails to load, so an engine release that adopts a new action lists it in its release notes and this default follows."
  type        = list(string)
  default = [
    "nrit-solutions/tf-pr-ops@*",
    "nrit-solutions/tf-pr-ops/*",
    "nrit-solutions/tfpr@*",
    "nrit-solutions/tfpr/*",
    "jdx/mise-action@*",
    "azure/login@*",
    "hashicorp/setup-terraform@*",
    "asdf-vm/actions/*",
  ]
}

variable "state_diagnostics_workspace_id" {
  description = "Log Analytics workspace that receives the state account's blob and table audit logs (reads, writes, deletes on state and the unit-lock table). Null (default) writes no diagnostic setting. The management workspace is created by the customer repository, so set this after the first live apply and re-apply the bootstrap."
  type        = string
  default     = null
}

variable "accept_free_org_risk" {
  description = "Acknowledge that limit_environments_to_default_branch = false lets any branch workflow bind the apply environment and act as the apply identity. That posture exists for organizations on the Free plan, where environments cannot be limited on private repositories, and is for a single-writer sandbox only. Required when limit_environments_to_default_branch is false."
  type        = bool
  default     = false
}

variable "infracost_api_key" {
  description = "Infracost API key. Set as the INFRACOST_API_KEY repository secret, and infracost is added to TFPR_EXTRA_TOOLS so the engine prices each plan. Null (default) writes no secret and leaves infracost out, so no run installs a tool it cannot use. Supply via TF_VAR_infracost_api_key; never put it in a tfvars file. Like the App keys, omitting it on a re-run destroys the secret it wrote."
  type        = string
  sensitive   = true
  default     = null
}

variable "infracost_api_key_unmanaged" {
  description = "The INFRACOST_API_KEY secret is set outside the bootstrap, by hand or by the customer. Keeps infracost in TFPR_EXTRA_TOOLS without managing the secret. Do not combine with infracost_api_key."
  type        = bool
  default     = false
  validation {
    condition     = !(var.infracost_api_key_unmanaged && nonsensitive(var.infracost_api_key != null))
    error_message = "Set infracost_api_key or infracost_api_key_unmanaged, not both."
  }
}

variable "limit_environments_to_default_branch" {
  description = "Limit the plan and apply environments to the default branch and put the checks App key on them as an environment secret, so a workflow on any other branch gets neither the Azure token nor the key. Both features need GitHub Pro, Team or Enterprise for a private repository. Set false only on a GitHub Free organization with a private repository; any writer there can then reach the apply identity and the checks key from a branch, and rulesets are not enforced either, so nothing gates the merge."
  type        = bool
  default     = true
  validation {
    condition     = var.limit_environments_to_default_branch || var.accept_free_org_risk
    error_message = "limit_environments_to_default_branch = false lets any branch act as the apply identity. Set accept_free_org_risk = true to confirm this is a single-writer sandbox on a Free organization."
  }
}

variable "default_branch" {
  description = "Default branch of the customer repository."
  type        = string
  default     = "main"
}

# customer.hcl -----------------------------------------------------------------

variable "write_customer_hcl" {
  description = "Write live/customer.hcl into the customer repository once, with tenant_root_id (from management_group_scope_id), location, location_short, business_unit and amba_action_group_email. The repository owns the file after that: later edits are never overwritten, and the write fails rather than replace a file that is already there. Set false for a repository created before the bootstrap wrote it."
  type        = bool
  default     = true
}

variable "business_unit" {
  description = "Value of the businessunit tag on the platform resources, written to live/customer.hcl. Null uses customer_name."
  type        = string
  default     = null
}

variable "amba_action_group_email" {
  description = "Monitored inbox every Azure Monitor Baseline Alert routes to, written to live/customer.hcl. Required when write_customer_hcl is true."
  type        = string
  default     = null
  validation {
    condition     = !var.write_customer_hcl || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.amba_action_group_email))
    error_message = "amba_action_group_email must be an email address when write_customer_hcl is true."
  }
}

# CODEOWNERS -------------------------------------------------------------------

variable "secret_scanning" {
  description = "Enable secret scanning and push protection on the customer repository. Private repositories need GitHub Secret Protection, which Team and Enterprise organization plans can buy per active committer; a Free organization cannot, so set false there. When false the bootstrap leaves the setting alone."
  type        = bool
  default     = true
}

variable "write_codeowners" {
  description = "Write .github/CODEOWNERS into the customer repository once, naming the approver team as owner of /.github/ and /projects.yml (the engine callers and engine discovery). The repository owns the file after that: later edits are never overwritten, and the write fails rather than replace a file that is already there. Needs apply_approvers, which creates the team. Set false for a repository that already has a CODEOWNERS."
  type        = bool
  default     = true
  validation {
    condition     = !var.write_codeowners || length(var.apply_approvers) > 0
    error_message = "write_codeowners needs apply_approvers: the approver team it creates is the code owner."
  }
}

# Runner and network posture --------------------------------------------------

variable "network_posture" {
  description = "github_hosted uses GitHub-hosted runners with a public AAD-authenticated state account. self_hosted_private uses a private-endpoint state account and self-hosted runners on a bootstrap network. self_hosted_private is the production standard; github_hosted is for non-production and demos."
  type        = string
  default     = "github_hosted"
  validation {
    condition     = contains(["github_hosted", "self_hosted_private"], var.network_posture)
    error_message = "network_posture must be github_hosted or self_hosted_private."
  }
}

variable "allow_state_access_from_my_ip" {
  description = "When self_hosted_private, also allow the operator public IP through the state account firewall (for the initial bootstrap apply). Leave false in steady state."
  type        = bool
  default     = false
}

variable "runner_compute_type" {
  description = "Compute for self-hosted runners. azure_container_app (default) uses Container App Jobs that scale to zero when idle, so you pay only while a job runs: the cheapest option. azure_container_instance uses always-on container instances: no cold start, but standing cost."
  type        = string
  default     = "azure_container_app"
  validation {
    condition     = contains(["azure_container_app", "azure_container_instance"], var.runner_compute_type)
    error_message = "runner_compute_type must be azure_container_app or azure_container_instance."
  }
}

variable "container_app_max_execution_count" {
  description = "Maximum concurrent Container App Job executions for the self_hosted_private posture with runner_compute_type = azure_container_app. Each execution is one ephemeral runner; the job still scales to zero when idle, so a higher cap is cost-neutral (billed per vCPU/GiB-second of actual execution). Default 1 runs jobs one at a time. Maps to the AVM module input of the same name."
  type        = number
  default     = 1
  validation {
    condition     = var.container_app_max_execution_count >= 1 && var.container_app_max_execution_count <= 10
    error_message = "container_app_max_execution_count must be between 1 and 10."
  }
}

variable "container_instance_count" {
  description = "Number of always-on container instance runners for the self_hosted_private posture with runner_compute_type = azure_container_instance. Unlike Container App Jobs these do not scale to zero, so each instance is a direct standing cost. Default 1. Maps to the AVM module input of the same name."
  type        = number
  default     = 1
  validation {
    condition     = var.container_instance_count >= 1 && var.container_instance_count <= 10
    error_message = "container_instance_count must be between 1 and 10."
  }
}

variable "runner_vnet_address_space" {
  description = "Address space for the standalone bootstrap network that hosts the self-hosted runners (self_hosted_private only). The runner module carves its runner, registry, and endpoint subnets from this. Independent of the landing zone connectivity stack."
  type        = string
  default     = "10.0.0.0/24"
}

variable "nat_gateway_enabled" {
  description = "Create a NAT gateway with an owned static egress IP for the runner network (self_hosted_private only). Gives the runners a stable, allowlistable outbound address. When false, egress uses the Container Apps environment's managed path with a dynamic IP, saving the NAT gateway and public IP cost; fine when nothing binds to the egress IP."
  type        = bool
  default     = true
}

variable "github_runners_app_id" {
  description = "Numeric App ID of the runners GitHub App (self_hosted_private only). The App authenticates the KEDA scaler and the runner registration with short-lived installation tokens, replacing the expiring runner PAT. Repository permissions: Administration read and write, Actions read; installed on the customer repository. Use the numeric App ID, not the Iv... client id: both the scaler and the runner image match the installation by app_id. Null keeps the PAT path (github_runners_token)."
  type        = string
  default     = null
}

variable "github_runners_app_installation_id" {
  description = "Installation id of the runners GitHub App on the customer organization (self_hosted_private only). Required when github_runners_app_id is set. Look it up with: gh api orgs/<org>/installations --jq '.installations[] | {id, app_slug}'."
  type        = string
  default     = null
  validation {
    condition     = (var.github_runners_app_id == null) == (var.github_runners_app_installation_id == null)
    error_message = "github_runners_app_id and github_runners_app_installation_id must be set together."
  }
}

variable "github_runners_app_private_key" {
  description = "Private key (PEM) of the runners GitHub App. Provide via the TF_VAR_github_runners_app_private_key environment variable; never put this in a tfvars file. Required when github_runners_app_id is set."
  type        = string
  sensitive   = true
  default     = null
}

variable "github_runners_token" {
  description = "GitHub PAT used to register the self-hosted runners (self_hosted_private only) on the PAT fallback path (github_runners_app_id null), with repo or org admin scope. PATs expire and an expired one silently stops all runner scale-up, so prefer the runners App. Provide via the TF_VAR_github_runners_token environment variable; falls back to github_token. Never put this in a tfvars file."
  type        = string
  sensitive   = true
  default     = null
}

variable "container_app_container_cpu" {
  description = "vCPU per runner replica. The AVM default of 1 starves the heavy ALZ policy-library plans; pair with container_app_container_memory (Container Apps requires 2Gi per vCPU)."
  type        = number
  default     = 2
}

variable "container_app_container_memory" {
  description = "Memory per runner replica. The AVM default of 2Gi OOM-kills terraform provider subprocesses on the heaviest units (amba runs two ALZ provider instances), which leaves terraform hanging on the plugin RPC until the replica timeout."
  type        = string
  default     = "4Gi"
}

variable "container_app_replica_timeout" {
  description = "Seconds a runner replica may live before the Container Apps job kills it, which also kills the workflow job it is running. The AVM default of 1800 is too short for the slow ALZ policy-library plans; 7200 bounds runaway jobs without killing real ones."
  type        = number
  default     = 7200
}

variable "container_app_polling_interval_seconds" {
  description = "Seconds between KEDA checks of the GitHub job queue for runner_compute_type = azure_container_app. A queued job waits on average half this interval before a runner execution starts, on top of the container start itself. The AVM default of 30 added about 15 seconds to every self-hosted job; 10 keeps the wait small at 360 polls per hour, each one or two GitHub API requests on the runners App, well inside its 5,000 per hour budget. Polling is not billed by Azure; the job still scales to zero. Below 5 the API budget starts to matter for little further gain."
  type        = number
  default     = 10

  validation {
    condition     = var.container_app_polling_interval_seconds >= 1 && var.container_app_polling_interval_seconds <= 300
    error_message = "container_app_polling_interval_seconds must be between 1 and 300."
  }
}

variable "runner_image_repository" {
  description = "Public registry path of the prebuilt signed runner image, without tag or digest. The default is the NRIT-published image; its current release is listed at https://docs.nrit.cloud/reference/versions/#runner-image-pin. Only used when runner_image_commit is null."
  type        = string
  default     = "ghcr.io/nrit-solutions/alz-runner"
}

variable "runner_image_version" {
  description = "Version (image tag) of the prebuilt runner image. Recorded as the target tag in the in-tenant registry so an operator can read which image version a customer runs. Must belong together with runner_image_digest; take both from the same release, listed at https://docs.nrit.cloud/reference/versions/#runner-image-pin."
  type        = string
  default     = "2.0.0"
}

variable "runner_image_digest" {
  description = "Manifest digest of the prebuilt runner image. The digest, not the tag, is what gets imported and what the Container App Job pulls, so it is pinned to exactly the signed artifact; a release bump changes runner_image_version and this digest together."
  type        = string
  default     = "sha256:a356a4e5b59bc0aeaf884e844f33f18b2e879a465fbd74defb383f842fab78a1"
  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.runner_image_digest))
    error_message = "runner_image_digest must be a full sha256:<64 hex> manifest digest."
  }
}

variable "runner_image_commit" {
  description = "Build-from-source fallback for sovereignty-sensitive customers: the nrit-alz-bootstrap git ref (commit SHA preferred) that holds runner-image/github-runner-aca. When set, the runner image is built by an in-tenant ACR build task from that ref instead of importing the prebuilt signed image, and the runner_image_repository/version/digest pins are ignored. Use a commit SHA so the image tag changes when the Dockerfile changes and the Container App Job redeploys."
  type        = string
  default     = null
}

variable "runner_image_context_token" {
  description = "Token the ACR build task uses to clone the build context for the build-from-source fallback (runner_image_commit set). The context is the public bootstrap repository, so it is normally unneeded; falls back to github_token. Provide via TF_VAR_runner_image_context_token; never put this in a tfvars file. Unused on the default import path, which needs no token at all."
  type        = string
  sensitive   = true
  default     = null
}
