# ================================================================================
# OCI API Gateway (JWT-authenticated)
# ================================================================================
# Creates a public API Gateway and a deployment with five routes that map
# HTTP methods + paths to the corresponding OCI Functions.
#
# Routes:
#   POST   /notes        → create-note
#   GET    /notes        → list-notes
#   GET    /notes/{id}   → get-note
#   PUT    /notes/{id}   → update-note
#   DELETE /notes/{id}   → delete-note
#
# Authentication (the difference from oci-crud-example):
#   A deployment-level authentication policy validates the JWT the SPA sends in
#   the Authorization header against the identity domain's JWKS.  Every route
#   opts in with an AUTHENTICATION_ONLY authorization policy, so unauthenticated
#   calls are rejected at the gateway before any function runs.
#
# Per-user isolation:
#   The gateway forwards the (now-verified) Authorization header to the function,
#   which decodes the token's `sub` claim and uses it as the NoSQL shard key, so
#   each user only ever sees their own notes.  We deliberately do NOT inject
#   ${request.auth[sub]} as a header — that expression fails to resolve under
#   JWT_AUTHENTICATION and 500s the request before it reaches the function.
#
# Path parameters:
#   For routes containing {id}, a header transformation injects
#   ${request.path[id]} as X-Note-Id (a proven expression).
# ================================================================================

# --------------------------------------------------------------------------------
# API Gateway — public endpoint in the shared subnet
# --------------------------------------------------------------------------------
resource "oci_apigateway_gateway" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-gateway"
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.public.id
}

# --------------------------------------------------------------------------------
# API Deployment — auth policy, routes, CORS, and function backends
# --------------------------------------------------------------------------------
resource "oci_apigateway_deployment" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-api"
  gateway_id     = oci_apigateway_gateway.notes.id
  path_prefix    = "/"

  specification {

    request_policies {

      # CORS — applies to all routes; gateway handles OPTIONS preflight itself.
      cors {
        allowed_origins              = ["*"]
        allowed_methods              = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
        allowed_headers              = ["Content-Type", "content-type", "Authorization", "authorization"]
        exposed_headers              = ["Content-Type"]
        is_allow_credentials_enabled = false
        max_age_in_seconds           = 300
      }

      # --------------------------------------------------------------------------
      # JWT authentication — validates the SPA's ID token against the domain JWKS
      # --------------------------------------------------------------------------
      # VERIFY BEFORE SHIP: `issuers` and `audiences` are config-dependent.
      #   issuers  — decode a real token; Identity Domains usually emits
      #              "https://identity.oraclecloud.com/" (trailing slash), but a
      #              domain-specific issuer can be enabled. Match it exactly.
      #   audiences — set to the app client_id because the SPA sends the ID token
      #              (aud = client_id). If you switch to access tokens + a custom
      #              API scope, change this to that scope's primary audience.
      # --------------------------------------------------------------------------
      authentication {
        type                        = "JWT_AUTHENTICATION"
        token_header                = "Authorization"
        token_auth_scheme           = "Bearer"
        is_anonymous_access_allowed = false

        issuers   = ["https://identity.oraclecloud.com/"]
        audiences = [oci_identity_domains_app.spa.name]

        public_keys {
          type                        = "REMOTE_JWKS"
          uri                         = "${data.oci_identity_domain.target.url}/admin/v1/SigningCert/jwk"
          is_ssl_verify_disabled      = false
          max_cache_duration_in_hours = 1
        }
      }
    }

    # ------------------------------------------------------------------
    # POST /notes — create a new note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes"
      methods = ["POST"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.create_note.id
      }

      request_policies {
        authorization {
          type = "AUTHENTICATION_ONLY"
        }
      }
    }

    # ------------------------------------------------------------------
    # GET /notes — list the caller's notes
    # ------------------------------------------------------------------
    routes {
      path    = "/notes"
      methods = ["GET"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.list_notes.id
      }

      request_policies {
        authorization {
          type = "AUTHENTICATION_ONLY"
        }
      }
    }

    # ------------------------------------------------------------------
    # GET /notes/{id} — retrieve a single note
    # ------------------------------------------------------------------
    # Injects X-Note-Id (path param); owner comes from the forwarded token.
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["GET"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.get_note.id
      }

      request_policies {
        authorization {
          type = "AUTHENTICATION_ONLY"
        }
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------
    # PUT /notes/{id} — update an existing note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["PUT"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.update_note.id
      }

      request_policies {
        authorization {
          type = "AUTHENTICATION_ONLY"
        }
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------
    # DELETE /notes/{id} — delete a note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["DELETE"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.delete_note.id
      }

      request_policies {
        authorization {
          type = "AUTHENTICATION_ONLY"
        }
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }
  }
}
