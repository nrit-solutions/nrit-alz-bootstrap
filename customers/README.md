# Customer bootstrap inputs

This folder holds only `_example.tfvars`, the template for a customer's
bootstrap inputs. Operators keep real customer tfvars outside this repository,
in one private repository per MSP. Pass the file's path, relative or absolute,
to `scripts/onboard.sh -f` and to `terraform plan -var-file`. `.gitignore`
keeps any other tfvars in this folder out of commits.

A tfvars file holds identifiers, names, the path to the bootstrap App's
private key, and the signed tfpr license and entitlement (`tfpr_license`,
`tfpr_entitlement`), which are not secrets. No key or PAT is ever stored in
it. The github provider authenticates as the bootstrap App (`github_app_id`,
`github_app_installation_id`, `github_app_pem_file`) or, when those are unset,
with the PAT in the `GITHUB_TOKEN` environment variable.

To onboard a new customer, copy `_example.tfvars` into the MSP's private
repository as `<customer>.tfvars` and follow
[Bootstrap a customer](https://docs.nrit.cloud/setup/bootstrap/). Every input
is in the
[Bootstrap reference](https://docs.nrit.cloud/setup/bootstrap-reference/#variables).
