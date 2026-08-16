#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the Notes application stack deployed by apply.sh.
#   Destroys resources in reverse phase order:
#
#   Phase 4 (04-webapp):   Destroy Object Storage bucket and objects
#   Phase 3 (03-functions): Destroy Functions, NoSQL, VCN, IAM, API Gateway
#   Phase 1 (01-ocir):     Destroy OCIR repository (images must be purged first)
#
#   Phase 2 has no Terraform state — only a Docker image in OCIR which is
#   deleted during the OCIR purge step before Phase 1 destroy.
#
# No environment variables required — all values derived from ~/.oci/config.
# ================================================================================

set -euo pipefail

# Load local, uncommitted overrides (OCI_DOMAIN_NAME, OCI_SIGNUP_PROFILE_NAME,
# OCI_COMPARTMENT_ID, etc.) if an env.sh is present. Gitignored.
if [ -f env.sh ]; then source env.sh; fi

# ------------------------------------------------------------------------------
# Derive OCI identifiers (same logic as apply.sh)
# ------------------------------------------------------------------------------

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
fi

export TF_VAR_tenancy_ocid="$TENANCY_OCID"
export TF_VAR_compartment_id="$OCI_COMPARTMENT_ID"
export TF_VAR_region="$REGION"

# Must match the domain used at apply time so the data source resolves the same
# domain (and the correct app to deactivate).  REQUIRED — no silent fallback,
# or destroy could target the wrong domain's app.
if [ -z "${OCI_DOMAIN_NAME:-}" ]; then
  echo "ERROR: OCI_DOMAIN_NAME is not set — export the domain you deployed into, e.g.:"
  echo "ERROR:   export OCI_DOMAIN_NAME=notes-app"
  exit 1
fi
export TF_VAR_domain_display_name="${OCI_DOMAIN_NAME}"

# ------------------------------------------------------------------------------
# Phase 4: Destroy static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/4] Destroying web application..."

# The bucket lives in the 03-functions state; Phase 4 only manages the uploaded
# objects but its config still requires the bucket-name var to be set.  Read it
# from the backend output (still present since Phase 3 is torn down after this).
WEB_BUCKET=$(cd 03-functions && terraform output -raw web_bucket_name 2>/dev/null || echo "unknown")

cd 04-webapp || { echo "ERROR: 04-webapp directory missing."; exit 1; }
terraform init
terraform destroy -auto-approve -var="web_bucket_name=${WEB_BUCKET}"
cd ..

# ------------------------------------------------------------------------------
# Phase 3: Destroy Functions, NoSQL, and API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/4] Destroying Functions, NoSQL, and API Gateway..."

# ------------------------------------------------------------------------------
# Deactivate the Identity Domains app before destroy
# ------------------------------------------------------------------------------
# Identity Domains rejects DeleteApp on an ACTIVE app with a generic 400, so
# terraform destroy fails on oci_identity_domains_app.  Flip it inactive first
# via the domain SCIM API (AppStatusChanger).  Best-effort: if this fails,
# deactivate "notes-spa" in the console, then re-run destroy.
# ------------------------------------------------------------------------------
APP_ID=$(cd 03-functions && terraform output -raw spa_app_id 2>/dev/null || echo "")
DOMAIN_URL=$(cd 03-functions && terraform output -raw identity_domain_url 2>/dev/null || echo "")

if [[ -n "${APP_ID}" && -n "${DOMAIN_URL}" ]]; then
  echo "NOTE: Deactivating Identity Domains app ${APP_ID}..."
  oci identity-domains app-status-changer put \
    --endpoint "${DOMAIN_URL}" \
    --app-status-changer-id "${APP_ID}" \
    --active false \
    --schemas '["urn:ietf:params:scim:schemas:oracle:idcs:AppStatusChanger"]' \
    --force 2>/dev/null \
    || echo "NOTE: CLI deactivate failed — if destroy errors, deactivate 'notes-spa' in the console."
fi

cd 03-functions || { echo "ERROR: 03-functions directory missing."; exit 1; }
terraform init
# Retry once — OCI IAM ETag optimistic locking causes spurious 412 failures
# on policy deletes when OCI modifies the resource between read and delete.
terraform destroy -auto-approve || terraform destroy -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Purge OCIR images before Phase 1 destroy
# ------------------------------------------------------------------------------
# Terraform cannot delete an OCIR repository while it still contains images.
# Enumerate all images in the compartment and delete them before destroying
# the repository in Phase 1.
# ------------------------------------------------------------------------------

echo "NOTE: Purging OCIR images from notes-functions repository..."

IMAGE_IDS=$(oci artifacts container image list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --all \
  --query 'data.items[].id' \
  --output json 2>/dev/null | \
  jq -r '.[] // empty' 2>/dev/null || true)

if [[ -n "${IMAGE_IDS}" ]]; then
  echo "${IMAGE_IDS}" | while read -r IMG_ID; do
    echo "NOTE: Deleting image ${IMG_ID}..."
    oci artifacts container image delete \
      --image-id "${IMG_ID}" \
      --force 2>/dev/null || true
  done
else
  echo "NOTE: No OCIR images found to delete."
fi

# ------------------------------------------------------------------------------
# Phase 1: Destroy OCIR repository
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 1/4] Destroying OCIR repository..."

cd 01-ocir || { echo "ERROR: 01-ocir directory missing."; exit 1; }
terraform init
terraform destroy -auto-approve
cd ..

echo "NOTE: Infrastructure teardown complete."

# ------------------------------------------------------------------------------
# Delete OCIR auth token and remove local cache
# ------------------------------------------------------------------------------
# The token was created by apply.sh and occupies one of the user's two
# allowed auth token slots.  Delete it by matching on the description used
# at creation time, then remove the local cache file.
# ------------------------------------------------------------------------------

echo "NOTE: Deleting OCIR auth token..."

TOKEN_FILE="${HOME}/.oci/ocir_token"

TOKEN_ID=$(oci iam auth-token list \
  --user-id "${USER_OCID}" \
  --query "data[?description=='notes-crud-ocir'].id | [0]" \
  --raw-output 2>/dev/null || echo "")

if [[ -n "${TOKEN_ID}" && "${TOKEN_ID}" != "null" ]]; then
  oci iam auth-token delete \
    --user-id "${USER_OCID}" \
    --auth-token-id "${TOKEN_ID}" \
    --force
  echo "NOTE: OCIR auth token deleted."
else
  echo "NOTE: No notes-crud-ocir auth token found — skipping."
fi

rm -f "${TOKEN_FILE}"
echo "NOTE: Removed cached token file ${TOKEN_FILE}."

# ================================================================================
# End of script
# ================================================================================
