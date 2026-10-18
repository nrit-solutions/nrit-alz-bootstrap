# Per-customer bootstrap inputs. Copy to <customer>.tfvars in the MSP's private
# operator repository and fill in.
# Never put a GitHub PAT or App private key here.

customer_name  = "contoso"
location       = "westeurope"
location_short = "weu"

tenant_id                  = "00000000-0000-0000-0000-000000000000"
management_subscription_id = "00000000-0000-0000-0000-000000000000" # holds state, identities, runners

# Scope the deploy identities at the customer's ALZ parent management group,
# as a full resource id (live/tenant.hcl takes the plain name of the same
# group). Null uses the tenant root group, which makes the apply identity Owner
# of the whole tenant: acceptable for a throwaway apply test, not for a
# production tenant. With an intermediate group, move the management
# subscription under it before the first foundation apply. For a hierarchy
# that already sits at the tenant root, scope to its alz group (README, "Scope
# on an existing hierarchy").
# management_group_scope_id = "/providers/Microsoft.Management/managementGroups/<name>"
management_group_scope_id = null

# GitHub
github_organization      = "<github-organization>"
customer_repository_name = "contoso-alz-live"
apply_approvers          = ["some-github-user"]

# Bootstrap GitHub App: the github provider authenticates as it (app_auth)
# instead of a PAT. One App per MSP, created in the MSP's organization with
# scripts/create-github-app.sh -p bootstrap and installed only on that
# organization (github_organization). "Only select repositories" is enough: a repository the
# App creates joins its installation, so select only existing repositories the
# bootstrap manages (on an empty organization, a placeholder repository). The
# key stays with the operator: give its path here, or export
# TF_VAR_github_app_private_key instead. Leave all three unset to keep the PAT
# in GITHUB_TOKEN.
# github_app_id              = "<numeric app id>"
# github_app_installation_id = "<installation id>" # gh api orgs/<org>/installations
# github_app_pem_file        = "~/keys/<app>.private-key.pem"

# Apply-before-merge: a PR cannot merge until /apply has run green. This is the
# recommended value. The bootstrap default is [], which requires no status check
# at all, so leaving this out lets a PR merge with unapplied changes.
required_status_checks = ["tf-pr-ops / merge-gate"]

# tfpr license (engine v9). The MSP license NRIT issued, the same on every
# customer of the MSP. scripts/onboard.sh adds tfpr_entitlement for this
# tenant and organization from the licensing portal. Signed tokens, not
# secrets, so they belong here. msp_tenant_id is the MSP's Entra tenant for
# the portal sign-in; leave it unset when it is tenant_id.
tfpr_license = "<MSP license token from NRIT>"
# msp_tenant_id = "00000000-0000-0000-0000-000000000000"

# Checks GitHub App: the engine writes every check row, the merge gate included,
# under this App. Create it once per organization with
# scripts/create-github-app.sh -p checks and install it on all repositories
# there, so each new customer repository is covered. The bootstrap sets
# TFPR_CHECKS_APP_CLIENT_ID and pins the required merge gate to the App so no
# other check of that name can satisfy it. The private key comes from
# TF_VAR_checks_app_private_key, never a tfvars file.
# checks_app_client_id = "Iv..."  # client id
# checks_app_id        = 1234567  # numeric App ID (ruleset pin)

# Runner and network posture. Default github_hosted.
#   github_hosted       non-production and demos (public AAD state)
#   self_hosted_private production standard (private state, self-hosted runners)
network_posture = "github_hosted"

# live/customer.hcl, written once into the new repository; the customer owns it
# after that. tenant_root_id comes from management_group_scope_id and the region
# from location. A repository created before the bootstrap wrote this file sets
# write_customer_hcl = false.
amba_action_group_email = "alerts@customer.example" # monitored inbox for every AMBA alert
# business_unit         = "contoso"             # businessunit tag; default customer_name
# write_customer_hcl    = true

# .github/CODEOWNERS, written once into the new repository: the approver team
# (from apply_approvers) owns /.github/ and /projects.yml. The customer owns the
# file after that. A repository that already has one sets false.
# write_codeowners = true

# Infracost. Set the key through TF_VAR_infracost_api_key (never here) and the
# bootstrap writes the INFRACOST_API_KEY secret and adds infracost to
# TFPR_EXTRA_TOOLS. Without a key infracost is left out. If the customer sets
# the secret themselves, keep infracost with:
# infracost_api_key_unmanaged = true

# Merge gate: require an approved pull request to main (a branch ruleset).
# Nothing applies on merge. The engine applies from an /apply comment on the open
# PR and checks the same review decision itself, so this ruleset gates the merge
# and the engine gates the apply.
# Default true. Set false only to skip the gate entirely.
# require_approved_pr = true

# Approving reviews the ruleset requires. Default 1, which is what a multi-writer
# customer wants. A single-writer org sets 0, because GitHub blocks approving your
# own PR. GitHub then returns an empty reviewDecision, so the bootstrap also sets
# TFPR_ALLOW_UNREVIEWED_APPLY = true on the repository, without which the engine
# refuses to apply.
# required_approving_review_count = 1

# Require code owner approval for paths .github/CODEOWNERS covers. Default true.
# A single-writer org whose CODEOWNERS names that writer sets false.
# require_code_owner_review = true

# Extra ruleset bypass actors; org admins always keep break-glass. In a
# customer-owned organization, give the MSP operator team pull-request-only
# bypass:
# ruleset_bypass_actors = [{ actor_type = "Team", team_slug = "<operator-team>" }]

# Limit the plan and apply environments to the default branch and put the
# checks App key on them. Needs GitHub Pro, Team or Enterprise for a private
# repository. Default true. Set false only on a GitHub Free org, which also
# cannot enforce the ruleset above, so nothing guards the merge there.
# limit_environments_to_default_branch = true

# Runner cost controls (self_hosted_private only):
# runner_compute_type               = "azure_container_app" # scale-to-zero, cheapest (default)
# container_app_max_execution_count = 1                      # max concurrent Container App Job runners (scales to zero)
# container_instance_count          = 1                      # always-on ACI runners (only for azure_container_instance)
# runner_vnet_address_space         = "10.0.0.0/24"

# Runner image (self_hosted_private only). The default imports the prebuilt,
# signed image (ghcr.io/nrit-solutions/alz-runner) into a bootstrap-owned
# registry by digest; no token of any kind is needed. Pin the release per
# customer so it is on record which version they run; both values come from
# the same release, listed at
# https://docs.nrit.cloud/reference/versions/#runner-image-pin:
# runner_image_version = "2.0.0"
# runner_image_digest  = "sha256:..."

# Secret scanning and push protection on the repository. Needs GitHub Secret
# Protection on the organization plan; a Free organization sets false.
# secret_scanning = true
# Sovereignty fallback: build the image in-tenant from source instead. Set a
# commit SHA of nrit-alz-bootstrap holding runner-image/github-runner-aca;
# applying then needs TF_VAR_github_token exported and stores that PAT in the
# customer tenant's ACR build task:
# runner_image_commit = "<sha>"

# Runner registration auth (self_hosted_private only). Recommended: a GitHub
# App with repository permissions Administration read/write and Actions read,
# installed on the customer repository. The scaler and the runners mint
# short-lived installation tokens from it, so nothing stored in the tenant
# can expire. The private key comes from TF_VAR_github_runners_app_private_key,
# never a tfvars file. Use the numeric App ID, not the Iv... client id.
# github_runners_app_id              = "<numeric app id>"
# github_runners_app_installation_id = "<installation id>"
# Fallback when unset: a PAT via TF_VAR_github_runners_token. PATs expire,
# and an expired one silently stops all runner scale-up.

tags = {
  managed_by = "terraform"
  component  = "cicd-bootstrap"
  customer   = "contoso"
}
