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
variable "genai_model_id" {
  description = "OCI Generative AI on-demand chat model display name"
  type        = string
  default     = "meta.llama-4-scout-17b-16e-instruct"
}
