# Providers for the customer bootstrap.
#
# This is the most primitive layer: it runs once per customer, by an MSP
# operator, against the customer tenant. It uses local state by default
# (see README). No backend is configured here on purpose.
#
# The github provider authenticates as the bootstrap GitHub App when
# github_app_id is set (app_auth), and with the GITHUB_TOKEN environment
# variable (or TF_VAR_github_token) otherwise. Neither the App key nor the
# token is ever placed in a tfvars file.
#
# State lives in a dedicated, IP-locked storage account owned by
# scripts/create-backend.sh, not by this config. The account, resource group,
# container, and key are supplied at init via -backend-config (backend blocks
# cannot use variables). See README, "Running it". Run the script first.

terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id     = var.management_subscription_id
  storage_use_azuread = true
  features {}
}

provider "azapi" {
  subscription_id = var.management_subscription_id
}

provider "github" {
  owner = var.github_organization
  token = var.github_token

  # The provider prefers a complete app_auth over the token.
  dynamic "app_auth" {
    for_each = var.github_app_id == null ? [] : [1]
    content {
      id              = var.github_app_id
      installation_id = var.github_app_installation_id
      pem_file        = local.github_app_private_key
    }
  }
}

provider "http" {}
