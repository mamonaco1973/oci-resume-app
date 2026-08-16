# ================================================================================
# OCI Object Storage — web bucket and backend bucket
# ================================================================================
# Two buckets, mirroring the s3-frontend / s3-backend split in aws-resume-app:
#
#   web      public-read, serves the SPA.  Lives in this phase rather than in
#            04-webapp because identity.tf has to register this bucket's
#            callback URL as an OAuth redirect URI, and that URL is only
#            knowable once the bucket name exists.  Phase 04 only uploads.
#   backend  private.  Holds every blob too large or too free-form for NoSQL:
#            resume text, per-job resume snapshots, scraped job descriptions,
#            model analyses, and attachment bytes.
# ================================================================================

# Namespace is required to build deterministic Object Storage URLs.
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

# Random suffix keeps bucket names globally unique across re-deploys.
resource "random_id" "web_suffix" {
  byte_length = 4
}

# --------------------------------------------------------------------------------
# Web bucket — public read so the SPA is served without signed URLs
# --------------------------------------------------------------------------------
resource "oci_objectstorage_bucket" "web" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "resume-web-${random_id.web_suffix.hex}"

  # ObjectRead makes every object publicly readable without auth tokens.
  access_type = "ObjectRead"
}

# --------------------------------------------------------------------------------
# Backend bucket — private; reached only by the functions' Resource Principal
# --------------------------------------------------------------------------------
# Object layout matches the AWS backend bucket so the ported code keeps its key
# builders unchanged:
#   users/USER#{id}/resumes/RESUME#{id}.txt
#   users/USER#{id}/jobs/JOB#{id}/job_description.txt
#   users/USER#{id}/jobs/JOB#{id}/resume_snapshot.txt
#   users/USER#{id}/jobs/JOB#{id}/job_analysis.txt
#   users/USER#{id}/jobs/JOB#{id}/attachments/{att_id}/{filename}
#
# No access_type set — the default is NoPublicAccess. Resume text and uploaded
# attachments are user content and must never be world-readable like the web
# bucket is.
# --------------------------------------------------------------------------------
resource "oci_objectstorage_bucket" "backend" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "resume-backend-${random_id.web_suffix.hex}"
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
