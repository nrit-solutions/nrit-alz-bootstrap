#!/usr/bin/env bash
# Create and lock down the storage account that holds the bootstrap's own
# Terraform state.
#
# This is out-of-band infrastructure on purpose. A config must not manage the
# account that stores its own state, so this account is owned by this script,
# not by Terraform. Terraform only references it through the backend block in
# providers.tf.
#
# The account is separate from the Terragrunt state account (state.tf). It is
# public-network Enabled but default-deny, allowing only the operator's current
# public IP. Shared keys are disabled, so all access is Entra ID. The blob key
# holds a single bootstrap.tfstate.
#
# It is idempotent: re-run it whenever your public IP changes, or to re-ensure
# any setting. Each run resets the firewall to exactly your current IP.
#
# Usage:
#   scripts/create-backend.sh -f ../<msp>-operator/customers/<customer>.tfvars
#   scripts/create-backend.sh -s <sub-id> -l westeurope --location-short weu
set -euo pipefail

subscription_id=""
location=""
location_short=""
var_file=""

usage() {
  cat >&2 <<'EOF'
Create the IP-locked storage account for the bootstrap's Terraform state.

Options:
  -f, --var-file PATH        Customer tfvars to read subscription id, location,
                             and location_short from.
  -s, --subscription-id ID   Override management_subscription_id.
  -l, --location NAME        Override location (for example westeurope).
      --location-short CODE  Override location_short (for example weu).
  -h, --help                 Show this help.

Flags override values read from the var-file. subscription_id, location, and
location_short must be resolved from one or the other.
EOF
}

# Read a top-level scalar string assignment (key = "value") from a tfvars file.
tfvar() {
  local key="$1" file="$2"
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--var-file) var_file="$2"; shift 2 ;;
    -s|--subscription-id) subscription_id="$2"; shift 2 ;;
    -l|--location) location="$2"; shift 2 ;;
    --location-short) location_short="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$var_file" ]; then
  [ -f "$var_file" ] || { echo "var-file not found: $var_file" >&2; exit 2; }
  [ -z "$subscription_id" ] && subscription_id="$(tfvar management_subscription_id "$var_file")"
  [ -z "$location" ] && location="$(tfvar location "$var_file")"
  [ -z "$location_short" ] && location_short="$(tfvar location_short "$var_file")"
fi

: "${subscription_id:?subscription id is required (use --var-file or --subscription-id)}"
: "${location:?location is required (use --var-file or --location)}"
: "${location_short:?location_short is required (use --var-file or --location-short)}"

# Deterministic, globally unique name so this script and any future logic agree
# without shared state. First 6 hex of a sha256 of the subscription id keep it
# unique per subscription while staying inside the 24-char lower-alphanumeric
# limit.
sub_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-6
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-6
  fi
}

hash6="$(sub_hash "$subscription_id")"
account_name="stcicdboot${location_short}${hash6}"
resource_group="rg-cicd-bootstrap-${location_short}"
container_name="tfstate"
state_key="bootstrap.tfstate"

if [ "${#account_name}" -gt 24 ] || ! printf '%s' "$account_name" | grep -qE '^[a-z0-9]{3,24}$'; then
  echo "Computed account name is invalid: ${account_name}" >&2
  exit 1
fi

echo "Subscription:   ${subscription_id}"
echo "Resource group: ${resource_group}"
echo "Account:        ${account_name}"
echo "Container:      ${container_name}"
echo "State key:      ${state_key}"

az account set --subscription "$subscription_id"

operator_ip="$(curl -fsS https://api.ipify.org)"
[ -n "$operator_ip" ] || { echo "Could not determine operator public IP" >&2; exit 1; }
operator_object_id="$(az ad signed-in-user show --query id -o tsv)"
echo "Operator IP:    ${operator_ip}"

# An unregistered provider makes the account create fail with a misleading
# "SubscriptionNotFound" on a subscription that never hosted storage.
if [ "$(az provider show --namespace Microsoft.Storage --query registrationState -o tsv)" != "Registered" ]; then
  echo "Registering Microsoft.Storage..."
  az provider register --namespace Microsoft.Storage --wait --output none
fi

echo "Ensuring resource group..."
az group create --name "$resource_group" --location "$location" --output none

if az storage account show --name "$account_name" --resource-group "$resource_group" --output none 2>/dev/null; then
  echo "Account exists, re-ensuring settings..."
  az storage account update \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --min-tls-version TLS1_2 \
    --allow-shared-key-access false \
    --allow-blob-public-access false \
    --https-only true \
    --public-network-access Enabled \
    --default-action Deny \
    --bypass AzureServices \
    --output none
else
  echo "Creating account..."
  az storage account create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --location "$location" \
    --sku Standard_ZRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-shared-key-access false \
    --allow-blob-public-access false \
    --https-only true \
    --public-network-access Enabled \
    --default-action Deny \
    --bypass AzureServices \
    --output none
fi

account_id="$(az storage account show --name "$account_name" --resource-group "$resource_group" --query id -o tsv)"

echo "Enabling blob versioning and soft delete..."
az storage account blob-service-properties update \
  --account-name "$account_name" \
  --resource-group "$resource_group" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 7 \
  --enable-container-delete-retention true \
  --container-delete-retention-days 7 \
  --output none

echo "Resetting firewall to operator IP ${operator_ip}..."
existing_ips="$(az storage account network-rule list \
  --account-name "$account_name" \
  --resource-group "$resource_group" \
  --query "ipRules[].ipAddressOrRange" -o tsv)"
for ip in $existing_ips; do
  [ "$ip" = "$operator_ip" ] && continue
  az storage account network-rule remove \
    --account-name "$account_name" \
    --resource-group "$resource_group" \
    --ip-address "$ip" \
    --output none
done
az storage account network-rule add \
  --account-name "$account_name" \
  --resource-group "$resource_group" \
  --ip-address "$operator_ip" \
  --output none

# Control plane (ARM), so it is not blocked by the default-deny firewall or the
# disabled shared key.
echo "Ensuring container ${container_name}..."
az storage container-rm create \
  --storage-account "$account_name" \
  --resource-group "$resource_group" \
  --name "$container_name" \
  --public-access off \
  --output none

echo "Granting Storage Blob Data Contributor to the operator..."
az role assignment create \
  --assignee-object-id "$operator_object_id" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$account_id" \
  --output none 2>/dev/null || true

cat <<EOF

Backend is ready. Initialize Terraform with:

  terraform init \\
    -backend-config="resource_group_name=${resource_group}" \\
    -backend-config="storage_account_name=${account_name}" \\
    -backend-config="container_name=${container_name}" \\
    -backend-config="key=${state_key}"

If your public IP changes, re-run this script before any terraform command.
Role assignment propagation can take a minute on first run.
EOF
