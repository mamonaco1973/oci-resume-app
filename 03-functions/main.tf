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
# 4 is enough to demonstrate real parallelism without provisioning a fleet.
# Raise it for throughput; each connector is an independent poller.
variable "worker_concurrency" {
  description = "Number of Connector Hub connectors draining the queue (= max concurrent scoring jobs)"
  type        = number
  default     = 4

  validation {
    condition     = var.worker_concurrency >= 1 && var.worker_concurrency <= 20
    error_message = "worker_concurrency must be between 1 and 20."
  }
}
