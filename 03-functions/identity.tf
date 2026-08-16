# ================================================================================
# OCI IAM Identity Domains — OAuth2 / OIDC app registration
# ================================================================================
# Registers a public SPA client (Authorization Code + PKCE, no client secret) in
# the tenancy's identity domain.  This is the OCI equivalent of the Cognito User
# Pool app client used in aws-cognito-app.  The browser runs the PKCE flow against
# this app, receives an OIDC ID token, and sends it to the API Gateway, which
# validates the token signature against the domain's JWKS before invoking any
# function.  The validated `sub` claim becomes the per-user note owner.
#
# Token model (initial port): the SPA sends the ID TOKEN as the bearer token.
# An ID token's `aud` is deterministically the app client_id, so the gateway can
# validate audience without standing up a custom resource app + scopes.  A later
# iteration can switch to access tokens with a dedicated API scope.
# ================================================================================

variable "domain_display_name" {
  description = "Display name of the identity domain to register the app in"
  type        = string
  default     = "Default"
}

# --------------------------------------------------------------------------------
# Look up the target identity domain to obtain its URL (the idcs_endpoint)
# --------------------------------------------------------------------------------
# The domain URL (https://idcs-<hash>.identity.oraclecloud.com) is required both
# as the idcs_endpoint for the App resource and to build the JWKS URI used by the
# API Gateway JWT authenticator in api.tf.
# --------------------------------------------------------------------------------
data "oci_identity_domains" "all" {
  compartment_id = var.tenancy_ocid
  display_name   = var.domain_display_name
}

data "oci_identity_domain" "target" {
  domain_id = data.oci_identity_domains.all.domains[0].id
}

# --------------------------------------------------------------------------------
# SPA app registration — public OAuth client, Auth Code + PKCE, no secret
# --------------------------------------------------------------------------------
# NOTE: oci_identity_domains_* resources talk to the domain's SCIM /admin/v1 API
# (idcs_endpoint), which is a different surface than the core OCI API.  The
# runner principal needs "Identity Domain Administrator" on the domain.
# --------------------------------------------------------------------------------
resource "oci_identity_domains_app" "spa" {
  idcs_endpoint = data.oci_identity_domain.target.url
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  display_name  = "notes-spa"

  # Well-known template for a custom OAuth application.  If this errors on your
  # provider version, move the string to `well_known_id` instead of `value`.
  based_on_template {
    value = "CustomWebAppTemplateId"
  }

  is_oauth_client = true
  client_type     = "public" # public => no client secret; PKCE required
  active          = true

  # Browser SPA only needs the auth-code exchange plus refresh.
  allowed_grants = ["authorization_code", "refresh_token"]

  # Redirect targets must match the hosted callback / index exactly.  Built from
  # the bucket URL in storage.tf so they track the random-suffixed bucket name.
  redirect_uris             = ["${local.website_base}/callback.html"]
  post_logout_redirect_uris = ["${local.website_base}/index.html"]

  all_url_schemes_allowed = false
}
