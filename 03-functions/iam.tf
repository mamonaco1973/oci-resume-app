# ================================================================================
# IAM — Dynamic Group and Policies
# ================================================================================
# Four sets of grants are required:
#
# 1. faas service -> OCIR + VCN
#    The Functions runtime pulls the container image and attaches containers to
#    the subnet.  Without these, functions fail with 502 because the container
#    never starts.
#
# 2. Functions -> NoSQL, Object Storage, Queue, Generative AI
#    A Dynamic Group matches every Function in the compartment; the policy gives
#    that group what the api and worker functions need.  The Resource Principal
#    signer in the code relies on this, so no credentials are embedded anywhere.
#
# 3. API Gateway -> Functions
#    A service-principal policy lets the gateway invoke functions.
#
# 4. Connector Hub -> Queue + Functions
#    Lets the connector read the queue and invoke the worker.
#
# Dynamic groups and tenancy-scoped policies must be created in the root
# compartment (var.tenancy_ocid), not in a child compartment.
#
# ------------------------------------------------------------------------------
# PROPAGATION HAZARD — read before debugging any 404 from a function
# ------------------------------------------------------------------------------
# A Function container caches its Resource Principal token, including dynamic
# group membership, at boot.  A container that started before a DG or policy
# below had propagated keeps a groupless token for its entire life and returns
# 404 NotAuthorizedOrNotFound forever, while a container started afterwards
# works — same image, same policy, different boot time.
#
# Worse, the OCI Python SDK classifies 404/NotAuthorizedOrNotFound as TRANSIENT
# and retries it (reasonable, since it is usually this exact propagation delay).
# When the condition is permanent for that container the retry loop burns the
# function timeout, so the first calls hang for the full budget and later ones
# fail instantly once the circuit breaker opens.  One fault, two symptoms.
#
# The fix is to recycle the container, never to keep editing the policy.
# ================================================================================

# --------------------------------------------------------------------------------
# Policy — faas service can pull images from OCIR and attach to the VCN
# --------------------------------------------------------------------------------
resource "oci_identity_policy" "faas_infra" {
  compartment_id = var.tenancy_ocid
  name           = "resume-faas-infra"
  description    = "Allow OCI Functions runtime to pull OCIR images and use VCN"

  statements = [
    "Allow service faas to read repos in tenancy",
    "Allow service faas to use virtual-network-family in compartment id ${var.compartment_id}",
  ]
}

# --------------------------------------------------------------------------------
# Dynamic Group — matches every Function in the compartment
# --------------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "resume_functions" {
  compartment_id = var.tenancy_ocid # Dynamic groups live at the tenancy root
  name           = "resume-functions-dg"
  description    = "OCI Functions in the resume compartment (Resource Principal auth)"

  # ALL{} syntax is required for Identity Domain-enabled tenancies (IDCS backend).
  matching_rule = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_id}'}"
}

# --------------------------------------------------------------------------------
# Policy — what the functions are allowed to touch
# --------------------------------------------------------------------------------
# One policy rather than four so there is a single propagation event to wait on
# rather than four independently-timed ones.
# --------------------------------------------------------------------------------
resource "oci_identity_policy" "functions_runtime" {
  compartment_id = var.tenancy_ocid
  name           = "resume-functions-runtime"
  description    = "Allow resume functions to use NoSQL, Object Storage, Queue and Generative AI"

  statements = [
    # NoSQL — job/resume/folder/usage rows.
    "Allow dynamic-group resume-functions-dg to manage nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group resume-functions-dg to use nosql-tables in compartment id ${var.compartment_id}",

    # Object Storage — resume text, job snapshots, analyses, attachment bytes.
    # manage objects (not buckets): the code never creates or deletes a bucket.
    "Allow dynamic-group resume-functions-dg to manage objects in compartment id ${var.compartment_id}",
    "Allow dynamic-group resume-functions-dg to read buckets in compartment id ${var.compartment_id}",

    # Queue — the api function enqueues; the worker is invoked by Connector Hub
    # and does not read the queue itself, but shares this dynamic group.
    "Allow dynamic-group resume-functions-dg to use queues in compartment id ${var.compartment_id}",

    # Generative AI — the scoring and extraction calls in the worker.
    "Allow dynamic-group resume-functions-dg to use generative-ai-family in compartment id ${var.compartment_id}",
  ]
}

# --------------------------------------------------------------------------------
# Policy — API Gateway can invoke Functions
# --------------------------------------------------------------------------------
# Uses the service principal condition so the API Gateway service identity (not
# a user or instance) is the one allowed to call Functions.
# --------------------------------------------------------------------------------
resource "oci_identity_policy" "apigateway_functions" {
  compartment_id = var.tenancy_ocid
  name           = "resume-apigateway-invoke"
  description    = "Allow API Gateway to invoke resume functions"

  statements = [
    join(" ", [
      "Allow any-user to use functions-family in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'ApiGateway',",
      "  request.resource.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}

# --------------------------------------------------------------------------------
# Policy — Connector Hub can drain the queue and invoke the worker
# --------------------------------------------------------------------------------
# sch.tf depends_on this: the connector begins reading as soon as it is ACTIVE,
# and without the grant already present it fails its reads silently.
# --------------------------------------------------------------------------------
resource "oci_identity_policy" "connector_hub" {
  compartment_id = var.tenancy_ocid
  name           = "resume-connector-hub"
  description    = "Allow Connector Hub to read the Queue and invoke the worker"

  statements = [
    join(" ", [
      "Allow any-user to manage queues in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
    join(" ", [
      "Allow any-user to use functions-family in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}
