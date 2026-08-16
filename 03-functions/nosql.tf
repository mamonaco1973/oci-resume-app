# ================================================================================
# OCI NoSQL Table
# ================================================================================
# Creates the "notes" table that stores CRUD notes.  The composite primary key
# mirrors the DynamoDB pattern used in the AWS reference implementation:
#   Shard (partition) key: owner — always "global" (no auth in this demo)
#   Sort key            : id    — UUID4 generated per note
#
# Item shape (example):
#   {
#     "owner":      "global",
#     "id":         "<uuid4>",
#     "title":      "<note title>",
#     "note":       "<note body>",
#     "created_at": "<ISO-8601 UTC>",
#     "updated_at": "<ISO-8601 UTC>"
#   }
# ================================================================================

resource "oci_nosql_table" "notes" {
  compartment_id = var.compartment_id
  name           = "notes"

  # DDL declares the full schema.  STRING columns beyond the key are optional
  # in Oracle NoSQL but declared here for documentation clarity.
  ddl_statement = join(" ", [
    "CREATE TABLE IF NOT EXISTS notes (",
    "  owner      STRING,",
    "  id         STRING,",
    "  title      STRING,",
    "  note       STRING,",
    "  created_at STRING,",
    "  updated_at STRING,",
    "  PRIMARY KEY(SHARD(owner), id)",
    ")"
  ])

  # Prevent accidental data loss on terraform destroy in environments where
  # the table may contain real data.  Set to true only for demo teardowns.
  is_auto_reclaimable = false

  table_limits {
    max_read_units     = 50
    max_write_units    = 50
    max_storage_in_gbs = 1
  }
}
