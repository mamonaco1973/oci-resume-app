#!/bin/bash
# ================================================================================
# File: 02-docker/build.sh
#
# Purpose:
#   Builds the notes-functions Docker image and pushes it to OCIR.
#   The image tag is a content hash of the source files — any code change
#   produces a new tag, which causes Phase 3 (Terraform) to update the
#   function image attribute.
#
#   On completion, writes IMAGE_PATH=<value> to .build_output so apply.sh
#   can source it and pass the path to Phase 3 as TF_VAR_image_path.
#
# Required env vars (set by apply.sh before this script runs):
#   OCIR_HOST      e.g. us-ashburn-1.ocir.io
#   OCIR_TOKEN     OCI auth token (Docker password)
#   OCIR_USERNAME  namespace/user-ocid
#   NAMESPACE      tenancy object storage namespace
# ================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="${SCRIPT_DIR}/code"
OUTPUT_FILE="${SCRIPT_DIR}/.build_output"

# Content hash of source files — tag changes only when code changes.
IMAGE_TAG=$(cat \
  "${CODE_DIR}/func.py" \
  "${CODE_DIR}/requirements.txt" \
  "${CODE_DIR}/Dockerfile" \
  | sha256sum | cut -d' ' -f1 | cut -c1-8)

IMAGE_PATH="${OCIR_HOST}/${NAMESPACE}/notes-functions:${IMAGE_TAG}"

echo "NOTE: Building Docker image (tag=${IMAGE_TAG})..."
docker build -t "${IMAGE_PATH}" "${CODE_DIR}"

echo "NOTE: Logging in to OCIR at ${OCIR_HOST}..."
# A newly created OCI auth token can take 1-2 minutes to propagate through IAM
# before OCIR accepts it. Poll the login until it succeeds instead of giving up
# after a fixed count. --password-stdin keeps the token out of the process list.
LOGIN_TIMEOUT=300
LOGIN_INTERVAL=15
elapsed=0
until printf '%s' "${OCIR_TOKEN}" | docker login "${OCIR_HOST}" \
        --username "${OCIR_USERNAME}" --password-stdin 2>/dev/null; do
  if [[ "${elapsed}" -ge "${LOGIN_TIMEOUT}" ]]; then
    echo "ERROR: OCIR login still failing after ${LOGIN_TIMEOUT}s — check the token/username."
    exit 1
  fi
  echo "NOTE: OCIR not ready yet (token propagating) — retry in ${LOGIN_INTERVAL}s (${elapsed}/${LOGIN_TIMEOUT}s)..."
  sleep "${LOGIN_INTERVAL}"
  elapsed=$(( elapsed + LOGIN_INTERVAL ))
done
echo "NOTE: OCIR login succeeded."

echo "NOTE: Pushing image to OCIR..."
docker push "${IMAGE_PATH}"

# Write image path for apply.sh to source before running Phase 3.
echo "IMAGE_PATH=${IMAGE_PATH}" > "${OUTPUT_FILE}"

echo "NOTE: Image pushed — ${IMAGE_PATH}"
