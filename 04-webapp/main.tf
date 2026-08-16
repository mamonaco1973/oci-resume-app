# ================================================================================
# Phase 4: Web Application — OCI Object Storage Static Hosting
# ================================================================================
# Deploys the static web client to OCI Object Storage.  Run after 03-functions
# so the API Gateway endpoint is known and injected into index.html.
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

provider "oci" {
  region = var.region
}

variable "compartment_id" {
  description = "OCID of the compartment for the Object Storage bucket"
  type        = string
}

variable "region" {
  description = "OCI region identifier"
  type        = string
}

# The bucket is created in the backend phase (03-functions/storage.tf) so the
# Identity Domains app can register its callback URL.  This phase only uploads.
variable "web_bucket_name" {
  description = "Existing Object Storage bucket to upload the SPA into"
  type        = string
}
