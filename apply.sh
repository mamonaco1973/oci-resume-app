#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the resume scoring application on OCI.
#
#   Phase 1 (01-ocir):      Creates the OCIR container repository
#   Phase 2 (02-docker):    Builds the Docker image and pushes it to OCIR
#   Phase 3 (03-functions): Deploys Functions, NoSQL, Queue, Connector Hub,
#                           VCN, IAM, buckets and API Gateway
#   Phase 4 (04-webapp):    Renders js/config.js and uploads the SPA
#
# No environment variables are required.  Everything is derived automatically
# from ~/.oci/config and the OCI CLI.  An OCIR auth token is created on the
# first run and saved to ~/.oci/ocir_token for reuse on subsequent runs.
#
# Optional env var:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
# ================================================================================

set -euo pipefail

# Model selection — keeps apply/destroy/check_env and Terraform in agreement.
source ./genai-config.sh

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

# Compartment falls back to tenancy root when OCI_COMPARTMENT_ID is not set.
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
  echo "NOTE: OCI_COMPARTMENT_ID not set — using tenancy OCID as compartment."
fi

NAMESPACE=$(oci os ns get --region "${REGION}" --query 'data' --raw-output)

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
    --description "resume-app-ocir" \
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

# ------------------------------------------------------------------------------
# Resolve the Generative AI model name to its OCID
# ------------------------------------------------------------------------------
# The inference endpoint's OnDemandServingMode takes a model OCID, not a display
# name — passing the name fails at scoring time with a 404 "Entity with key
# <name> not found", long after a successful deploy.
#
# The OCID is resolved here rather than hardcoded because base-model OCIDs are
# REGION-SPECIFIC. A literal ocid1.generativeaimodel.oc1.iad.… in config would
# work in Ashburn and 404 everywhere else, which is exactly the kind of thing
# that makes a tutorial fail for everyone who is not the author.
#
# genai-config.sh therefore keeps the human-readable name, and this turns it
# into whatever OCID that name has in the region being deployed to.
# ------------------------------------------------------------------------------

echo "NOTE: Resolving Gen AI model '${GENAI_MODEL_ID}' to an OCID..."

GENAI_MODEL_OCID=$(oci generative-ai model-collection list-models \
  --compartment-id "${TENANCY_OCID}" \
  --region "${REGION}" \
  --output json 2>/dev/null \
  | jq -r --arg m "${GENAI_MODEL_ID}" '
      [ .data.items[]?
        | select(."display-name" == $m)
        | select(.capabilities[]? == "CHAT")
        | select(."time-on-demand-retired" == null)
        | .id
      ] | first // empty' 2>/dev/null || echo "")

if [ -z "${GENAI_MODEL_OCID}" ]; then
  echo "ERROR: Could not resolve '${GENAI_MODEL_ID}' to an on-demand CHAT model"
  echo "ERROR: in ${REGION}. List what is currently available with:"
  echo "ERROR:   oci generative-ai model-collection list-models \\"
  echo "ERROR:     --compartment-id ${TENANCY_OCID} --output json | jq -r '"
  echo "ERROR:     .data.items[] | select(.capabilities[]? == \"CHAT\")"
  echo "ERROR:     | select(.\"time-on-demand-retired\" == null) | .\"display-name\"'"
  echo "ERROR: Then update GENAI_MODEL_ID in genai-config.sh."
  exit 1
fi

export TF_VAR_genai_model_id="${GENAI_MODEL_OCID}"
echo "NOTE: Gen AI model    - ${GENAI_MODEL_ID}"
echo "NOTE: Gen AI model id - ${GENAI_MODEL_OCID}"

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

# SPA runtime config consumed by every ES module. Not committed (see
# .gitignore) — regenerated on every apply.
echo "NOTE: Writing js/config.js..."
# Self-registration profile — looked up by NAME (created once in the console),
# so no profile ID has to be hard-coded or exported. apply.sh resolves its ID
# from the domain. When found, the SPA sign-in modal shows a "Sign Up"
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
  echo "NOTE: Profile '${SIGNUP_PROFILE_NAME}' not found — 'Sign Up' hidden."
  SIGNUP_PROFILE_ID=""
else
  echo "NOTE: Self-registration profile id - ${SIGNUP_PROFILE_ID}"
fi

# Self-registration lands on the domain's hosted signup form. Empty when the
# profile was not found, which makes the SPA hide the Sign Up button
# rather than link somewhere broken.
SIGNUP_URL=""
if [ -n "${SIGNUP_PROFILE_ID}" ]; then
  SIGNUP_URL="${DOMAIN_URL%/}/ui/v1/signup?profileid=${SIGNUP_PROFILE_ID}"
fi

# WEB_BASE_URL is the directory the SPA is served from, not an origin: Object
# Storage hosts it under /n/<ns>/b/<bucket>/o/, so every browser-side URL has to
# be built from this rather than window.location.origin.
WEB_BASE_URL="${WEBSITE_URL%/index.html}"

export API_BASE_URL="${API_BASE}"
export DOMAIN_URL CLIENT_ID="${SPA_CLIENT_ID}" WEB_BASE_URL SIGNUP_URL

envsubst '${API_BASE_URL} ${DOMAIN_URL} ${CLIENT_ID} ${WEB_BASE_URL} ${SIGNUP_URL}' \
  < js/config.js.tmpl > js/config.js || {
  echo "ERROR: Failed to generate js/config.js"
  exit 1
}

echo "NOTE: Web base URL         - ${WEB_BASE_URL}"
echo "NOTE: OAuth redirect URI   - ${REDIRECT_URI}"

terraform init
terraform apply -auto-approve -var="web_bucket_name=${WEB_BUCKET}"
cd ..

# ------------------------------------------------------------------------------
# Post-deployment validation
# ------------------------------------------------------------------------------
# No cold-start wait here. It was inherited from the notes app, where it was
# already doing nothing useful: validate.sh only proves the gateway REJECTS
# unauthenticated calls, and those are answered by API Gateway itself — no
# function is ever invoked, so there is no container to warm.
#
# The first real invocation happens when someone signs in and loads the app,
# which is well after this script exits.
# ------------------------------------------------------------------------------

echo "NOTE: Running post-deployment validation..."
./validate.sh

# ================================================================================
# End of script
# ================================================================================
