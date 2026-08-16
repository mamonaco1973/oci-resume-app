# ================================================================================
# OCI Object Storage — Web Bucket (created in the backend phase)
# ================================================================================
# The bucket lives here, not in 04-webapp, because the Identity Domains app in
# identity.tf must register this bucket's callback URL as an OAuth redirect URI —
# and that URL is only knowable once the bucket name exists.  Phase 04 simply
# uploads objects into the bucket created here (mirrors the aws-cognito-app split
# where the bucket is a backend resource and the webapp phase only uploads).
# ================================================================================

# Namespace is required to build the deterministic Object Storage URL.
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

# Random suffix keeps the bucket name globally unique across re-deploys.
resource "random_id" "web_suffix" {
  byte_length = 4
}

# --------------------------------------------------------------------------------
# Bucket — public read so the SPA can be served without signed URLs
# --------------------------------------------------------------------------------
resource "oci_objectstorage_bucket" "web" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "notes-web-${random_id.web_suffix.hex}"

  # ObjectRead makes every object publicly readable without auth tokens.
  access_type = "ObjectRead"
}

# --------------------------------------------------------------------------------
# Deterministic HTTPS base for hosted objects — reused by the OAuth redirect URIs
# in identity.tf and by the SPA callback flow.  OCI serves each object at:
#   https://objectstorage.{region}.oraclecloud.com/n/{ns}/b/{bucket}/o/{object}
# --------------------------------------------------------------------------------
locals {
  website_base = join("", [
    "https://objectstorage.${var.region}.oraclecloud.com",
    "/n/${data.oci_objectstorage_namespace.ns.namespace}",
    "/b/${oci_objectstorage_bucket.web.name}",
    "/o",
  ])
}
