# ================================================================================
# Phase 3: Functions — OCI Functions, NoSQL, Networking, IAM, API Gateway
# ================================================================================
# Deploys all backend infrastructure.  Requires the OCIR image built in Phase 2
# to already exist; image path is supplied via TF_VAR_image_path by apply.sh.
# ================================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Auth uses ~/.oci/config by default (API key mode).
provider "oci" {
  region = var.region
}

# ------------------------------------------------------------------------------
# Home-region alias — required for tenancy-level IAM
# ------------------------------------------------------------------------------
# Policies and dynamic groups are GLOBAL resources with a single master copy in
# the tenancy home region. OCI accepts reads for them anywhere but rejects
# CREATE/UPDATE/DELETE outside home with:
#
#   403-NotAllowed, Please go to your home region IAD to execute CREATE,
#   UPDATE and DELETE operations.
#
# This stack deploys to us-chicago-1 for Generative AI model availability, so
# the default provider cannot write them. Everything else here is regional and
# belongs in var.region; only the five resources in iam.tf use this alias.
#
# Not needed for the Identity Domains app in identity.tf — that one is issued
# against the domain's own idcs-* endpoint, not a regional identity endpoint.
# ------------------------------------------------------------------------------
provider "oci" {
  alias  = "home"
  region = var.home_region
}

# ================================================================================
# Variables
# ================================================================================

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy (root compartment)"
  type        = string
}

variable "compartment_id" {
  description = "OCID of the compartment where all resources are created"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g., us-ashburn-1)"
  type        = string
}

variable "home_region" {
  description = "Tenancy home region — where tenancy-level IAM writes must go"
  type        = string
}

variable "image_path" {
  description = "Full OCIR image path including tag (built by 02-docker/build.sh)"
  type        = string
  default     = ""
}

# Model selection is centralised in genai-config.sh at the repo root and reaches
# Terraform as TF_VAR_genai_model_id, so apply.sh, destroy.sh, check_env.sh and
# the worker Function can never disagree about which model is in play.
#
# Llama 4 rather than the obvious Gemini pick: OCI's model catalog retires
# on-demand models aggressively (the whole Grok 3/4 line went 2026-08-15, and
# every Cohere chat model is already retired), and Gemini 2.5 is retiring
# upstream. Meta's entries carry no retirement date and are open-weight.
# Re-check availability before a fresh deploy:
#   oci generative-ai model-collection list-models --compartment-id <tenancy>
#
# This is the model OCID, not the display name. OnDemandServingMode looks the
# model up by key and a display name 404s at inference time — after a deploy
# that looked entirely successful. apply.sh resolves the readable name in
# genai-config.sh into the OCID it has in the target region.
#
# No default: base-model OCIDs differ per region, so any literal here would be
# silently wrong for anyone deploying elsewhere. Failing at plan time with
# "no value for required variable" is far better than a 404 during scoring.
variable "genai_model_id" {
  description = "OCID of the OCI Generative AI on-demand chat model"
  type        = string
}

# How many Connector Hub connectors drain the scoring queue.
#
# Each connector invokes its target Function serially, so this IS the worker
# concurrency: 4 means at most 4 jobs scoring simultaneously. Oracle's own
# guidance for parallel invocation is to run multiple connectors against one
# queue — there is no autoscaling equivalent, so the number is chosen here
# rather than discovered at runtime.
#
# How this number was arrived at, because it is empirical and not a default:
#   4 with xai.grok-4.3            -> constant 429s from the Generative AI
#                                     on-demand throttle; jobs appeared to
#                                     serialize because the retry turns
#                                     throttling into waiting
#   2 with grok                    -> stable, but only two at a time
#   4 with gemini-2.5-flash-lite   -> fine; the faster model holds its throttle
#                                     slot for far less time, so contention drops
#
# The throttle cannot be queried or raised — OCI applies dynamic throttling, so
# the rate is undocumented and moves with system-wide demand. Watch the worker
# log for "GenAI ... throttled (429)": if those appear, lower this. Workers
# sitting in backoff are worse than fewer workers that actually run.
variable "worker_concurrency" {
  description = "Number of Connector Hub connectors draining the queue (= max concurrent scoring jobs)"
  type        = number
  default     = 4

  validation {
    condition     = var.worker_concurrency >= 1 && var.worker_concurrency <= 20
    error_message = "worker_concurrency must be between 1 and 20."
  }
}
