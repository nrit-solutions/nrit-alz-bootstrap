# Changelog

Operator changelog. This repository has no releases: a change takes effect
when an operator runs `terraform apply` against a customer's state. Every entry
therefore states whether it needs a manual apply, and with which targets, var
file, and environment. `[Unreleased]` holds merged changes. A dated section
marks when its changes were applied. Tenants may lag, so check the plan, not
this file, for a tenant's actual state.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Neutral wording where the MSP reads it: the build-from-source runner image is
  tagged `github-runner:alz-<sha>` instead of `nrit-<sha>`, the Dockerfile
  marker is `# Platform additions`, and the README, `runner-image.tf` and the
  dev container no longer name NRIT. The tag change only affects the
  build-from-source fallback; the default digest import is untouched.
- Generated `live/customer.hcl` and `.github/CODEOWNERS` say "written once by
  the bootstrap", and comments, variable descriptions and the example tfvars
  no longer cite private repositories or issues. The runner image pin points
  at the public versions page. No apply needed: both files are written once
  and the bootstrap ignores later content changes, so existing repositories
  see no diff.

### Fixed

- The plan identity is back on Storage Blob Data Contributor on the state
  container. With Storage Blob Data Reader (since 2026-10-12) every pull
  request that adds a unit failed at `terraform init`, because init creates
  the state blob of a unit that has never been applied. Needs a targeted
  apply per customer, no keys required:
  `terraform apply -var-file=<tfvars> -target='azurerm_role_assignment.state_blob["plan"]'`.
  Expect one role assignment replaced. The replacement deletes a role
  assignment under the locked state resource group, so lift the lock first
  and put it back after: `az lock delete -n state-cannot-delete -g
  rg-cicd-state-<region>`, the targeted apply, then
  `terraform apply -var-file=<tfvars> -target=azurerm_management_lock.state`.

### Added

- A dev container (`.devcontainer/`) with the pinned toolchain for operators
  on Windows, and a Workstation section in the README that states what the
  scripts need and which Windows setups work. No apply needed.
- This repository was published on 2026-10-14 from the private operator
  repository. It carries no earlier history. No apply needed.
