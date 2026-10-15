# Changelog

Operator changelog. This repository has no releases: a change takes effect
when an operator runs `terraform apply` against a customer's state. Every entry
therefore states whether it needs a manual apply, and with which targets, var
file, and environment. `[Unreleased]` holds merged changes. A dated section
marks when its changes were applied. Tenants may lag, so check the plan, not
this file, for a tenant's actual state.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- The plan identity is back on Storage Blob Data Contributor on the state
  container. With Storage Blob Data Reader (2026-10-12, nrit-tf-pr-ops#413)
  every pull request that adds a unit failed at `terraform init`, because
  init creates the state blob of a unit that has never been applied
  (nrit-tf-pr-ops#429). Needs a targeted apply per customer, no keys required:
  `terraform apply -var-file=<tfvars> -target='azurerm_role_assignment.state_blob["plan"]'`.
  Expect one role assignment replaced. The replacement deletes a role
  assignment under the locked state resource group, so lift the lock first
  and put it back after: `az lock delete -n state-cannot-delete -g
  rg-cicd-state-<region>`, the targeted apply, then
  `terraform apply -var-file=<tfvars> -target=azurerm_management_lock.state`.
  Applied to nrit and the sandbox on 2026-10-15.

### Added

- A dev container (`.devcontainer/`) with the pinned toolchain for operators
  on Windows, and a Workstation section in the README that states what the
  scripts need and which Windows setups work. No apply needed.
- This repository was published on 2026-10-14 from the private operator
  repository. It carries no earlier history. No apply needed.
