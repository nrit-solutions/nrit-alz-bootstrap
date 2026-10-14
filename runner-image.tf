# Runner image: import the prebuilt signed image into an in-tenant registry.
#
# Default path for self_hosted_private. NRIT builds, scans, signs, and
# publishes the runner image once (nrit-alz-runner-image ->
# ghcr.io/nrit-solutions/alz-runner); the bootstrap imports the pinned digest
# into a small bootstrap-owned ACR with the server-side importImage action.
# No docker, no GitHub token, and no cross-tenant PAT stored in the customer
# tenant. The Container App Job pulls from this registry over a private
# endpoint, so the posture keeps private-endpoint pulls and no public runtime
# dependency. Setting runner_image_commit switches to the build-from-source
# fallback (module-owned ACR with build tasks) and disables this whole file.

resource "azurerm_container_registry" "runner" {
  count               = local.runner_image_import ? 1 : 0
  name                = local.runner_registry_name
  resource_group_name = azurerm_resource_group.runners[0].name
  location            = var.location
  sku                 = "Premium" # private endpoints need Premium
  admin_enabled       = false
  tags                = var.tags

  public_network_access_enabled = false
  # Trusted-services bypass: importImage must reach the registry while public
  # access is disabled.
  network_rule_bypass_option = "AzureServices"
}

# Server-side copy from public GHCR: anonymous, and the manifest digest
# survives the import bit-identical, so the job's digest reference points at
# exactly the signed artifact. A digest or version bump changes the body,
# which recreates the action and re-runs the import; Force overwrites the
# version tag if it already exists.
resource "azapi_resource_action" "import_runner_image" {
  count       = local.runner_image_import ? 1 : 0
  type        = "Microsoft.ContainerRegistry/registries@2023-07-01"
  resource_id = azurerm_container_registry.runner[0].id
  action      = "importImage"
  method      = "POST"
  body = {
    source = {
      registryUri = local.runner_image_registry_uri
      sourceImage = "${local.runner_image_repository_path}@${var.runner_image_digest}"
    }
    targetTags = ["alz-runner:${var.runner_image_version}"]
    mode       = "Force"
  }
}

# On this path the runner module still carves its registry private-endpoint
# subnet, but its own registry, endpoint, and privatelink.azurecr.io zone are
# disabled, so the bootstrap owns them: the same pattern as the state
# endpoints. The endpoint lands after the module in the same apply; that is
# fine because nothing pulls the image until a workflow job runs (the
# module's pull-at-create placeholder job is Azure DevOps-only).

resource "azurerm_private_dns_zone" "runner_registry" {
  count               = local.runner_image_import ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.runners[0].name
  tags                = var.tags

  # No depends_on on the module: the job update validates the image pull and
  # needs this zone resolvable, so ordering the zone after the module
  # deadlocks. On a mode switch this create can collide with the module's
  # not-yet-destroyed zone of the same name, and the job update can race the
  # endpoint below; both converge on re-running the same apply (see the
  # README's migration note).
}

resource "azurerm_private_dns_zone_virtual_network_link" "runner_registry" {
  count                 = local.runner_image_import ? 1 : 0
  name                  = "pdnsl-runner-acr-${var.location_short}"
  resource_group_name   = azurerm_resource_group.runners[0].name
  private_dns_zone_name = azurerm_private_dns_zone.runner_registry[0].name
  virtual_network_id    = module.runners[0].virtual_network_resource_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "runner_registry" {
  count               = local.runner_image_import ? 1 : 0
  name                = "pe-runner-acr-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  location            = var.location
  subnet_id           = module.runners[0].private_dns_zone_subnet_resource_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-runner-acr"
    private_connection_resource_id = azurerm_container_registry.runner[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "registry"
    private_dns_zone_ids = [azurerm_private_dns_zone.runner_registry[0].id]
  }
}
