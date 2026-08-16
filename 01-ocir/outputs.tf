# ================================================================================
# Outputs
# ================================================================================

output "repository_name" {
  description = "OCIR repository display name"
  value       = oci_artifacts_container_repository.notes.display_name
}
