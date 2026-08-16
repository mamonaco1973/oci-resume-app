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
