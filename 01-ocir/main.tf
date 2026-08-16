# ================================================================================
# Phase 1: OCIR — OCI Container Registry Repository
# ================================================================================
# Creates the private container repository that holds the notes-functions image.
# Must run before 02-docker so the repository exists before the image is pushed.
# ================================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
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
  description = "OCID of the compartment where the repository is created"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g., us-ashburn-1)"
  type        = string
}
