# Deploy identities and OIDC federation.
#
# Two user-assigned managed identities: plan (read) and apply (write). Each has
# a federated credential for its GitHub Actions environment, so no secrets are
# stored. The plan identity gets Reader and the apply identity gets Owner at the
# management group scope, because the foundation creates role assignments and
# policy.

resource "azurerm_resource_group" "identity" {
  name     = local.resource_group_identity
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "cicd" {
  for_each            = local.managed_identities
  name                = each.value
  resource_group_name = azurerm_resource_group.identity.name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "cicd" {
  for_each                  = local.federated_credentials
  name                      = "fc-${var.customer_name}-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.cicd[each.value.identity_key].id
  audience                  = [local.oidc_audience]
  issuer                    = local.github_issuer
  subject                   = each.value.subject
}

resource "azurerm_role_assignment" "plan_management_group" {
  scope                = local.management_group_scope_id
  role_definition_name = var.plan_role_definition_name
  principal_id         = azurerm_user_assigned_identity.cicd["plan"].principal_id
}

resource "azurerm_role_assignment" "apply_management_group" {
  scope                = local.management_group_scope_id
  role_definition_name = var.apply_role_definition_name
  principal_id         = azurerm_user_assigned_identity.cicd["apply"].principal_id
}
