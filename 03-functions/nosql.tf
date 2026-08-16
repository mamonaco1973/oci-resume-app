# ================================================================================
# OCI NoSQL Table — single-table store for resumes, jobs, folders and usage
# ================================================================================
# Mirrors the DynamoDB single-table design in aws-resume-app: one table, one
# composite key, four logical entity types distinguished by the sort key prefix.
#
#   pk = USER#<user_id>          (shard key — every query is scoped to one user)
#   sk = RESUME#<id>             resume metadata
#        JOB#<id>                job metadata + attachments array
#        FOLDER#<id>             folder name + metadata
#        USER#USAGE              token accounting
#
# Why `doc JSON` rather than a column per attribute:
#   DynamoDB is schemaless, so the four entity types can differ freely and a job
#   can carry a nested `attachments` list.  OCI NoSQL requires a declared schema,
#   so reproducing that shape as columns would mean unioning every field across
#   all four types — and nested arrays still would not fit.  A single JSON
#   payload column keeps the entities heterogeneous, keeps the port close to the
#   AWS original, and leaves the key columns strongly typed so SHARD() still
#   partitions correctly.  Reads/writes go through nosql_util.py, which is the
#   only code that knows `doc` exists.
# ================================================================================

resource "oci_nosql_table" "resume_app" {
  compartment_id = var.compartment_id
  name           = "resume_app"

  ddl_statement = join(" ", [
    "CREATE TABLE IF NOT EXISTS resume_app (",
    "  pk  STRING,",
    "  sk  STRING,",
    "  doc JSON,",
    "  PRIMARY KEY(SHARD(pk), sk)",
    ")"
  ])

  # Table survives an accidental `terraform destroy` of the wider stack; the
  # teardown script empties it explicitly so the removal is always deliberate.
  is_auto_reclaimable = false

  # Sized for the polling read pattern: the SPA re-fetches GET /jobs on a timer
  # while a score is pending, so reads dominate writes. Blob text (job
  # descriptions, analyses, attachments) lives in Object Storage, not here, so
  # storage stays tiny.
  table_limits {
    max_read_units     = 50
    max_write_units    = 50
    max_storage_in_gbs = 2
  }
}
