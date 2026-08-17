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

echo "NOTE: Model is listed as a CHAT model."
echo "NOTE: Model OCID - ${GENAI_MODEL_OCID}"

# ------------------------------------------------------------------------------
# Prove the model actually answers an on-demand chat call
# ------------------------------------------------------------------------------
# Being listed proves nothing. `list-models` is the control plane and returns
# models that are only available through a dedicated AI cluster — ACTIVE, CHAT
# capable, no retirement date, valid OCID, and every chat() call 404s. Measured
# in us-ashburn-1: all Meta Llama 4, both OpenAI gpt-oss sizes and every Cohere
# model list fine and cannot be called on demand.
#
# The only reliable test is to make the call, so probe_genai.py does exactly
# that against the configured model. Best-effort: it needs a python with the
# oci SDK, and if none is found the deploy continues with a warning rather than
# being blocked by a tooling gap.
# ------------------------------------------------------------------------------

GENAI_PY=""
for candidate in \
    "$(command -v python3 || true)" \
    "$(head -1 "$(command -v oci || echo /nonexistent)" 2>/dev/null | sed 's/^#!//; s/ .*//')" \
    "${HOME}/lib/oracle-cli/bin/python"; do
  if [ -x "${candidate}" ] && "${candidate}" -c "import oci" 2>/dev/null; then
    GENAI_PY="${candidate}"
    break
  fi
done

if [ -z "${GENAI_PY}" ]; then
  echo "WARN: No python with the oci SDK found — skipping the on-demand chat probe."
  echo "WARN: Verify manually before trusting the deploy:  python3 probe_genai.py"
else
  echo "NOTE: Probing on-demand chat with ${GENAI_MODEL_ID}..."
  if "${GENAI_PY}" probe_genai.py --check "${GENAI_MODEL_ID}"; then
    echo "NOTE: Generative AI model answers on demand."
  else
    echo "ERROR: '${GENAI_MODEL_ID}' is listed but does NOT serve on-demand chat."
    echo "ERROR: It likely requires a dedicated AI cluster. See what does work:"
    echo "ERROR:   ${GENAI_PY} probe_genai.py"
    echo "ERROR: Then update GENAI_MODEL_ID in genai-config.sh."
    exit 1
  fi
fi
