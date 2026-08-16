# ================================================================================
# OCI Logging — Functions Application Resource Logs
# ================================================================================
# Enables resource logs on the Functions Application so that function
# invocation output (stdout/stderr, Python exceptions) is visible in the
# OCI Logging console under the resume-log-group log group.
# ================================================================================

resource "oci_logging_log_group" "resume" {
  compartment_id = var.compartment_id
  display_name   = "resume-log-group"
}

resource "oci_logging_log" "functions" {
  display_name = "resume-functions-log"
  log_group_id = oci_logging_log_group.resume.id
  log_type     = "SERVICE"

  configuration {
    source {
      category    = "invoke"
      resource    = oci_functions_application.resume.id
      service     = "functions"
      source_type = "OCISERVICE"
    }
    compartment_id = var.compartment_id
  }

  is_enabled         = true
  retention_duration = 30
}
