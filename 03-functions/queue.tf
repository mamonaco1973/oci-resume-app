# ================================================================================
# OCI Queue — async scoring bus
# ================================================================================
# POST /jobs writes the job row with status "submitted", drops a message here,
# and returns immediately.  Connector Hub (sch.tf) drains the queue into the
# worker Function.  This is the OCI stand-in for SQS -> Lambda event source
# mapping in aws-resume-app.
#
# The asynchrony is not a design preference — it is forced.  API Gateway caps a
# request well below what a page scrape plus two model calls takes, so the
# synchronous version of this endpoint cannot exist on any of these platforms.
# ================================================================================

resource "oci_queue_queue" "jobs" {
  compartment_id = var.compartment_id
  display_name   = "resume-job-requests"

  # How long a consumed message stays hidden while the worker runs before it
  # becomes redeliverable.  Must exceed the worker's 300s timeout or a slow
  # scoring run gets handed to a second worker while the first is still going,
  # and the user is billed twice for the same job.  900s leaves real headroom.
  visibility_in_seconds = 900

  # Drop unprocessed messages after a day (matches the AWS queue).
  retention_in_seconds = 86400

  # Default long-poll wait for GetMessages calls that don't specify one.
  timeout_in_seconds = 30

  # After this many delivery attempts the message moves to the companion dead
  # letter queue OCI creates automatically — it is not discarded.  A posting URL
  # that reliably crashes the scraper therefore stops retrying instead of
  # burning model tokens on every redelivery.
  dead_letter_queue_delivery_count = 3
}
