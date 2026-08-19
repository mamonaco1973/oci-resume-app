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
# ------------------------------------------------------------------------------
# AND what is callable varies BY REGION
# ------------------------------------------------------------------------------
# This is the finding that reshaped the project. Measured with probe_genai.py by
# calling chat() against every listed CHAT model in each region:
#
#   us-ashburn-1   8 work.  No Meta, no OpenAI. Grok wildly erratic --
#                  0.4s to 68s on an identical 5-token request, and WHICH
#                  models were slow changed between runs.
#   us-chicago-1  10 work.  Meta Llama AND OpenAI gpt-oss both answer.
#                  Slowest model 2.6s. No pathological outliers.
#
# Same tenancy, same script, same request. The app therefore deploys to
# us-chicago-1 (see OCI_REGION in apply.sh), not the us-ashburn-1 the other OCI
# projects in this repo use.
#
# Chicago timings at 5 max_tokens, fastest first:
#     0.10s  openai.gpt-oss-120b      <- current pick
#     0.10s  openai.gpt-oss-20b
#     0.12s  meta.llama-4-maverick-17b-128e-instruct-fp8
#     0.26s  meta.llama-4-scout-17b-16e-instruct
#     0.38s  xai.grok-4.20-non-reasoning
#     0.57s  google.gemini-2.5-flash
#     0.77s  google.gemini-2.5-pro
#     2.64s  xai.grok-4.20-reasoning
#
# Why gpt-oss-120b: fastest measured, and open-weight -- no upstream vendor
# retirement schedule hanging over it, unlike Gemini 2.5 (being retired on GCP)
# or the Grok line (ten variants retired on a single day, 2026-08-15).
#
# Swap to openai.gpt-oss-20b for lower cost and probably lower latency on long
# generations, at some quality cost on the scoring call. One line; no code
# changes -- the GenericChatRequest path in worker.py works for every vendor
# here, proven by probe_genai.py.
#
# NOTE: google.gemini-2.5-flash-lite does NOT exist in Chicago. Chicago carries
# flash and pro only. Do not assume a model moves with you across regions.
#
# Re-verify before any fresh deploy -- do NOT trust the model list:
#     ./probe_genai.py --region us-chicago-1
# ==============================================================================

export GENAI_MODEL_ID="openai.gpt-oss-120b"
