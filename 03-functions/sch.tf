# ================================================================================
# Connector Hub — Queue source -> worker Function target (xN, see below)
# ================================================================================
# OCI's bridge from a queue to compute, and the piece with no real equivalent on
# the other three clouds.  Note what it is NOT: there is no "invoke on message
# arrival" semantic.  The connector polls the queue and flushes a batch when
# either the size or the time threshold is reached, and the timer starts with
# the first message of the batch — so at the default size a single job would sit
# waiting for the FULL window before the worker ever sees it.
#
# batch_time_in_sec cannot be set below 60.  Counting messages is therefore the
# only lever that produces a prompt flush, which is why batch_size_in_num is 1:
# it delivers in 1-2s and makes one invocation equal one job.  Leaving these at
# their defaults is the single most common way to conclude the pipeline is
# broken when it is merely batching.
# ================================================================================

# ------------------------------------------------------------------------------
# WHY THERE ARE SEVERAL OF THESE
# ------------------------------------------------------------------------------
# A single connector invokes its target Function SERIALLY. Oracle's own docs:
#
#   "A connector invokes Functions in a serial synchronous manner. Functions are
#    invoked synchronously with 6 MB of data per invocation. Such invocations are
#    handled sequentially."
#
# So one connector is one worker. Submit two jobs and the second waits for the
# first to finish scoring — visibly different from SQS -> Lambda, Pub/Sub ->
# Eventarc and Service Bus -> Functions, all of which fan out on their own.
#
# batch_size_in_num does NOT help: it controls how many messages ride along in
# one invocation, not how many invocations are in flight. Raising it would just
# make one worker chew through a batch sequentially, and would also delay a lone
# job until the batch filled or the 60s timer expired.
#
# Oracle's recommended workaround is to point MULTIPLE connectors at the same
# queue, which is what count does here. The queue's visibility timeout stops two
# connectors picking up the same message.
#
# The cost of this design is that concurrency is fixed at deploy time: four
# connectors means at most four jobs scoring at once, whether one was submitted
# or forty. There is no scale-to-load equivalent.
# ------------------------------------------------------------------------------
resource "oci_sch_service_connector" "jobs" {
  count = var.worker_concurrency

  compartment_id = var.compartment_id
  display_name   = "resume-queue-to-worker-${count.index + 1}"
  description    = "Drains scoring requests from the Queue into the worker Function"

  # ------------------------------------------------------------------------------
  # Source — the queue, addressed through the plugin interface
  # ------------------------------------------------------------------------------
  # Queue sources are modelled as a connector *plugin* rather than a first-class
  # kind like logging/streaming, so the queue OCID travels inside config_map
  # instead of a dedicated attribute.  config_map is a JSON string in the
  # provider, hence jsonencode rather than a bare map.
  # ------------------------------------------------------------------------------
  source {
    kind        = "plugin"
    plugin_name = "QueueSource"
    config_map  = jsonencode({ queueId = oci_queue_queue.jobs.id })
  }

  # ------------------------------------------------------------------------------
  # Target — the worker function, one message per invocation
  # ------------------------------------------------------------------------------
  # Only one of batch_size_in_kbs / batch_size_in_num may be set.  Messages here
  # are a few hundred bytes, so a KB threshold would never trigger and the 60s
  # time limit would govern every flush.
  # ------------------------------------------------------------------------------
  target {
    kind              = "functions"
    function_id       = oci_functions_function.worker.id
    batch_time_in_sec = 60
    batch_size_in_num = 1
  }

  # The connector starts reading the moment it becomes ACTIVE.  Without the
  # policy already in place its reads fail, and the symptom is a silently dead
  # pipeline rather than an auth error, so the ordering is load-bearing.
  depends_on = [oci_identity_policy.connector_hub]
}
