# Changelog

Operator changelog. This repository has no releases: a change takes effect
when an operator runs `terraform apply` against a customer's state. Every entry
therefore states whether it needs a manual apply, and with which targets, var
file, and environment. `[Unreleased]` holds merged changes. A dated section
marks when its changes were applied. Tenants may lag, so check the plan, not
this file, for a tenant's actual state.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `SECURITY.md` names private vulnerability reporting on this repository as
  the route for security problems, with scope and response times. No apply
  needed.

### Changed

- The PR checks workflow pins `jdx/mise-action` by full commit SHA, like its
  other actions, so the repository can require SHA-pinned actions. No apply
  needed.
- `scripts/onboard.sh` stops before the plan when the customer repository
  already exists on GitHub but is not in the bootstrap state, for example one
  made with "Use this template". It names the fix (delete it or pick another
  `customer_repository_name`) instead of failing the apply on a name clash.
  Re-runs for an onboarded customer are unaffected. `github.tf` comments name
  the `tfpr / merge-gate` check. No apply needed.
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

## [2026-10-22]

### Changed

- The engine is renamed to tfpr, and every consumer runs tfpr v12. The
  `required_status_checks` default is `["tfpr / merge-gate"]`, and the
  `allowed_actions` default drops the `nrit-solutions/tf-pr-ops` entries.
  `scripts/create-github-app.sh` names a new checks App `tfpr-<org>` by
  default. A customer whose tfvars sets `required_status_checks` explicitly
  changes it after its engine bump, per the v12 release notes. Applied per
  customer, after its callers ran v12:
  `terraform apply -var-file=<customer>.tfvars -target=github_actions_repository_permissions.live -target='github_repository_ruleset.require_approved_pr'`.
- The `allowed_actions` default also allows `nrit-solutions/tfpr@*` and
  `nrit-solutions/tfpr/*`, next to the current `tf-pr-ops` entries. The engine
  is being renamed to `tfpr`, and a consumer can only move to the renamed
  entrypoint once its repository allows it. Additive: the `tf-pr-ops` entries
  stay until every consumer has moved. Applied per customer with:
  `terraform apply -var-file=<customer>.tfvars -target=github_actions_repository_permissions.live`.
