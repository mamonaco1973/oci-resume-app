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
#     xai.grok-4.20-non-reasoning
#     google.gemini-2.5-flash
#     google.gemini-2.5-pro
#     google.gemini-2.5-flash-lite     <- current pick
#
# Everything else is listed but NOT on demand: all Meta Llama 4, both OpenAI
# gpt-oss sizes, and every Cohere model. There is no Anthropic model at all.
#
# Why Flash-Lite. It is a LATENCY-OPTIMISED tier, the same class as
# claude-haiku-4-5 on AWS — which makes the four-cloud comparison a fair
# like-for-like instead of measuring model choice. Two Grok builds (4.3, then
# 4.20-non-reasoning) both ran slow; dropping reasoning did not fix it, which
# points at the family rather than the reasoning setting.
#
# Note on "Gemini 2.5 is retiring": that is a GCP/Vertex lifecycle event. OCI's
# catalog shows time-deprecated AND time-on-demand-retired null for all three
# google.gemini-2.5-* entries — versus a hard 2026-08-15 on ten Grok entries.
# Gemini on OCI is a separate hosting arrangement with no announced end date.
# (gcp-resume-app pins this model and DOES need a bump — that one is real.)
#
# Alternatives if this proves slow too: xai.grok-4.20-non-reasoning, or
# google.gemini-2.5-flash (a step up from Lite). One line; no code edits — the
# GenericChatRequest path in worker.py already works for every vendor here,
# proven by probe_genai.py.
#
# Re-verify before any fresh deploy — do NOT trust the model list:
#     python3 probe_genai.py
# ==============================================================================

export GENAI_MODEL_ID="google.gemini-2.5-flash-lite"
