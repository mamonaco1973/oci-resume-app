#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the Notes CRUD application on OCI.
#
#   Phase 1 (01-ocir):    Creates the OCIR container repository
#   Phase 2 (02-docker):  Builds the Docker image and pushes it to OCIR
#   Phase 3 (03-functions): Deploys Functions, NoSQL, VCN, IAM, API Gateway
#   Phase 4 (04-webapp):  Injects API URL into HTML and deploys to Object Storage
#
# No environment variables are required.  Everything is derived automatically
# from ~/.oci/config and the OCI CLI.  An OCIR auth token is created on the
# first run and saved to ~/.oci/ocir_token for reuse on subsequent runs.
#
# Optional env var:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
# ================================================================================

set -euo pipefail

# Load local, uncommitted overrides (OCI_DOMAIN_NAME, OCI_SIGNUP_PROFILE_NAME,
# OCI_COMPARTMENT_ID, etc.) if an env.sh is present. Gitignored.
if [ -f env.sh ]; then source env.sh; fi

# ------------------------------------------------------------------------------
# Environment validation
# ------------------------------------------------------------------------------

echo "NOTE: Running environment validation..."
./check_env.sh
echo "NOTE: Validating the authentication domain."
./setup_domain.sh

# setup_domain.sh created/verified the identity domain and wrote env.sh with
# OCI_DOMAIN_NAME (+ OCI_SIGNUP_PROFILE_NAME). Load it now so the rest of the
# deploy targets that domain. This is where OCI_DOMAIN_NAME is required — after
# setup_domain has had its chance to produce it (not up front in check_env.sh).
if [ -f env.sh ]; then source env.sh; fi
if [ -z "${OCI_DOMAIN_NAME:-}" ]; then
  echo "ERROR: OCI_DOMAIN_NAME is unset after setup_domain.sh — expected it to write env.sh."
  exit 1
fi

# ------------------------------------------------------------------------------
# Derive OCI identifiers from ~/.oci/config
# ------------------------------------------------------------------------------

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

# Compartment falls back to tenancy root when OCI_COMPARTMENT_ID is not set.
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
  echo "NOTE: OCI_COMPARTMENT_ID not set — using tenancy OCID as compartment."
fi

NAMESPACE=$(oci os ns get --query 'data' --raw-output)

# OCIR username: namespace/username-string (not OCID).
# For federated users this returns "oracleidentitycloudservice/email@domain.com"
# which OCIR requires; for local users it returns the plain username.
USER_NAME=$(oci iam user get --user-id "${USER_OCID}" --query 'data.name' --raw-output)
OCIR_USERNAME="${NAMESPACE}/${USER_NAME}"
OCIR_HOST="${REGION}.ocir.io"

echo "NOTE: Region      - ${REGION}"
echo "NOTE: Namespace   - ${NAMESPACE}"
echo "NOTE: Compartment - ${OCI_COMPARTMENT_ID}"
echo "NOTE: OCIR user   - ${OCIR_USERNAME}"

# ------------------------------------------------------------------------------
# OCIR auth token — created once, cached in ~/.oci/ocir_token
# ------------------------------------------------------------------------------
# OCI auth tokens can only be read at creation time.  On first run this block
# creates one via the OCI CLI and writes it to the cache file.  Subsequent
# runs reuse the cached value.  If the cache is lost, delete the file and
# re-run; a new token will be created (max 2 tokens per user — old ones may
# need to be deleted first in the Console under Identity → Users → Auth Tokens).
# ------------------------------------------------------------------------------

TOKEN_FILE="${HOME}/.oci/ocir_token"

if [ -f "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
  echo "NOTE: Using cached OCIR token from ${TOKEN_FILE}"
  OCIR_TOKEN=$(cat "${TOKEN_FILE}")
else
  echo "NOTE: No cached OCIR token found — creating one via OCI CLI..."
  OCIR_TOKEN=$(oci iam auth-token create \
    --user-id "${USER_OCID}" \
    --description "notes-crud-ocir" \
    --query 'data.token' \
    --raw-output)

  echo "${OCIR_TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  echo "NOTE: OCIR token created and saved to ${TOKEN_FILE}"
fi

# Export Terraform variables shared across all phases.
export TF_VAR_tenancy_ocid="$TENANCY_OCID"
export TF_VAR_compartment_id="$OCI_COMPARTMENT_ID"
export TF_VAR_region="$REGION"

# Identity domain that holds the SPA app + self-registration profile.  Create the
# domain once in the console (Terraform can't cleanly create/destroy domains),
# then point at it here.  REQUIRED — check_env.sh (run above) fails if unset.
export TF_VAR_domain_display_name="${OCI_DOMAIN_NAME}"
echo "NOTE: Identity domain - ${TF_VAR_domain_display_name}"

# Export OCIR vars for 02-docker/build.sh.
export OCIR_HOST OCIR_TOKEN OCIR_USERNAME NAMESPACE

# ------------------------------------------------------------------------------
# Phase 1: Create OCIR repository
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 1/4] Creating OCIR container repository..."

cd 01-ocir || { echo "ERROR: 01-ocir directory missing."; exit 1; }
terraform init
terraform apply -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Phase 2: Build and push Docker image
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 2/4] Building and pushing Docker image..."

./02-docker/build.sh

# Source the image path written by build.sh and pass it to Phase 3.
# shellcheck source=/dev/null
source 02-docker/.build_output
export TF_VAR_image_path="${IMAGE_PATH}"

# ------------------------------------------------------------------------------
# Phase 3: Deploy Functions, NoSQL, and API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/4] Deploying Functions, NoSQL, and API Gateway..."

cd 03-functions || { echo "ERROR: 03-functions directory missing."; exit 1; }
terraform init
terraform apply -auto-approve

# Read everything Phase 4 needs: API URL, the web bucket (created here so the
# Identity Domains app could register its callback URL), and the OAuth config.
API_BASE=$(terraform output -raw api_gateway_endpoint)
WEB_BUCKET=$(terraform output -raw web_bucket_name)
WEBSITE_URL=$(terraform output -raw website_url)
SPA_CLIENT_ID=$(terraform output -raw spa_client_id)
DOMAIN_URL=$(terraform output -raw identity_domain_url)
cd ..

echo "NOTE: API Gateway endpoint - ${API_BASE}"
echo "NOTE: Web bucket           - ${WEB_BUCKET}"
echo "NOTE: SPA client_id        - ${SPA_CLIENT_ID}"

# The OAuth redirect must match the URI registered on the app exactly; derive it
# from the hosted index.html URL (…/o/index.html → …/o/callback.html).
REDIRECT_URI="${WEBSITE_URL%/index.html}/callback.html"

# ------------------------------------------------------------------------------
# Phase 4: Build and deploy the static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/4] Deploying static web application..."

cd 04-webapp || { echo "ERROR: 04-webapp directory missing."; exit 1; }

export API_BASE
envsubst '${API_BASE}' < index.html.tmpl > index.html || {
  echo "ERROR: Failed to generate index.html"
  exit 1
}

# SPA runtime config consumed by index.html + callback.html. Not committed
# (see .gitignore) — regenerated on every apply.
echo "NOTE: Writing config.json..."
# Self-registration profile — looked up by NAME (created once in the console),
# so no profile ID has to be hard-coded or exported. apply.sh resolves its ID
# from the domain. When found, the SPA sign-in chooser shows a "Create Account"
# option linking to the hosted signup form; if not found, the chooser goes
# straight to sign-in. Override the name with OCI_SIGNUP_PROFILE_NAME.
SIGNUP_PROFILE_NAME="${OCI_SIGNUP_PROFILE_NAME:-spa-signup}"

# The domain URL from Terraform can carry an explicit :443 port; strip it for the
# identity-domains CLI endpoint.
DOMAIN_ENDPOINT="${DOMAIN_URL/:443/}"

echo "NOTE: Resolving self-registration profile '${SIGNUP_PROFILE_NAME}'..."
SIGNUP_PROFILE_ID=$(oci identity-domains self-registration-profiles list \
  --endpoint "${DOMAIN_ENDPOINT}" \
  --filter "name eq \"${SIGNUP_PROFILE_NAME}\"" \
  --query 'data.resources[0].id' --raw-output 2>/dev/null || echo "")

if [ -z "${SIGNUP_PROFILE_ID}" ] || [ "${SIGNUP_PROFILE_ID}" = "null" ]; then
  echo "NOTE: Profile '${SIGNUP_PROFILE_NAME}' not found — 'Create Account' hidden."
  SIGNUP_PROFILE_ID=""
else
  echo "NOTE: Self-registration profile id - ${SIGNUP_PROFILE_ID}"
fi

cat > config.json <<EOF
{
  "domainUrl": "${DOMAIN_URL}",
  "clientId": "${SPA_CLIENT_ID}",
  "redirectUri": "${REDIRECT_URI}",
  "apiBaseUrl": "${API_BASE}",
  "signupProfileId": "${SIGNUP_PROFILE_ID}"
}
EOF

terraform init
terraform apply -auto-approve -var="web_bucket_name=${WEB_BUCKET}"
cd ..

# ------------------------------------------------------------------------------
# Post-deployment validation
# ------------------------------------------------------------------------------
# OCI Functions pull the container image from OCIR on first invocation.
# Wait briefly to allow the cold start to complete before hitting the API.
# ------------------------------------------------------------------------------

echo "NOTE: Waiting 60s for function cold start readiness..."
sleep 60

echo "NOTE: Running post-deployment validation..."
./validate.sh

# ================================================================================
# End of script
# ================================================================================
