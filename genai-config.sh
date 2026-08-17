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
# Listing a model tells you NOTHING about whether you can call it
# ------------------------------------------------------------------------------
# `list-models` is the control plane. It returns every model the region knows
# about, including ones available only through a dedicated AI cluster. A model
# can be ACTIVE, advertise the CHAT capability, carry no retirement date, and
# resolve to a perfectly valid OCID — and still fail every chat() call with
# 404 "Entity with key <ocid> not found".
#
# Measured in us-ashburn-1 on 2026-08-17 by calling chat() against every listed
# CHAT model (see probe_genai.py). On-demand actually works with:
#
#     xai.grok-4.3                      <- current pick
#     xai.grok-4.20-reasoning
#     xai.grok-4.20-0309-reasoning
#     xai.grok-4.20-0309-non-reasoning
#     xai.grok-4.20-non-reasoning
#     google.gemini-2.5-flash
#     google.gemini-2.5-pro
#     google.gemini-2.5-flash-lite
#
# Everything else is listed but NOT on demand: all Meta Llama 4, both OpenAI
# gpt-oss sizes, and every Cohere model. There is no Anthropic model at all.
#
# Why grok-4.3 out of those eight: it is the newest (created 2026-05-01) and
# carries no retirement date. The Gemini 2.5 line works today but is retiring
# upstream, and xAI's own older line (grok-3, grok-4, grok-4-fast) retired on
# 2026-08-15 — so recency is the only real signal available.
#
# Alternative: google.gemini-2.5-flash-lite is cheaper and is the exact model
# gcp-resume-app uses, so its prompts port verbatim — at the cost of a known
# upstream sunset. Swapping is a one-line change here; no code edits.
#
# Re-verify before any fresh deploy — do NOT trust the model list:
#     python3 probe_genai.py
# ==============================================================================

export GENAI_MODEL_ID="xai.grok-4.3"
