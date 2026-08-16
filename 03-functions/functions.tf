# ================================================================================
# OCI Functions Application and Functions
# ================================================================================
# Two functions, both from the same container image, distinguished by the
# FUNCTION_TYPE environment variable that func.py dispatches on:
#
#   api     — every REST route.  Routing is by method + path inside the
#             function, exactly as the AWS API Lambda does, rather than one
#             Function per route.  Twenty routes against five-function-style
#             one-per-operation wiring would mean twenty Function resources and
#             twenty cold-start surfaces for no benefit.
#   worker  — drained from the Queue by Connector Hub (sch.tf).  Runs the
#             scrape + two Generative AI calls, so it gets the long timeout and
#             is never reachable from the gateway.
#
# The image is built and pushed by apply.sh before terraform apply runs;
# var.image_path arrives via TF_VAR_image_path.
# ================================================================================

# --------------------------------------------------------------------------------
# Functions Application — groups both functions on the shared VCN subnet
# --------------------------------------------------------------------------------
resource "oci_functions_application" "resume" {
  compartment_id = var.compartment_id
  display_name   = "resume-app"
  subnet_ids     = [oci_core_subnet.public.id]
}

# --------------------------------------------------------------------------------
# Shared function config — merged with FUNCTION_TYPE per function below
# --------------------------------------------------------------------------------
locals {
  fn_config = {
    NOSQL_TABLE_NAME = oci_nosql_table.resume_app.name
    COMPARTMENT_ID   = var.compartment_id
    BACKEND_BUCKET   = oci_objectstorage_bucket.backend.name
    OS_NAMESPACE     = data.oci_objectstorage_namespace.ns.namespace
    QUEUE_ID         = oci_queue_queue.jobs.id
    QUEUE_ENDPOINT   = oci_queue_queue.jobs.messages_endpoint
  }
}

# --------------------------------------------------------------------------------
# api — serves every REST route behind the API Gateway
# --------------------------------------------------------------------------------
# Timeout is deliberately short.  This function only ever does NoSQL and Object
# Storage work plus a queue put; anything slow belongs in the worker.  A short
# ceiling also stops the OCI SDK's retry loop from silently consuming the whole
# budget when a call is failing (see the retry note in iam.tf).
# --------------------------------------------------------------------------------
resource "oci_functions_function" "api" {
  application_id     = oci_functions_application.resume.id
  display_name       = "resume-api"
  image              = var.image_path
  memory_in_mbs      = "1024"
  timeout_in_seconds = 60
  config             = merge(local.fn_config, { FUNCTION_TYPE = "api" })
}

# --------------------------------------------------------------------------------
# worker — Connector Hub target; scrapes the posting and calls Generative AI
# --------------------------------------------------------------------------------
# 300s matches the AWS worker Lambda.  Two sequential model calls plus an HTTP
# fetch of an arbitrary job posting is well inside that, but the posting fetch is
# the unbounded part, so the headroom is real rather than decorative.
# --------------------------------------------------------------------------------
resource "oci_functions_function" "worker" {
  application_id     = oci_functions_application.resume.id
  display_name       = "resume-worker"
  image              = var.image_path
  memory_in_mbs      = "2048"
  timeout_in_seconds = 300

  config = merge(local.fn_config, {
    FUNCTION_TYPE  = "worker"
    GENAI_MODEL_ID = var.genai_model_id
    GENAI_ENDPOINT = "https://inference.generativeai.${var.region}.oci.oraclecloud.com"
  })
}
