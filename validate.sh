#!/bin/bash
# ================================================================================
# File: validate.sh
# ================================================================================
# Purpose:
#   Post-deploy check for the JWT-authenticated resume scoring API. Every route
#   requires a valid Identity Domains token, so an end-to-end curl loop would
#   need an interactive browser login. Instead this script:
#     1. Confirms the API rejects UNauthenticated requests (proves the JWT
#        authenticator is wired up and enforcing).
#     2. Confirms the async tier exists — queue plus connector — because a
#        missing connector is invisible from the API surface: jobs submit fine
#        and simply never leave "submitted".
#     3. Prints the web app URL and manual test instructions.
#
# Requirements: oci CLI configured, curl, jq, 03-functions/04-webapp TF state.
# ================================================================================

set -euo pipefail

# Same override the rest of the scripts use. Without this every OCI CLI call
# below silently queries whatever ~/.oci/config points at, finds none of the
# resources, and reports a healthy deploy as broken -- "0 of 4 connectors" when
# all four are ACTIVE in the deploy region.
REGION="${OCI_REGION:-us-chicago-1}"

# ------------------------------------------------------------------------------
# Discover endpoints from Terraform output
# ------------------------------------------------------------------------------
echo "NOTE: Locating API Gateway endpoint..."
# Guarded rather than left bare: without state this fails under set -e and the
# script vanishes with no output, which reads as a crash instead of "phase 3 has
# not been applied".
API_BASE=$(cd 03-functions && terraform output -raw api_gateway_endpoint 2>/dev/null || echo "")
if [[ -z "${API_BASE}" ]]; then
  echo "ERROR: Could not read api_gateway_endpoint from 03-functions state."
  echo "ERROR: Run ./apply.sh first, or check that phase 3 applied cleanly."
  exit 1
fi
WEBAPP_URL=$(cd 04-webapp && terraform output -raw website_url 2>/dev/null || echo "N/A")
QUEUE_ID=$(cd 03-functions && terraform output -raw queue_id 2>/dev/null || echo "")
# The Terraform output is the model OCID, which is unreadable in a summary.
# Source the config for the name the OCID was resolved from.
source ./genai-config.sh 2>/dev/null || true
GENAI_MODEL="${GENAI_MODEL_ID:-unknown}"

echo "NOTE: API Gateway URL - ${API_BASE}"

# ------------------------------------------------------------------------------
# Negative test — unauthenticated calls MUST be rejected by the gateway
# ------------------------------------------------------------------------------
# The gateway validates the JWT before the function runs, so no token → 401
# (some configurations return 403). Either proves auth is enforced; a 2xx here
# would mean the routes are open and the deploy is broken.
#
# Two paths are probed rather than one: a collection route and a path-parameter
# route. They are configured differently — the second carries header
# transformations — so a mistake that only affects the parameterised routes
# would slip past a single-path check.
# ------------------------------------------------------------------------------
# --------------------------------------------------------------------------------
# Function: http_status
#
# Purpose
# Return the HTTP status for a URL, or "000" when the request never completed.
#
# curl exits non-zero when it cannot resolve or connect. Under `set -e` that
# kills the script mid-assignment with NO output at all, which looks like a
# silent crash rather than a network problem — so the failure is swallowed here
# and reported as 000 instead.
#
# Arguments
# - $1 : URL
# - $@ : any extra curl arguments
#
# Returns
# - Three-digit status, or 000
# --------------------------------------------------------------------------------
http_status() {
  local url="$1"; shift
  local code

  # curl already prints "000" to stdout when it cannot connect, AND exits
  # non-zero. A trailing `|| echo 000` therefore appends a SECOND value and the
  # caller sees "000000" — which is not equal to "000", so every guard that
  # compares against it silently passes. Capture first, then substitute only if
  # nothing came back at all.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "${url}" 2>/dev/null) || true
  [[ -z "${code}" ]] && code="000"

  printf '%s' "${code}"
}

# --------------------------------------------------------------------------------
# Wait for the gateway hostname to resolve
# --------------------------------------------------------------------------------
# A freshly created API Gateway gets a new hostname, and DNS for it is not
# resolvable the instant Terraform returns. On a destroy/apply cycle the first
# curl therefore fails outright.
#
# Polling beats a fixed sleep: a re-apply against an existing gateway continues
# immediately instead of always paying the wait, and a genuinely unreachable
# endpoint reports that rather than being masked by a sleep that was never long
# enough anyway.
# --------------------------------------------------------------------------------
echo "NOTE: Waiting for the gateway endpoint to resolve..."

GW_READY="no"
for attempt in $(seq 1 30); do
  if [[ "$(http_status "${API_BASE}/jobs")" != "000" ]]; then
    GW_READY="yes"
    break
  fi
  echo "NOTE: Not resolving yet (attempt ${attempt}/30) — retrying in 10s..."
  sleep 10
done

if [[ "${GW_READY}" != "yes" ]]; then
  echo "ERROR: ${API_BASE} did not become reachable after 5 minutes."
  echo "ERROR: Check the gateway exists and its hostname resolves:"
  echo "ERROR:   dig +short \$(echo ${API_BASE} | sed 's#https://##')"
  exit 1
fi

echo "NOTE: Verifying unauthenticated requests are rejected..."

for path in "/jobs" "/resumes/00000000-0000-0000-0000-000000000000"; do
  STATUS=$(http_status "${API_BASE}${path}")

  if [[ "${STATUS}" == "401" || "${STATUS}" == "403" ]]; then
    echo "NOTE: Unauthenticated GET ${path} correctly rejected (HTTP ${STATUS})."
  else
    echo "ERROR: Expected 401/403 without a token on ${path}, got HTTP ${STATUS}."
    echo "ERROR: The JWT authenticator may not be enforcing — check api.tf."
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# CORS preflight — PATCH must be allowed
# ------------------------------------------------------------------------------
# /jobs/{id}/notes and /jobs/{id}/folder are the only PATCH routes. If PATCH is
# missing from the deployment's allowed_methods the browser blocks those two
# calls at preflight and nothing else looks wrong, so it is worth asserting.
# ------------------------------------------------------------------------------
echo "NOTE: Verifying CORS preflight allows PATCH..."

# `|| true` because set -o pipefail would otherwise abort the whole script if
# curl hiccups here — a CORS check failing is a warning, not a reason to stop.
ALLOWED=$(curl -s -o /dev/null -D - -X OPTIONS --max-time 10 \
  -H "Origin: https://example.com" \
  -H "Access-Control-Request-Method: PATCH" \
  "${API_BASE}/jobs/test/notes" 2>/dev/null \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-methods"{print $2}' \
  || true)

if [[ "${ALLOWED}" == *"PATCH"* ]]; then
  echo "NOTE: CORS preflight advertises PATCH."
else
  echo "WARN: PATCH not seen in Access-Control-Allow-Methods (got: ${ALLOWED:-none})."
  echo "WARN: Editing job notes and moving jobs between folders will fail in a"
  echo "WARN: browser. Check the cors block in 03-functions/api.tf."
fi

# ------------------------------------------------------------------------------
# Async tier — queue and connector must both exist and be ACTIVE
# ------------------------------------------------------------------------------
# This is the failure the API surface cannot show you. Without a live connector,
# POST /jobs still returns 200 and the job row still appears; it just stays at
# "submitted" forever because nothing drains the queue.
# ------------------------------------------------------------------------------
# --------------------------------------------------------------------------------
# Function: oci_state
#
# Purpose
# Run an OCI CLI query and return its value, or "UNAVAILABLE" if the command
# does not exist in this CLI version.
#
# Both stdout and stderr are discarded on failure. The CLI prints its usage
# banner to STDOUT for an unknown subcommand, so redirecting only stderr
# captures that banner as the "result" and prints a wall of usage text where a
# lifecycle state should be.
#
# Arguments
# - "$@" : full OCI CLI invocation
#
# Returns
# - The queried value, or UNAVAILABLE
# --------------------------------------------------------------------------------
oci_state() {
  local out
  out=$("$@" 2>/dev/null) || return 1
  # A usage banner or empty result is not a lifecycle state.
  if [[ -z "${out}" || "${out}" == Usage:* || "${out}" == *"No such command"* ]]; then
    return 1
  fi
  printf '%s' "${out}"
}

if [[ -n "${QUEUE_ID}" ]]; then
  echo "NOTE: Verifying the scoring queue is ACTIVE..."
  # `oci queue` splits into channels / messages / queue-admin. The control
  # plane (lifecycle state) lives under queue-admin; `messages` is the data
  # plane and knows nothing about whether the queue is ACTIVE.
  QSTATE=$(oci_state oci queue queue-admin get --queue-id "${QUEUE_ID}" \
    --region "${REGION}" \
    --query 'data."lifecycle-state"' --raw-output) || QSTATE="UNAVAILABLE"

  if [[ "${QSTATE}" == "UNAVAILABLE" ]]; then
    echo "WARN: Queue state could not be read in ${REGION} — check the CLI version"
    echo "WARN: and that the queue exists there. Not treated as a failure."
  else
    echo "NOTE: Queue state - ${QSTATE}"
    if [[ "${QSTATE}" != "ACTIVE" ]]; then
      echo "WARN: Queue is not ACTIVE — submitted jobs will not be scored."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Connector Hub — count the ACTIVE connectors, do not just check one
# ------------------------------------------------------------------------------
# A connector invokes its Function serially, so the NUMBER of active connectors
# IS the scoring concurrency. Checking a single one by exact name would pass
# while three of four were broken, and the only symptom would be jobs quietly
# scoring one at a time.
# ------------------------------------------------------------------------------
echo "NOTE: Verifying Connector Hub connectors are ACTIVE..."
COMPARTMENT_ID=$(cd 03-functions && terraform output -raw compartment_id 2>/dev/null || echo "")
EXPECTED=$(cd 03-functions && terraform output -raw worker_concurrency 2>/dev/null || echo "")

if [[ -n "${COMPARTMENT_ID}" ]]; then
  SCACTIVE=$(oci_state oci sch service-connector list --region "${REGION}" --compartment-id "${COMPARTMENT_ID}"     --query 'length(data.items[?starts_with("display-name", `resume-queue-to-worker`) && "lifecycle-state" == `ACTIVE`])'     --raw-output) || SCACTIVE="UNAVAILABLE"

  if [[ "${SCACTIVE}" == "UNAVAILABLE" ]]; then
    echo "WARN: Connector state could not be read in ${REGION} — check the CLI"
    echo "WARN: version and the region. Not treated as a failure."
  else
    echo "NOTE: Active connectors - ${SCACTIVE}${EXPECTED:+ of ${EXPECTED}}"

    if [[ "${SCACTIVE}" == "0" ]]; then
      echo "WARN: No connector is ACTIVE — jobs will sit at 'submitted' forever."
    elif [[ -n "${EXPECTED}" && "${SCACTIVE}" != "${EXPECTED}" ]]; then
      echo "WARN: Fewer connectors than expected — scoring runs at reduced"
      echo "WARN: concurrency (each connector processes one job at a time)."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Summary + manual test instructions
# ------------------------------------------------------------------------------
cat <<EOF

=================================================================================
  Deployment validated (auth enforced)!
=================================================================================
  API   : ${API_BASE}
  Web   : ${WEBAPP_URL}
  Model : ${GENAI_MODEL}

  Manual end-to-end test:
    1. Open the Web URL above and sign in (or sign up).
    2. Add a resume under "Manage Resumes".
    3. Submit a job by URL or by pasting a description.
    4. The row appears as "submitted", moves to "Scoring", then shows a score.
       If it never leaves "submitted", the connector is not draining the queue.
=================================================================================
EOF
