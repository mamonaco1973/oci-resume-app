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
#     xai.grok-4.3
#     xai.grok-4.20-reasoning
#     xai.grok-4.20-0309-reasoning
#     xai.grok-4.20-0309-non-reasoning
#     xai.grok-4.20-non-reasoning      <- current pick
#     google.gemini-2.5-flash
#     google.gemini-2.5-pro
#     google.gemini-2.5-flash-lite
#
# Everything else is listed but NOT on demand: all Meta Llama 4, both OpenAI
# gpt-oss sizes, and every Cohere model. There is no Anthropic model at all.
#
# Why the NON-REASONING variant. xAI ships reasoning and non-reasoning builds of
# the same model, and neither grok-4.3's name nor the catalog says which mode it
# runs in. Reasoning models spend tokens and wall-clock thinking before they
# answer — worth it for open-ended problems, wasted here: one call extracts
# fields from scraped text, the other scores against a fixed rubric with a fixed
# output shape. Neither benefits from deliberation.
#
# It also makes the four-cloud comparison honest. AWS uses claude-haiku-4-5 and
# GCP uses gemini-2.5-flash-lite — both explicitly the fast/small tier of their
# family. Scoring OCI with a reasoning model against those two would measure the
# model choice, not the platform.
#
# Alternative: google.gemini-2.5-flash-lite is cheaper and is the exact model
# gcp-resume-app uses, so its prompts port verbatim — at the cost of a known
# upstream sunset. Swapping is a one-line change here; no code edits.
#
# Re-verify before any fresh deploy — do NOT trust the model list:
#     python3 probe_genai.py
# ==============================================================================

export GENAI_MODEL_ID="xai.grok-4.20-non-reasoning"
