# ==============================================================================
# genai-config.sh
# ==============================================================================
# Single source of truth for the OCI Generative AI model. Sourced by apply.sh,
# destroy.sh and check_env.sh so every script and the worker Function agree on
# which model is in play.
#
# This is the model's DISPLAY NAME, not its OCID. apply.sh resolves it to the
# OCID that name has in the target region and passes THAT to Terraform, because
# the inference endpoint's OnDemandServingMode looks a model up by key: give it
# a display name and scoring fails with a 404 "Entity with key <name> not
# found", long after a deploy that reported success.
#
# The name is what lives in config rather than the OCID because base-model
# OCIDs are region-specific — a literal ocid1.generativeaimodel.oc1.iad.… would
# work in Ashburn and 404 for anyone deploying anywhere else.
#
# GENAI_MODEL_ID flows to:
#   - check_env.sh  pre-flight availability probe (resolves and reports the OCID)
#   - apply.sh      resolved to an OCID, exported as TF_VAR_genai_model_id
#   - validate.sh   readable name for the summary output
#
# ------------------------------------------------------------------------------
# Why Llama 4 and not the obvious choice
# ------------------------------------------------------------------------------
# OCI retires on-demand models aggressively. As of 2026-08-16 in us-ashburn-1:
#   - every Cohere chat model is already on-demand retired
#   - the entire Grok 3 / 4 / 4-fast / code-fast line retired 2026-08-15
#   - there is no Anthropic model at all
#   - Google Gemini is present, but Gemini 2.5 is retiring upstream
# Meta's Llama 4 entries carry no retirement date and have open weights behind
# them, which makes them the most durable choice for a build that has to keep
# working long after it is published.
#
# Before a fresh deploy, confirm the model is still served on demand:
#   T=$(grep -m1 '^tenancy' ~/.oci/config | cut -d= -f2 | tr -d ' ')
#   oci generative-ai model-collection list-models --compartment-id "$T" \
#     --region us-ashburn-1 --output json \
#     | jq -r '.data.items[] | select(.capabilities[]? == "CHAT")
#              | "\(.vendor)  \(."display-name")  \(."time-on-demand-retired")"'
#
# Swap to meta.llama-4-maverick-17b-128e-instruct-fp8 for better scoring
# quality at higher cost — it is a drop-in change, no code edits needed.
# ==============================================================================

export GENAI_MODEL_ID="meta.llama-4-scout-17b-16e-instruct"
