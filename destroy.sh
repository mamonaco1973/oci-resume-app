#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the resume scoring application stack deployed by apply.sh.
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
# Region the stack deploys into. Defaults to whatever ~/.oci/config says, but
# OCI_REGION overrides it so this project can target a different region without
# repointing the CLI for everything else on the machine.
#
# This project deploys to us-chicago-1 rather than the usual us-ashburn-1
# because Generative AI model availability differs sharply by region: Chicago
# serves Meta Llama and OpenAI gpt-oss on demand and Ashburn does not, and the
# Grok models that ARE in both were erratic in Ashburn (measured 0.4s to 68s on
# an identical 5-token request) while Chicago's slowest was 2.6s.
REGION="${OCI_REGION:-us-chicago-1}"
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
fi

export TF_VAR_tenancy_ocid="$TENANCY_OCID"
export TF_VAR_compartment_id="$OCI_COMPARTMENT_ID"
export TF_VAR_region="$REGION"

# ------------------------------------------------------------------------------
# Home region — where tenancy-level IAM writes must go
# ------------------------------------------------------------------------------
# Policies and dynamic groups have one master copy, in the tenancy home region,
# and OCI rejects writes to them from anywhere else with a 403 naming the home
# region. Since this stack deploys to Chicago, 03-functions runs those five
# resources through a provider alias pinned here.
#
# Queried rather than hardcoded: the home region is a property of the tenancy,
# so a hardcoded IAD would silently be wrong for anyone else running this.
# ------------------------------------------------------------------------------
HOME_REGION=$(oci iam region-subscription list \
  --tenancy-id "${TENANCY_OCID}" \
  --query 'data[?"is-home-region"]."region-name" | [0]' \
  --raw-output 2>/dev/null || echo "")

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region. Check with:"
  echo "ERROR:   oci iam region-subscription list --tenancy-id ${TENANCY_OCID}"
  exit 1
fi

export TF_VAR_home_region="${HOME_REGION}"

# genai_model_id has no default — deliberately, so a missing value fails at plan
# time rather than deploying a worker pointed at nothing. Terraform still
# demands a value on DESTROY, though, and without this the teardown stops on an
# interactive prompt.
#
# A placeholder is correct here rather than resolving the real OCID: the value
# is only ever read as config on Function resources that are being deleted, so
# looking it up would mean an extra API round trip to feed a field nothing will
# read. Resolving it would also make destroy fail whenever the model has since
# been withdrawn — precisely when you most need the teardown to work.
export TF_VAR_genai_model_id="unused-during-destroy"

# Must match the domain used at apply time so the data source resolves the same
# domain (and the correct app to deactivate).  REQUIRED — no silent fallback,
# or destroy could target the wrong domain's app.
if [ -z "${OCI_DOMAIN_NAME:-}" ]; then
  echo "ERROR: OCI_DOMAIN_NAME is not set — export the domain you deployed into, e.g.:"
  echo "ERROR:   export OCI_DOMAIN_NAME=resume-app"
  exit 1
fi
export TF_VAR_domain_display_name="${OCI_DOMAIN_NAME}"

# ------------------------------------------------------------------------------
# Phase 4: Destroy static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/4] Destroying web application..."

# The bucket lives in the 03-functions state; Phase 4 only manages the uploaded
# objects but its config still requires the bucket-name var to be set.  Read it
# from the Phase 3 output, with the same API fallback the backend bucket uses
# below: a previously failed destroy strips the outputs while leaving the
# buckets, so the output alone is not dependable on a re-run.
WEB_BUCKET=$(cd 03-functions && terraform output -raw web_bucket_name 2>/dev/null || echo "")

if [ -z "${WEB_BUCKET}" ]; then
  WEB_NS=$(oci os ns get --region "${REGION}" --query 'data' --raw-output 2>/dev/null || echo "")
  if [ -n "${WEB_NS}" ]; then
    WEB_BUCKET=$(oci os bucket list \
      --region "${REGION}" \
      --namespace "${WEB_NS}" \
      --compartment-id "${OCI_COMPARTMENT_ID}" \
      --query "data[?starts_with(name, 'resume-web-')].name | [0]" \
      --raw-output 2>/dev/null || echo "")
  fi
fi

# Destroy only needs the variable SET -- the objects are removed by state
# address, not by name -- so a placeholder is safe when discovery finds nothing.
if [ -z "${WEB_BUCKET}" ] || [ "${WEB_BUCKET}" = "null" ]; then
  WEB_BUCKET="unknown"
fi

cd 04-webapp || { echo "ERROR: 04-webapp directory missing."; exit 1; }
terraform init
terraform destroy -auto-approve -var="web_bucket_name=${WEB_BUCKET}"
cd ..

# ------------------------------------------------------------------------------
# Phase 3: Destroy Functions, NoSQL, and API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/4] Destroying Functions, NoSQL, Queue, and API Gateway..."

# ------------------------------------------------------------------------------
# Empty the backend bucket before Terraform touches it
# ------------------------------------------------------------------------------
# Object Storage refuses to delete a bucket that still contains objects, and the
# backend bucket is filled at RUNTIME by the functions — resume text, per-job
# snapshots, scraped descriptions, analyses and attachment bytes. None of it is
# in Terraform state, so `terraform destroy` would fail on the bucket with a
# BucketNotEmpty that looks unrelated to anything the user did.
#
# The web bucket does not need this: every object in it is managed by the
# 04-webapp state and was already removed above.
# ------------------------------------------------------------------------------

BACKEND_BUCKET=$(cd 03-functions && terraform output -raw backend_bucket_name 2>/dev/null || echo "")
OS_NAMESPACE=$(cd 03-functions && terraform output -raw os_namespace 2>/dev/null || echo "")

# ------------------------------------------------------------------------------
# Fall back to discovery when the outputs are gone
# ------------------------------------------------------------------------------
# Terraform destroys OUTPUTS BEFORE the resources they reference, so a destroy
# that fails on the bucket leaves the bucket alive but its outputs already
# stripped from state. Every later run then reads empty strings, skips the
# purge, and fails on the same 409 -- the first failure destroys the
# information the recovery path needs, and re-running can never work.
#
# So do not trust the outputs as the only source. The namespace is a tenancy
# constant and the bucket carries a known name prefix, so both are recoverable
# from the API alone.
# ------------------------------------------------------------------------------
if [ -z "${OS_NAMESPACE}" ]; then
  OS_NAMESPACE=$(oci os ns get --region "${REGION}" --query 'data' --raw-output 2>/dev/null || echo "")
  if [ -n "${OS_NAMESPACE}" ]; then
    echo "NOTE: Namespace recovered from API - ${OS_NAMESPACE}"
  fi
fi

if [ -z "${BACKEND_BUCKET}" ] && [ -n "${OS_NAMESPACE}" ]; then
  BACKEND_BUCKET=$(oci os bucket list \
    --region "${REGION}" \
    --namespace "${OS_NAMESPACE}" \
    --compartment-id "${OCI_COMPARTMENT_ID}" \
    --query "data[?starts_with(name, 'resume-backend-')].name | [0]" \
    --raw-output 2>/dev/null || echo "")
  if [ -n "${BACKEND_BUCKET}" ] && [ "${BACKEND_BUCKET}" != "null" ]; then
    echo "NOTE: Backend bucket recovered from API - ${BACKEND_BUCKET}"
  else
    BACKEND_BUCKET=""
  fi
fi

if [[ -n "${BACKEND_BUCKET}" && -n "${OS_NAMESPACE}" ]]; then
  echo "NOTE: Emptying backend bucket ${BACKEND_BUCKET}..."
  # Failure here is NOT survivable: Terraform's bucket delete fails with
  # 409-BucketNotEmpty a few lines later, and the original code hid the cause
  # behind "already empty or unreachable — continuing". Stderr is kept and the
  # script stops, so the real error is what you see.
  if ! oci os object bulk-delete \
      --region "${REGION}" \
      --namespace "${OS_NAMESPACE}" \
      --bucket-name "${BACKEND_BUCKET}" \
      --force; then
    echo "ERROR: Could not empty ${BACKEND_BUCKET} in ${REGION}."
    echo "ERROR: terraform destroy would fail on 409-BucketNotEmpty, so"
    echo "ERROR: stopping here instead. Empty it and re-run ./destroy.sh."
    exit 1
  fi
else
  # Not survivable either. If the outputs cannot be read, the bucket is not
  # emptied and Terraform fails on 409-BucketNotEmpty regardless -- so the old
  # "skipping purge" NOTE only bought a confusing error thirty seconds later.
  echo "ERROR: Could not read backend_bucket_name / os_namespace from the"
  echo "ERROR: 03-functions state, so the bucket cannot be emptied and"
  echo "ERROR: terraform destroy would fail on 409-BucketNotEmpty."
  echo "ERROR:   bucket    = '${BACKEND_BUCKET}'"
  echo "ERROR:   namespace = '${OS_NAMESPACE}'"
  echo "ERROR: Check:  cd 03-functions && terraform output"
  exit 1
fi

# ------------------------------------------------------------------------------
# Deactivate the Identity Domains app before destroy
# ------------------------------------------------------------------------------
# Identity Domains rejects DeleteApp on an ACTIVE app with a generic 400, so
# terraform destroy fails on oci_identity_domains_app.  Flip it inactive first
# via the domain SCIM API (AppStatusChanger).  Best-effort: if this fails,
# deactivate "resume-spa" in the console, then re-run destroy.
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
    || echo "NOTE: CLI deactivate failed — if destroy errors, deactivate 'resume-spa' in the console."
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

echo "NOTE: Purging OCIR images from resume-functions repository..."

IMAGE_IDS=$(oci artifacts container image list \
  --region "${REGION}" \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --all \
  --query 'data.items[].id' \
  --output json 2>/dev/null | \
  jq -r '.[] // empty' 2>/dev/null || true)

if [[ -n "${IMAGE_IDS}" ]]; then
  echo "${IMAGE_IDS}" | while read -r IMG_ID; do
    echo "NOTE: Deleting image ${IMG_ID}..."
    oci artifacts container image delete \
      --region "${REGION}" \
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
  --region "${HOME_REGION}" \
  --user-id "${USER_OCID}" \
  --query "data[?description=='resume-app-ocir'].id | [0]" \
  --raw-output 2>/dev/null || echo "")

if [[ -n "${TOKEN_ID}" && "${TOKEN_ID}" != "null" ]]; then
  oci iam auth-token delete \
    --region "${HOME_REGION}" \
    --user-id "${USER_OCID}" \
    --auth-token-id "${TOKEN_ID}" \
    --force
  echo "NOTE: OCIR auth token deleted."
else
  echo "NOTE: No resume-app-ocir auth token found — skipping."
fi

rm -f "${TOKEN_FILE}"
echo "NOTE: Removed cached token file ${TOKEN_FILE}."

./delete_domain.sh

# ================================================================================
# End of script
# ================================================================================
