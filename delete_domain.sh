#!/bin/bash
# ==============================================================================
# File: delete_domain.sh
#
# Inverse of setup_domain.sh — tears down the identity domain it created.  Kept
# OUTSIDE destroy.sh for the same reason setup_domain.sh is outside apply.sh:
# Terraform can't manage identity-domain lifecycle, so we drive it with the CLI.
#
# It performs:
#   1. Deactivate the domain (OCI refuses to delete an ACTIVE domain).
#   2. Delete the domain — this also removes its self-registration profile and
#      settings, so no separate cleanup is needed for those.
#   3. Remove env.sh so the build scripts no longer target a domain that's gone.
#
# Deleting the domain cascades everything setup_domain.sh created inside it, so
# steps 2b/3 of setup (notification setting + self-reg profile) need no inverse.
#
# ORDER MATTERS: run ./destroy.sh FIRST.  It removes the Terraform-managed SPA
# app (oci_identity_domains_app) that lives inside the domain; deactivating +
# deleting the domain is cleanest once that app is already gone.
#
# Idempotent: if the domain is already gone, it just cleans up env.sh and exits.
# ==============================================================================

set -euo pipefail

# Reuse the same names setup_domain.sh persisted (gitignored).
if [ -f env.sh ]; then source env.sh; fi

DOMAIN_NAME="${OCI_DOMAIN_NAME:-notes-app}"

# ------------------------------------------------------------------------------
# Derive OCI identifiers from ~/.oci/config (mirrors setup_domain.sh)
# ------------------------------------------------------------------------------
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$TENANCY_OCID}"

echo "NOTE: Domain      - ${DOMAIN_NAME}"
echo "NOTE: Compartment - ${COMPARTMENT_ID}"

# Remove env.sh regardless of how we exit, so a half-deleted domain never leaves
# the build scripts pointing at it.
cleanup_env_sh() {
  if [ -f env.sh ]; then
    echo "NOTE: Removing env.sh..."
    rm -f env.sh
  fi
}

# ------------------------------------------------------------------------------
# 1. Look up the domain by display name
# ------------------------------------------------------------------------------
find_domain_id() {
  oci iam domain list \
    --compartment-id "${COMPARTMENT_ID}" \
    --all \
    --query "data[?\"display-name\"=='${DOMAIN_NAME}'].id | [0]" \
    --raw-output 2>/dev/null || echo ""
}

DOMAIN_ID="$(find_domain_id)"

if [ -z "${DOMAIN_ID}" ] || [ "${DOMAIN_ID}" = "null" ]; then
  echo "NOTE: Domain '${DOMAIN_NAME}' not found — nothing to delete."
  cleanup_env_sh
  exit 0
fi

echo "NOTE: Found domain - ${DOMAIN_ID}"

# ------------------------------------------------------------------------------
# 2. Deactivate (only if ACTIVE) — a deactivated domain can't be deleted while
#    ACTIVE, and re-deactivating an INACTIVE one errors, so gate on state.
# ------------------------------------------------------------------------------
STATE=$(oci iam domain get --domain-id "${DOMAIN_ID}" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "")
echo "NOTE: Lifecycle state - ${STATE:-unknown}"

if [ "${STATE}" = "ACTIVE" ]; then
  echo "NOTE: Deactivating domain (waiting for completion)..."
  oci iam domain deactivate \
    --domain-id "${DOMAIN_ID}" \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds 900 \
    < /dev/null
fi

# ------------------------------------------------------------------------------
# 3. Delete the domain (waits for the work request to finish). --force skips the
#    interactive confirmation. This also removes the self-registration profile.
# ------------------------------------------------------------------------------
echo "NOTE: Deleting domain (this takes a few minutes)..."
oci iam domain delete \
  --domain-id "${DOMAIN_ID}" \
  --force \
  --wait-for-state SUCCEEDED \
  --max-wait-seconds 1800 \
  < /dev/null

# ------------------------------------------------------------------------------
# 4. Drop env.sh so ./apply.sh won't target the now-deleted domain
# ------------------------------------------------------------------------------
cleanup_env_sh

echo ""
echo "================================================================================="
echo "  Domain '${DOMAIN_NAME}' deleted."
echo "================================================================================="
echo "  Re-run ./setup_domain.sh to recreate it from scratch."
echo "================================================================================="
