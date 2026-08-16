#!/bin/bash
# ================================================================================
# File: validate.sh
# ================================================================================
# Purpose:
#   Post-deploy check for the JWT-authenticated Notes API.  Unlike the
#   unauthenticated oci-crud-example, the CRUD endpoints now require a valid
#   Identity Domains token, so an end-to-end curl loop would need an interactive
#   browser login.  Instead this script:
#     1. Confirms the API rejects an UNauthenticated request (proves the JWT
#        authenticator is wired up and enforcing).
#     2. Prints the web app URL and manual test instructions.
#
# Requirements: oci CLI configured, curl, jq, 03-functions/04-webapp TF state.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Discover endpoints from Terraform output
# ------------------------------------------------------------------------------
echo "NOTE: Locating API Gateway endpoint..."
API_BASE=$(cd 03-functions && terraform output -raw api_gateway_endpoint)
WEBAPP_URL=$(cd 04-webapp && terraform output -raw website_url 2>/dev/null || echo "N/A")

echo "NOTE: API Gateway URL - ${API_BASE}"

# ------------------------------------------------------------------------------
# Negative test — an unauthenticated call MUST be rejected by the gateway
# ------------------------------------------------------------------------------
# The gateway validates the JWT before the function runs, so no token → 401
# (some configurations return 403).  Either proves auth is enforced; a 2xx here
# would mean the routes are open and the deploy is broken.
# ------------------------------------------------------------------------------
echo "NOTE: Verifying unauthenticated requests are rejected..."

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE}/notes")

if [[ "${STATUS}" == "401" || "${STATUS}" == "403" ]]; then
  echo "NOTE: Unauthenticated GET /notes correctly rejected (HTTP ${STATUS})."
else
  echo "ERROR: Expected 401/403 without a token, got HTTP ${STATUS}."
  echo "ERROR: The JWT authenticator may not be enforcing — check api.tf."
  exit 1
fi

# ------------------------------------------------------------------------------
# Summary + manual test instructions
# ------------------------------------------------------------------------------
cat <<EOF

=================================================================================
  Deployment validated (auth enforced)!
=================================================================================
  API : ${API_BASE}
  Web : ${WEBAPP_URL}

  Manual end-to-end test:
    1. Open the Web URL above and click "Sign in".
    2. Authenticate with an Identity Domains user, then create/list notes.

  Manual API test with a token (copy id_token from browser sessionStorage):
    JWT="<paste sessionStorage.id_token>"
    curl -H "Authorization: Bearer \$JWT" ${API_BASE}/notes
    curl -X POST -H "Authorization: Bearer \$JWT" \\
      -H "Content-Type: application/json" \\
      -d '{"title":"Hello","note":"World"}' ${API_BASE}/notes
=================================================================================
EOF
