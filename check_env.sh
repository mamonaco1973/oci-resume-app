#!/bin/bash
# ================================================================================
# File: check_env.sh
#
# Purpose:
#   Pre-flight validation.  Confirms required tools are available and the
#   OCI CLI is configured and reachable.
#
# Required tools: oci, terraform, docker, jq, envsubst
#
# Optional env var:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Tool checks
# ------------------------------------------------------------------------------

echo "NOTE: Validating required commands in PATH."

commands=("oci" "terraform" "docker" "jq" "envsubst")

for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${cmd}"
    exit 1
  fi
  echo "NOTE: Found required command: ${cmd}"
done

echo "NOTE: All required commands are available."

# ------------------------------------------------------------------------------
# OCI CLI connectivity check
# ------------------------------------------------------------------------------

echo "NOTE: Checking OCI CLI connection."
if ! oci os ns get > /dev/null 2>&1; then
  echo "ERROR: Failed to connect to OCI. Check your ~/.oci/config."
  exit 1
fi

echo "NOTE: OCI CLI authentication successful."

# ------------------------------------------------------------------------------
# Generative AI availability check
# ------------------------------------------------------------------------------
# The model the worker scores with must actually be served on demand in this
# region. OCI retires on-demand models aggressively — an entire vendor's line
# went retired on a single day in August 2026 — so a build that worked last
# month can fail on a model that is merely listed but no longer invokable.
#
# Catching it here turns a confusing runtime failure (every job silently ends
# up in Error with a model message) into a clear pre-flight stop.
# ------------------------------------------------------------------------------

source ./genai-config.sh

echo "NOTE: Checking Generative AI model availability - ${GENAI_MODEL_ID}"

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

# Resolve to the OCID rather than just counting matches: the OCID is what
# apply.sh actually passes to Terraform, so checking for its presence here is
# checking the same thing the deploy depends on.
GENAI_MODEL_OCID=$(oci generative-ai model-collection list-models \
  --compartment-id "${TENANCY_OCID}" \
  --output json 2>/dev/null \
  | jq -r --arg m "${GENAI_MODEL_ID}" '
      [ .data.items[]?
        | select(."display-name" == $m)
        | select(.capabilities[]? == "CHAT")
        | select(."time-on-demand-retired" == null)
        | .id
      ] | first // empty' 2>/dev/null || echo "")

if [[ -z "${GENAI_MODEL_OCID}" ]]; then
  echo "ERROR: Model '${GENAI_MODEL_ID}' is not available for on-demand CHAT"
  echo "ERROR: in this region, or has been retired. List what is live with:"
  echo "ERROR:   oci generative-ai model-collection list-models \\"
  echo "ERROR:     --compartment-id ${TENANCY_OCID} --output json | jq -r '"
  echo "ERROR:     .data.items[] | select(.capabilities[]? == \"CHAT\")"
  echo "ERROR:     | select(.\"time-on-demand-retired\" == null)"
  echo "ERROR:     | .\"display-name\"'"
  echo "ERROR: Then update GENAI_MODEL_ID in genai-config.sh."
  exit 1
fi

echo "NOTE: Generative AI model is available on demand."
echo "NOTE: Model OCID - ${GENAI_MODEL_OCID}"
