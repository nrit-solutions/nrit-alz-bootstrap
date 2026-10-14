#!/usr/bin/env bash
# Onboard a customer: get the tfpr entitlement for its Azure tenant and GitHub
# organization, write it into the customer tfvars, then plan, confirm, apply,
# and check the result.
#
# Run it after scripts/create-backend.sh and the terraform init that script
# prints, with the same environment a manual plan needs (README, "Running it").
#
# The entitlement comes from the licensing portal API, signed in as the MSP
# operator with az. When no az token can be had, an entitlement copied from
# the portal page can be pasted instead.
#
# Usage:
#   scripts/onboard.sh -f ../<msp>-operator/customers/<customer>.tfvars [--yes]
set -euo pipefail

PORTAL_URL="${TFPR_PORTAL_URL:-https://portal.license.nrit.cloud}"
PORTAL_APP_ID="${TFPR_PORTAL_APP_ID:-782a7bd7-1431-49fe-ae88-7ad971d1ca2a}"
REVOCATIONS_URL="${TFPR_REVOCATIONS_URL:-https://license.nrit.cloud/revocations.jws}"

var_file=""
assume_yes=false

usage() {
  cat >&2 <<'EOF'
Get the tfpr entitlement for a customer, write TFPR_LICENSE and
TFPR_ENTITLEMENT through the bootstrap, and check the result.

Options:
  -f, --var-file PATH  Customer tfvars. Must set tfpr_license (the MSP license
                       from NRIT). tfpr_entitlement is written into it.
  -y, --yes            Apply without asking, and never prompt. For automation.
  -h, --help           Show this help.

Environment overrides: TFPR_PORTAL_URL, TFPR_PORTAL_APP_ID,
TFPR_REVOCATIONS_URL.
EOF
}

die() { echo "onboard: $*" >&2; exit 1; }

# Read a top-level scalar string assignment (key = "value") from a tfvars file.
tfvar() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$var_file" | head -n1
}

# Replace the key's line, or append one.
set_tfvar() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$var_file"; then
    awk -v k="$key" -v v="$value" '
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = \"" v "\""; next }
      { print }' "$var_file" >"$tmp"
  else
    cp "$var_file" "$tmp"
    printf '\n%s = "%s"\n' "$key" "$value" >>"$tmp"
  fi
  cat "$tmp" >"$var_file"
  rm -f "$tmp"
}

# Print the decoded JSON payload of a compact JWS. No signature check: the
# engine verifies; this only reads ids to compare.
jws_payload() {
  local part
  part=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#part} % 4 )) -ne 0 ]; do part="${part}="; done
  printf '%s' "$part" | base64 --decode
}

# The same name scripts/create-backend.sh derives for the bootstrap state account.
sub_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-6
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-6
  fi
}

is_jws() { [[ "$1" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--var-file) var_file="$2"; shift 2 ;;
    -y|--yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$var_file" ] || { usage; exit 2; }
[ -f "$var_file" ] || die "var-file not found: $var_file"
for tool in az gh jq curl terraform; do
  command -v "$tool" >/dev/null || die "$tool is required."
done
tf_data_dir="${TF_DATA_DIR:-.terraform}"
[ -f "$tf_data_dir/terraform.tfstate" ] || die "run from the repository root after scripts/create-backend.sh and terraform init."

tenant_id=$(tfvar tenant_id)
msp_tenant_id=$(tfvar msp_tenant_id)
msp_tenant_id="${msp_tenant_id:-$tenant_id}"
org=$(tfvar github_organization)
[ -n "$org" ] || die "github_organization is not set in $var_file"
repo=$(tfvar customer_repository_name)
customer=$(tfvar customer_name)
license=$(tfvar tfpr_license)
entitlement=$(tfvar tfpr_entitlement)

[ -n "$tenant_id" ] && [ -n "$repo" ] && [ -n "$customer" ] || die "$var_file must set tenant_id, customer_repository_name and customer_name."

# One clone can hold another customer's init; planning this tfvars against
# that state would show the other customer's resources being replaced.
subscription_id=$(tfvar management_subscription_id)
location_short=$(tfvar location_short)
expected_backend="stcicdboot${location_short}$(sub_hash "$subscription_id")"
actual_backend=$(jq -r '.backend.config.storage_account_name // empty' "$tf_data_dir/terraform.tfstate")
[ "$actual_backend" = "$expected_backend" ] || die "terraform is initialised against $actual_backend, but $var_file needs $expected_backend. Run scripts/create-backend.sh -f $var_file and the terraform init it prints (with -reconfigure), or use a separate TF_DATA_DIR per customer."
[ -n "$license" ] || die "$var_file has no tfpr_license. Add the MSP license NRIT issued: tfpr_license = \"<token>\"."
is_jws "$license" || die "tfpr_license is not a compact JWS."

license_claims=$(jws_payload "$license")
license_id=$(jq -r '.jti' <<<"$license_claims")
msp=$(jq -r '.sub' <<<"$license_claims")
org_id=$(curl -fsS "https://api.github.com/orgs/${org}" | jq -r '.id')
[[ "$org_id" =~ ^[0-9]+$ ]] || die "could not read the id of GitHub organization $org."

echo "Customer:     $customer ($org/$repo)"
echo "Tenant:       $tenant_id"
echo "GitHub org:   $org ($org_id)"
echo "MSP:          $msp (license $license_id, tenant $msp_tenant_id)"

revocations=$(jws_payload "$(curl -fsS "$REVOCATIONS_URL")")
is_revoked() { jq -e --arg id "$2" --arg list "$1" '.[$list] | index($id)' <<<"$revocations" >/dev/null; }
! is_revoked revoked_licenses "$license_id" || die "license $license_id is revoked. Ask NRIT for a new one."

entitlement_matches() {
  is_jws "$1" || return 1
  jws_payload "$1" | jq -e --arg tid "$tenant_id" --argjson org "$org_id" --arg msp "$msp" \
    '.azure_tid == $tid and .gh_org_id == $org and .msp == $msp' >/dev/null || return 1
  ! is_revoked revoked_entitlements "$(jws_payload "$1" | jq -r '.sub')"
}

portal_token() {
  az account get-access-token --tenant "$msp_tenant_id" --resource "api://${PORTAL_APP_ID}" \
    --query accessToken -o tsv 2>/dev/null
}

# Prints the token of the live entitlement for this tenant and org, issuing
# one when there is none.
portal_entitlement() {
  local token="$1" body status
  body=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $token" "$PORTAL_URL/api/entitlements")
  status=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$status" = 200 ] || die "portal list failed ($status): $(jq -r '.message // .' <<<"$body" 2>/dev/null)"
  local existing
  existing=$(jq -r --arg tid "$tenant_id" --argjson org "$org_id" \
    'first(.entitlements[] | select(.status == "live" and .azure_tid == $tid and .gh_org_id == $org) | .token) // empty' <<<"$body")
  if [ -n "$existing" ]; then
    echo "Entitlement:  found a live one in the portal" >&2
    printf '%s' "$existing"
    return
  fi
  body=$(curl -sS -w '\n%{http_code}' -X POST -H "Authorization: Bearer $token" -H 'content-type: application/json' \
    -d "$(jq -n --arg tid "$tenant_id" --arg login "$org" --argjson org "$org_id" --arg label "$customer" '{azure_tid: $tid, gh_org: $login, gh_org_id: $org, label: $label}')" \
    "$PORTAL_URL/api/entitlements")
  status=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$status" = 201 ] || die "portal issue failed ($status): $(jq -r '.message // .' <<<"$body" 2>/dev/null)"
  echo "Entitlement:  issued $(jq -r '.id' <<<"$body")" >&2
  jq -r '.token' <<<"$body"
}

if entitlement_matches "$entitlement"; then
  echo "Entitlement:  already in $var_file"
else
  [ -z "$entitlement" ] || echo "The entitlement in $var_file is revoked or for another tenant, organization or MSP; replacing it."
  token=$(portal_token) || token=""
  if [ -n "$token" ]; then
    entitlement=$(portal_entitlement "$token")
  elif $assume_yes; then
    die "no portal token. Run: az login --tenant $msp_tenant_id --scope api://${PORTAL_APP_ID}/user_impersonation"
  else
    echo "No portal token for tenant $msp_tenant_id. Either stop and run:"
    echo "  az login --tenant $msp_tenant_id --scope api://${PORTAL_APP_ID}/user_impersonation"
    echo "or issue the entitlement on $PORTAL_URL and paste its token here (empty to stop):"
    read -rs entitlement
    [ -n "$entitlement" ] || exit 1
  fi
  entitlement_matches "$entitlement" || die "the entitlement is revoked or not for tenant $tenant_id, organization $org_id and MSP $msp."
  set_tfvar tfpr_entitlement "$entitlement"
  echo "Wrote tfpr_entitlement to $var_file. Commit it if the file is tracked."
fi
entitlement_id=$(jws_payload "$entitlement" | jq -r '.sub')

plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT
plan_status=0
terraform plan -detailed-exitcode -var-file="$var_file" -out="$plan_dir/tfplan" || plan_status=$?
[ "$plan_status" -ne 1 ] || die "terraform plan failed."

if [ "$plan_status" -eq 2 ]; then
  if ! $assume_yes; then
    read -rp "Apply this plan? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Not applied."; exit 1; }
  fi
  terraform apply "$plan_dir/tfplan"
fi

echo "Checking ${org}/${repo}..."
failed=false
[ "$(gh variable get TFPR_LICENSE -R "$org/$repo")" = "$license" ] || { echo "TFPR_LICENSE is missing or differs." >&2; failed=true; }
[ "$(gh variable get TFPR_ENTITLEMENT -R "$org/$repo")" = "$entitlement" ] || { echo "TFPR_ENTITLEMENT is missing or differs." >&2; failed=true; }

revocations=$(jws_payload "$(curl -fsS "$REVOCATIONS_URL")")
if is_revoked revoked_licenses "$license_id"; then
  echo "License $license_id is revoked. Ask NRIT for a new one." >&2; failed=true
fi
if is_revoked revoked_entitlements "$entitlement_id"; then
  echo "Entitlement $entitlement_id is revoked. Run onboard again for a new one." >&2; failed=true
fi

$failed && exit 1
echo "Done: TFPR_LICENSE and TFPR_ENTITLEMENT are set and not revoked (list issued $(jq -r '.iat | todate' <<<"$revocations"))."
