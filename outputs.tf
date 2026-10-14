output "state_resource_group_name" {
  description = "Resource group holding the state storage account."
  value       = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  description = "State storage account name. Set as the BACKEND_AZURE_STORAGE_ACCOUNT_NAME Action variable."
  value       = azurerm_storage_account.state.name
}

output "state_container_name" {
  description = "State container name."
  value       = local.state_container_name
}

output "plan_identity_client_id" {
  description = "Client id of the plan identity. Set as AZURE_CLIENT_ID in the plan environment."
  value       = azurerm_user_assigned_identity.cicd["plan"].client_id
}

output "apply_identity_client_id" {
  description = "Client id of the apply identity. Set as AZURE_CLIENT_ID in the apply environment."
  value       = azurerm_user_assigned_identity.cicd["apply"].client_id
}

output "plan_identity_principal_id" {
  description = "Object id of the plan identity, for role assignment auditing."
  value       = azurerm_user_assigned_identity.cicd["plan"].principal_id
}

output "apply_identity_principal_id" {
  description = "Object id of the apply identity, for role assignment auditing."
  value       = azurerm_user_assigned_identity.cicd["apply"].principal_id
}

output "repository_full_name" {
  description = "The generated customer infrastructure-live repository."
  value       = github_repository.live.full_name
}

output "repository_html_url" {
  description = "URL of the generated customer repository."
  value       = github_repository.live.html_url
}

output "runner_egress_ip" {
  description = "Public egress IP of the self-hosted runners (self_hosted_private only). Allowlisted on the state account firewall. Null for github_hosted."
  value       = try(azurerm_public_ip.runner_egress[0].ip_address, null)
}

output "runner_image" {
  description = "Runner image the Container App Job runs: the in-tenant registry path with the version tag and pinned digest. Answers which runner image version this customer runs. Null unless self_hosted_private on the default import path."
  value       = try("${azurerm_container_registry.runner[0].login_server}/alz-runner:${var.runner_image_version}@${var.runner_image_digest}", null)
}
