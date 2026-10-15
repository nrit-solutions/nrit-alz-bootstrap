# Self-hosted runners (production posture).
#
# When network_posture is self_hosted_private, the state account is default-deny
# (see state.tf) and deployments must run from inside the customer network. This
# wraps the first-party AVM module Azure/avm-ptn-cicd-agents-and-runners (0.6.0),
# which creates a standalone bootstrap virtual network, registry, and runners
# with their own NAT gateway egress. The network is independent of the landing
# zone connectivity stack, so there is no circular dependency at onboarding; it
# can be peered to the hub later if runners must reach private workload resources.
#
# Cost: the default runner_compute_type is azure_container_app, Container App
# Jobs that scale to zero when idle, so you pay only while a deploy runs.
# container_app_max_execution_count caps concurrency (default 1); raising it is
# cost-neutral because the job scales to zero. azure_container_instance is the
# always-on alternative, sized by container_instance_count (a standing cost).

# Container Apps needs the Microsoft.App resource provider registered. Harmless
# if it already is.
resource "azapi_resource_action" "register_container_apps" {
  count       = local.use_private_networking && var.runner_compute_type == "azure_container_app" ? 1 : 0
  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = "/subscriptions/${var.management_subscription_id}"
  action      = "providers/Microsoft.App/register"
  method      = "POST"
}

# Dedicated resource group for the runner network and, when nat_gateway_enabled,
# the egress IP we own. The runner module deploys into this same group
# (resource_group_creation_enabled = false, parent_id below), so the IP and the
# NAT gateway it attaches to live together, instead of the IP being parked in
# the identity group.
resource "azurerm_resource_group" "runners" {
  count    = local.use_private_networking ? 1 : 0
  name     = local.resource_group_runners
  location = var.location
  tags     = var.tags
}

# We own the egress public IP so the state firewall can allow exactly the
# runner's outbound address; the module attaches it to the NAT gateway it
# creates. Both are optional: without them egress rides the Container Apps
# managed path with a dynamic IP. Note the state firewall IP rule is moot for
# same-region traffic anyway (Azure bypasses IP rules there); the private
# endpoints carry that traffic.
resource "azurerm_public_ip" "runner_egress" {
  count               = local.use_private_networking && var.nat_gateway_enabled ? 1 : 0
  name                = "pip-cicd-runners-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

module "runners" {
  count   = local.use_private_networking ? 1 : 0
  source  = "Azure/avm-ptn-cicd-agents-and-runners/azurerm"
  version = "0.6.0"

  location = var.location
  postfix  = "runner-${var.location_short}"
  tags     = var.tags

  # Bring our own resource group (created above) so the egress IP and the runner
  # network share one group, and the resources are named from the clean postfix
  # rather than the module default group rg-<postfix>.
  resource_group_creation_enabled = false
  parent_id                       = azurerm_resource_group.runners[0].id

  # GitHub, repo-scoped runners. Default auth is the runners GitHub App: the
  # KEDA scaler and the runner registration mint short-lived installation
  # tokens from the App key, so no expiring PAT lives in the tenant (a PAT
  # expiry silently stops all scale-up; see the 2026-08-23 changelog entry).
  # Leaving github_runners_app_id null falls back to the PAT path.
  version_control_system_type                  = "github"
  version_control_system_organization          = var.github_organization
  version_control_system_repository            = github_repository.live.name
  version_control_system_runner_scope          = "repo"
  version_control_system_authentication_method = local.runners_use_app ? "github_app" : "pat"
  version_control_system_personal_access_token = local.runners_use_app ? null : try(coalesce(var.github_runners_token, var.github_token), null)

  version_control_system_github_application_id              = local.runners_use_app ? var.github_runners_app_id : ""
  version_control_system_github_application_installation_id = local.runners_use_app ? var.github_runners_app_installation_id : ""
  version_control_system_github_application_key             = local.runners_use_app ? var.github_runners_app_private_key : null

  # Compute. azure_container_app scales to zero when idle (the cost-optimal
  # default); azure_container_instance is always-on. Inputs for the unused
  # compute type are ignored by the module.
  compute_types = [var.runner_compute_type]

  container_app_min_execution_count      = 0
  container_app_max_execution_count      = var.container_app_max_execution_count
  container_app_replica_timeout          = var.container_app_replica_timeout
  container_app_polling_interval_seconds = var.container_app_polling_interval_seconds
  container_app_container_cpu            = var.container_app_container_cpu
  container_app_container_memory         = var.container_app_container_memory

  container_instance_count                  = var.container_instance_count
  container_instance_use_availability_zones = false

  # Runner image. Default: the prebuilt signed image, imported by digest into
  # the bootstrap-owned registry (runner-image.tf); the module then only
  # grants AcrPull to the runner identity and points the job at the digest,
  # and the job pulls with that identity because no registry password is set.
  # Fallback: runner_image_commit builds from source with a module-owned ACR
  # and build task; the task clones the private context repo with github_token
  # (override via runner_image_context_token), and a commit SHA (not a branch)
  # keeps the image tag content-addressed so a Dockerfile change redeploys the
  # job. The task/dockerfile/context values on the import path are dead: the
  # variable type requires them, but with no module registry no task exists.
  use_default_container_image                          = false
  container_registry_creation_enabled                  = local.runner_image_from_source
  container_registry_private_dns_zone_creation_enabled = local.runner_image_from_source
  # Built from the registry's config-echoed attributes, not its id: the
  # module's AcrPull count needs the value plan-time known, and a plain
  # string carries no dependency edge, which let the role-assignment PUT
  # race the registry creation and 404.
  custom_container_registry_id           = local.runner_image_from_source ? null : "/subscriptions/${var.management_subscription_id}/resourceGroups/${azurerm_container_registry.runner[0].resource_group_name}/providers/Microsoft.ContainerRegistry/registries/${azurerm_container_registry.runner[0].name}"
  custom_container_registry_login_server = local.runner_image_from_source ? null : "${azurerm_container_registry.runner[0].name}.azurecr.io"
  custom_container_registry_images = local.runner_image_from_source ? {
    container_app = {
      task_name            = "github-container-app-image-build-task"
      dockerfile_path      = "Dockerfile"
      context_path         = "https://github.com/nrit-solutions/nrit-alz-bootstrap#${var.runner_image_commit}:runner-image/github-runner-aca"
      context_access_token = coalesce(var.runner_image_context_token, var.github_token)
      image_names          = ["github-runner:alz-${substr(var.runner_image_commit, 0, 7)}"]
    }
    } : {
    container_app = {
      task_name            = "none"
      dockerfile_path      = "none"
      context_path         = "none"
      context_access_token = null
      image_names          = ["alz-runner@${var.runner_image_digest}"]
    }
  }
  # Nothing builds on the import path, so skip the post-build settle delay.
  delays = local.runner_image_from_source ? {} : { delay_after_container_image_build = 0 }

  # Standalone private bootstrap network, single zone for cost. With
  # nat_gateway_enabled our egress IP sits on the NAT gateway; without it the
  # environment's managed egress is used (dynamic IP).
  use_private_networking        = true
  use_zone_redundancy           = false
  virtual_network_address_space = var.runner_vnet_address_space
  nat_gateway_creation_enabled  = var.nat_gateway_enabled
  public_ip_creation_enabled    = false
  public_ip_id                  = var.nat_gateway_enabled ? azurerm_public_ip.runner_egress[0].id : null

  # Keep this list to resources that never change after creation: a
  # module-level dependency on a changed resource defers every data source in
  # the module to apply time, and the then-unknown resource group id forces a
  # vnet replacement. So no image import here (nothing pulls it until a job
  # runs), and nothing that follows the repository: the name reference above
  # already orders the runners after the repository, and a repository replace
  # must not rebuild the runner network.
  depends_on = [
    azapi_resource_action.register_container_apps,
  ]
}
