# ================================================================================
# OCIR Container Repository
# ================================================================================
# Private repository for the notes-functions image.  Built by 02-docker/build.sh
# after this phase completes.
# ================================================================================

resource "oci_artifacts_container_repository" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-functions"
  is_public      = false
}
