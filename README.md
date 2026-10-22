# Customer bootstrap

The bootstrap is the first thing an operator runs to onboard a new customer. It
is the equivalent of the Azure Landing Zone accelerator's bootstrap phase,
built as reusable Terraform. It runs once per customer, from a workstation,
against the customer tenant, and stands up everything the customer's
infrastructure-live repository needs before any pipeline can run.
It serves platform customers only: workload infrastructure goes into the live
repository as units, never into bootstrap inputs.

The docs site holds the procedure and the full reference. This README keeps
the operator detail the site does not cover.

- [Bootstrap a customer](https://docs.nrit.cloud/setup/bootstrap/): the
  procedure, GitHub auth, and the runner image.
- [Bootstrap reference](https://docs.nrit.cloud/setup/bootstrap-reference/):
  every resource, input, and output.
- [Secrets and variables](https://docs.nrit.cloud/setup/secrets-and-variables/):
  what the customer repository reads and who sets it.
- [License](https://docs.nrit.cloud/operations/license/): `TFPR_LICENSE`,
  `TFPR_ENTITLEMENT`, and the license states.

## What it creates

| File | What |
|---|---|
| `state.tf` | The customer's state account: Entra ID only, versioning, 30-day soft delete, point-in-time restore, a CanNotDelete lock, and optional audit logs |
| `identity.tf` | The plan (Reader) and apply (Owner) identities at `management_group_scope_id`, federated to the `plan` and `apply` environments |
| `github.tf` | The customer repository from the template, its variables, secrets, environments, Actions allow-list, secret scanning, and merge-gate ruleset, plus `live/customer.hcl` and `.github/CODEOWNERS` written once |
| `runners.tf`, `runner-image.tf`, `state-private-endpoint.tf` | Self-hosted runners and private state access, on `self_hosted_private` only |

Both identities have Storage Blob Data Contributor on the state container. The
plan identity needs write for a unit that has never been applied, because
`terraform init` creates that unit's state blob; a read-only plan identity
fails every pull request that adds a unit. The plan side
still runs without the state lease on callers at engine v10.2.0 or later.
Details are in
[What it creates](https://docs.nrit.cloud/setup/bootstrap-reference/#what-it-creates).

## Operator values

Real customer tfvars live in a private repository that the MSP owns, never in
this one. Copy `customers/_example.tfvars` there. Pass the file's path to
`scripts/onboard.sh -f` and to `terraform plan -var-file`. A relative or
absolute path both work.

## Running it

### Workstation

The scripts are bash and need `az`, `gh`, `jq`, `terraform`, `curl` and
`python3` on the path. macOS and Linux run them as they are. On Windows use
one of:

- **The dev container** in `.devcontainer/`, with VS Code and Docker Desktop.
  It carries the pinned toolchain and mounts the parent folder, so a sibling
  operator repo (`../<msp>-operator/customers/<customer>.tfvars`) is reachable
  as on a workstation. Port 8787 is forwarded for `scripts/create-github-app.sh`.
  The container home is not persistent: write App keys (`-k`) to a path under
  the mounted folder that the operator repo ignores, not to `~`.
- **WSL** (Ubuntu) with the same tools installed. Works like Linux.

Git Bash runs `create-backend.sh` and `onboard.sh` but is not supported:
`chmod 600` does nothing on NTFS, so the App key is not protected, and the
Windows `az` wrapper can mangle path arguments. PowerShell and cmd do not run
the scripts.

Follow [Run it](https://docs.nrit.cloud/setup/bootstrap/#run-it). In short:
`scripts/create-backend.sh`, the `terraform init` it prints, then
`scripts/onboard.sh`.

One clone serves every customer, but the init holds one backend at a time.
Before switching customers, re-run `scripts/create-backend.sh` with the other
tfvars and its `terraform init -reconfigure`, or keep a `TF_DATA_DIR` per
customer. `scripts/onboard.sh` refuses to plan against the wrong one.

### onboard.sh

`scripts/onboard.sh` gets the entitlement and runs the bootstrap:

```sh
scripts/onboard.sh -f ../<msp>-operator/customers/<customer>.tfvars   # add --yes for automation
```

1. Reads `tfpr_license` from the tfvars (required) and stops if the signed
   revocation list at `https://license.nrit.cloud/revocations.jws` lists it.
2. Keeps a `tfpr_entitlement` already in the tfvars when it names this
   tenant, organization and MSP and is not revoked. Otherwise it gets a
   token for the licensing portal with
   `az account get-access-token --tenant <msp_tenant_id>` and takes the
   customer's live entitlement from the portal API, or issues one. Without a
   token it prints the `az login` command, or takes an entitlement pasted from
   the portal page. It writes the entitlement into the tfvars; commit it to
   the private repository.
3. Runs `terraform plan`, asks y/N, and applies that plan. A plan with no
   changes skips straight to the check. It first stops when the initialised
   backend is another customer's bootstrap state account.
4. Checks that both repository variables hold the expected values and that
   the revocation list names neither token.

`msp_tenant_id` is the MSP's Entra tenant, where the operator holds the
portal's `Entitlement.Issuer` role. Null means the customer tenant, which is
right when the MSP runs its own landing zone. The script needs the same
environment as a manual plan (the App keys, see
[GitHub auth](#github-auth)) and an initialised backend.

A repository where the variables were set by hand lists them in
`adopt_tfpr_variables`, so the first plan imports them instead of failing to
create them.

## Runner image mode switch

The default imports the prebuilt image by digest; `runner_image_commit`
switches to the build-from-source fallback (see
[The runner image](https://docs.nrit.cloud/setup/bootstrap/#the-runner-image)).

Moving between the two is a tfvars change (set or unset
`runner_image_commit`) plus a `-target='module.runners'` apply with the
`runner-image.tf` resources targeted alongside; Terraform swaps the registry
and repoints the job. The knobs are mutually exclusive by design:
`runner_image_commit` set wins and the import pins are ignored.

Known migration hiccup: the Container App Job PUT validates the image pull
server-side, and on a mode switch the job update races the creation of the
registry's private DNS zone and endpoint (the zone can also collide with
the module's not-yet-destroyed old zone), so the update can fail with
"unable to pull image using Managed identity". Re-run the same apply until
clean; each pass completes more of the chain and the job update succeeds
once the endpoint resolves. A fresh onboarding does not hit this, because
the Container Apps environment creation gives the endpoint a ten-minute
head start. Note the old registry is destroyed before the job repoints, so
finish the re-applies promptly: until then a queued workflow job cannot
pull.

## GitHub auth

The `github` provider authenticates as the bootstrap GitHub App when
`github_app_id` is set, and with the PAT in `GITHUB_TOKEN` otherwise. App
creation is on
[Onboard as an MSP](https://docs.nrit.cloud/setup/msp-onboarding/#3-create-the-bootstrap-app)
and the token table in
[Before you start](https://docs.nrit.cloud/setup/bootstrap/#github).

`scripts/create-github-app.sh` creates both Apps private from a manifest. The
bootstrap App is one private App per MSP, installable only on the MSP's own
organization. The checks App is one per organization.

The bootstrap App needs no organization Variables permission, because the
license variables are repository variables.

## Known permadiff: do not apply the ACR bypass revert (build-from-source fallback only)

Only on the build-from-source fallback (`runner_image_commit` set); the
default import path has no module-owned registry and no build task, so this
permadiff does not appear there.

Every plan shows `azurerm_container_registry.this` wanting to set
`network_rule_bypass_for_tasks_enabled = true -> false`. That flag is owned by
an `azapi_update_resource` patch inside the AVM runners module; the wrapped
`azurerm` resource does not know about it and tries to revert it. Applying the
revert breaks the next runner-image build (the registry is private and the
build task needs the bypass), and the azapi patch does not self-heal on drift.
If it is ever applied by accident, restore it with:

```sh
az rest --method patch \
  --url "https://management.azure.com/<acr-resource-id>?api-version=2025-05-01-preview" \
  --body '{"properties":{"networkRuleBypassAllowedForTasks":true}}'
```

## Known issue: disabling nat_gateway_enabled on an existing deployment

The AVM runners module (0.6.x) does not support turning its NAT gateway off
cleanly. With `nat_gateway_creation_enabled = false` and no
`nat_gateway_id`, it renders `natGateway = { id = null }` into the container
app subnet, which ARM rejects ("Expecting a string. Actual value is Null"),
and Terraform drops the subnet-to-gateway dependency edge, so the gateway
delete races the subnet update and fails with
`CannotDeleteNatGatewayAssociatedToSubnet`.

Disable procedure that works:

1. Detach out of band: `az network vnet subnet update ... --remove natGateway`.
2. Targeted apply with narrow targets only, so the ACR registry and build
   task stay out of the graph:
   `-target='module.runners[0].module.virtual_network[0].module.subnet["container_app"]' -target='azurerm_public_ip.runner_egress' -target='azurerm_storage_account_network_rules.state'`
   (the orphaned NAT gateway and IP destroys ride along automatically).
3. The subnet update still fails on the null id. Fix state by hand:
   `terraform state pull`, set the container app subnet's
   `body.value.properties.natGateway.id` to `null`, bump the serial,
   `terraform state push`. Plans are clean afterwards.
4. Smoke test: dispatch `drift.yml` on the customer repo and confirm the
   runner picks it up. Egress works without the gateway because Container
   Apps workload-profile environments have their own managed egress, even
   with `defaultOutboundAccess = false` on the subnet.

Any genuine change to the container app subnet keeps failing on the null id
until the module is fixed upstream. Rollback at any point: set the variable
back to `true` and run the same targeted apply.

## Scope on an existing hierarchy

A live tree whose `tenant_root_id` is the tenant id creates `alz` directly
under the tenant root group. Scope the identities to that group once it
exists:

```hcl
management_group_scope_id = "/providers/Microsoft.Management/managementGroups/alz"
```

Everything the pipeline applies sits at or below `alz`: the foundation units,
policy, the platform and landing-zone subscriptions. Two things stay outside
and are operator actions with tenant-root rights (elevate in the portal, do
the step, remove the elevation):

- creating `alz` on a bare tenant before the first foundation apply, with
  `az account management-group create --name alz --display-name "Azure Landing Zones"`;
- re-parenting or recreating `alz`.

Azure gives the identity that creates a management group Owner on it. If the
apply identity created `alz` and the groups below it, it holds unmanaged Owner
assignments there. When the bootstrap moves its own Owner assignment from the
tenant root to `alz`, delete the unmanaged one at `alz` first, or the create
fails with `RoleAssignmentExists`:

```sh
az role assignment list --assignee <apply principal id> \
  --scope /providers/Microsoft.Management/managementGroups/alz --query "[].id" -o tsv
az role assignment delete --ids <that id>
```

The ones on groups below `alz` are redundant with Owner at `alz` and can go
the same way.

## Working on this repository

Install the hooks once with `pre-commit install` (`mise install` gives you
the pinned `terraform` and `pre-commit`). They format Terraform, refuse
private key blocks and any file named `tfplan*`, and run again on every pull
request in `.github/workflows/pr-checks.yml`. Write plans to `$TMPDIR`, never
into the repository: a plan file embeds the full state, including every secret
the bootstrap writes.
