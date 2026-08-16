# ================================================================================
# Outputs
# ================================================================================
# apply.sh reads these after Phase 3 to inject the API base URL into the HTML
# template and to build config.json for the SPA (client_id + domain endpoints),
# then uploads objects into the web bucket created here during Phase 4.
# ================================================================================

output "api_gateway_endpoint" {
  description = "HTTPS base URL for the Notes API (no trailing slash)"
  value       = "https://${oci_apigateway_gateway.notes.hostname}"
}

output "ocir_image_path" {
  description = "Full OCIR path of the deployed function image"
  value       = var.image_path
}

output "nosql_table_name" {
  description = "OCI NoSQL table name"
  value       = oci_nosql_table.notes.name
}

# --- Web hosting (bucket created in storage.tf) --------------------------------

output "web_bucket_name" {
  description = "Object Storage bucket that hosts the SPA (uploaded to in Phase 4)"
  value       = oci_objectstorage_bucket.web.name
}

output "website_url" {
  description = "Direct HTTPS link to the hosted index.html"
  value       = "${local.website_base}/index.html"
}

# --- Identity Domains OAuth app (consumed by the SPA config.json) --------------

output "spa_client_id" {
  description = "OAuth client_id of the SPA app (Identity Domains app 'name')"
  value       = oci_identity_domains_app.spa.name
}

# The OCID (not the client_id) — needed to deactivate the app before destroy,
# since Identity Domains rejects DeleteApp on an active app with a 400.
output "spa_app_id" {
  description = "OCID of the Identity Domains SPA app"
  value       = oci_identity_domains_app.spa.id
}

output "identity_domain_url" {
  description = "Identity domain base URL (authorize/token/JWKS live under this)"
  value       = data.oci_identity_domain.target.url
}
