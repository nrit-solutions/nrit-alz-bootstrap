# Terraform state backend for the customer.
#
# One storage account holds the state for every unit in the customer's
# infrastructure-live repository. Units are isolated by blob key
# (path_relative_to_include in root.hcl), not by separate accounts. Access is
# Entra ID only: shared keys are disabled, so the container is created through
# the ARM control plane (azapi) rather than the data plane.

resource "azurerm_resource_group" "state" {
  name     = local.resource_group_state
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "state" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.state.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  # Always reachable at the network layer; access is then gated by Entra ID
  # auth and, for self_hosted_private, the default-deny firewall below.
  public_network_access_enabled = true
  tags                          = var.tags

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }

    # Point-in-time restore of the whole container; needs versioning, change
    # feed and a soft-delete window longer than the restore window.
    restore_policy {
      days = 29
    }
  }
}

# Deleting the resource group or the account loses every unit's state.
resource "azurerm_management_lock" "state" {
  name       = "state-cannot-delete"
  scope      = azurerm_resource_group.state.id
  lock_level = "CanNotDelete"
  notes      = "Holds the Terraform state of every unit in the customer repository."
}

# Data-plane logs for state and the unit-lock table, so a rewrite or delete is
# on record. The workspace is created by the customer repository, so set
# state_diagnostics_workspace_id after the first live apply.
resource "azurerm_monitor_diagnostic_setting" "state" {
  for_each = var.state_diagnostics_workspace_id == null ? {} : {
    blob  = "${azurerm_storage_account.state.id}/blobServices/default"
    table = "${azurerm_storage_account.state.id}/tableServices/default"
  }
  name                       = "state-${each.key}"
  target_resource_id         = each.value
  log_analytics_workspace_id = var.state_diagnostics_workspace_id

  enabled_log {
    category_group = "audit"
  }
}

# For self_hosted_private the data plane is default-deny, allowing only the
# runner's egress IP (the public IP we own and attach to the runner NAT
# gateway, see runners.tf) and, optionally, the operator IP for the first
# bootstrap. The control plane (used below to create the container, and by role
# assignments) is not affected by these rules.
resource "azurerm_storage_account_network_rules" "state" {
  count              = local.use_private_networking ? 1 : 0
  storage_account_id = azurerm_storage_account.state.id
  default_action     = "Deny"
  bypass             = ["AzureServices"]
  ip_rules = compact(concat(
    azurerm_public_ip.runner_egress[*].ip_address,
    var.allow_state_access_from_my_ip ? [chomp(data.http.operator_ip[0].response_body)] : [],
  ))
}

data "http" "operator_ip" {
  count = local.use_private_networking && var.allow_state_access_from_my_ip ? 1 : 0
  url   = "https://api.ipify.org"
}

# The blob service id is a fixed string under the account. A data source here
# would become unknown whenever the account has a pending update, and an
# unknown parent_id forces replacement of the container, which holds every
# unit's state.
resource "azapi_resource" "state_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  parent_id = "${azurerm_storage_account.state.id}/blobServices/default"
  name      = local.state_container_name

  body = {
    properties = {
      publicAccess = "None"
    }
  }

  schema_validation_enabled = false
  depends_on                = [azurerm_storage_account_network_rules.state]
}

# The apply identity writes state and takes the state lease. The plan identity
# only reads it: the engine plans with -lock=false since tf-pr-ops v10.2.0, so
# PR-authored code on the plan side cannot rewrite or delete any unit's state.
resource "azurerm_role_assignment" "state_blob" {
  for_each             = azurerm_user_assigned_identity.cicd
  scope                = azapi_resource.state_container.id
  role_definition_name = each.key == "apply" ? "Storage Blob Data Contributor" : "Storage Blob Data Reader"
  principal_id         = each.value.principal_id
}

# Both identities can use the tf-pr-ops cross-PR unit lock table (tfprlocks).
# Account scope: the engine creates the table on first use, so no narrower
# scope exists at assignment time.
resource "azurerm_role_assignment" "state_table" {
  for_each             = azurerm_user_assigned_identity.cicd
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = each.value.principal_id
}
