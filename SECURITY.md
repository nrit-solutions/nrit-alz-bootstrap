# Security

## Reporting a vulnerability

Report a vulnerability in this repository privately, through its
**Security** tab: choose **Report a vulnerability**. Do not open a public
issue or pull request for it.

Licensed operators can also report through the support channel named in
their license agreement.

Include the commit or release, the affected file or script, the steps to
reproduce and the impact you expect. Leave out real credentials, tfvars,
state and plan output.

## Scope

- The Terraform in this repository: the GitHub organization and repository
  settings, the identities and role assignments, the state storage and the
  runners
- The scripts under `scripts/` and the runner image definition

Vulnerabilities in the PR-ops engine belong with the engine: report them on
`nrit-solutions/tfpr`. Problems in a customer repository created by this
bootstrap belong with the operator of that repository.

## What happens next

The report is acknowledged within one business day. A vulnerability rated
critical is fixed within ten business days of confirming it, and other
fixes ship in the next release.
