# ================================================================================
# OCI Logging — Functions Application Resource Logs
# ================================================================================
# Enables resource logs on the Functions Application so that function
# invocation output (stdout/stderr, Python exceptions) is visible in the
# OCI Logging console under the notes-log-group log group.
# ================================================================================

resource "oci_logging_log_group" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-log-group"
}

resource "oci_logging_log" "functions" {
  display_name = "notes-functions-log"
  log_group_id = oci_logging_log_group.notes.id
  log_type     = "SERVICE"

  configuration {
    source {
      category    = "invoke"
      resource    = oci_functions_application.notes.id
      service     = "functions"
      source_type = "OCISERVICE"
    }
    compartment_id = var.compartment_id
  }

  is_enabled         = true
  retention_duration = 30
}
