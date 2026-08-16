# ================================================================================
# OCIR Container Repository
# ================================================================================
# Private repository for the resume-functions image.  Built by 02-docker/build.sh
# after this phase completes.
# ================================================================================

resource "oci_artifacts_container_repository" "resume" {
  compartment_id = var.compartment_id
  display_name   = "resume-functions"
  is_public      = false
}
