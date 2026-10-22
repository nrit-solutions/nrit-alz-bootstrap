# Private access to the state account from the self-hosted runners.
#
# self_hosted_private deploys runners into a private vnet. Rather than have them
# egress through the NAT gateway to the state account's public endpoint (allowed
# by an IP firewall rule), they reach it over the vnet through a private
# endpoint. This is the proper private path: it does not depend on the runner's
# outbound IP (Azure Container Instances do not reliably egress via a subnet NAT
# gateway), and state traffic never touches the public endpoint.
#
# The runner module exposes its vnet and private-endpoint subnet, so the endpoint
# drops straight into the network it already built (alongside the ACR endpoint).

resource "azurerm_private_dns_zone" "state_blob" {
  count               = local.use_private_networking ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.runners[0].name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "state_blob" {
  count                 = local.use_private_networking ? 1 : 0
  name                  = "pdnsl-state-blob-${var.location_short}"
  resource_group_name   = azurerm_resource_group.runners[0].name
  private_dns_zone_name = azurerm_private_dns_zone.state_blob[0].name
  virtual_network_id    = module.runners[0].virtual_network_resource_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "state_blob" {
  count               = local.use_private_networking ? 1 : 0
  name                = "pe-state-blob-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  location            = var.location
  subnet_id           = module.runners[0].private_dns_zone_subnet_resource_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-state-blob"
    private_connection_resource_id = azurerm_storage_account.state.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.state_blob[0].id]
  }
}

# The tfpr cross-PR unit lock table (tfprlocks) lives on the same account.
# Private endpoints are per-subresource, so the blob endpoint above does not
# cover the table service, and same-region traffic to the public table endpoint
# bypasses IP firewall rules. Mirror the blob path for table.
#
# The module's private-endpoint subnet is a /29 with no free IPs (ACR and blob
# endpoints), so this endpoint gets its own bootstrap-managed subnet. The
# prefix is derived from the same vnet address space the module carves up: the
# module takes the first /27 and the /29 at index 4 (offset 32), so index 5
# (offset 40) is the first free /29. Coupled to the module's internal layout;
# revisit if the runner module changes its subnetting.

resource "azurerm_subnet" "state_private_endpoints" {
  count                = local.use_private_networking ? 1 : 0
  name                 = "subnet-state-private-endpoint-runner-${var.location_short}"
  resource_group_name  = azurerm_resource_group.runners[0].name
  virtual_network_name = element(split("/", module.runners[0].virtual_network_resource_id), length(split("/", module.runners[0].virtual_network_resource_id)) - 1)
  address_prefixes     = [cidrsubnet(var.runner_vnet_address_space, 5, 5)]
}

resource "azurerm_private_dns_zone" "state_table" {
  count               = local.use_private_networking ? 1 : 0
  name                = "privatelink.table.core.windows.net"
  resource_group_name = azurerm_resource_group.runners[0].name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "state_table" {
  count                 = local.use_private_networking ? 1 : 0
  name                  = "pdnsl-state-table-${var.location_short}"
  resource_group_name   = azurerm_resource_group.runners[0].name
  private_dns_zone_name = azurerm_private_dns_zone.state_table[0].name
  virtual_network_id    = module.runners[0].virtual_network_resource_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "state_table" {
  count               = local.use_private_networking ? 1 : 0
  name                = "pe-state-table-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  location            = var.location
  subnet_id           = azurerm_subnet.state_private_endpoints[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-state-table"
    private_connection_resource_id = azurerm_storage_account.state.id
    subresource_names              = ["table"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "table"
    private_dns_zone_ids = [azurerm_private_dns_zone.state_table[0].id]
  }
}
