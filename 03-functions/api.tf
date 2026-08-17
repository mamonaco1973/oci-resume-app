# ================================================================================
# OCI API Gateway (JWT-authenticated)
# ================================================================================
# One gateway, one deployment, twenty routes — all of them backed by the single
# `api` Function, which dispatches internally exactly as the AWS API Lambda does.
#
# Authentication:
#   A deployment-level policy validates the SPA's JWT against the identity
#   domain's JWKS.  Every route opts in with AUTHENTICATION_ONLY, so
#   unauthenticated calls are rejected at the gateway before any function runs.
#   /register is authenticated too — it runs after sign-in to create the user's
#   usage record and needs the caller's identity to know whose record to make.
#
# Per-user isolation:
#   The gateway forwards the validated Authorization header; the function
#   decodes the `sub` claim and uses it as the NoSQL shard key.  We deliberately
#   do NOT inject ${request.auth[sub]} as a header — that expression fails to
#   resolve under JWT_AUTHENTICATION and 500s the request before it reaches the
#   function.
#
# ------------------------------------------------------------------------------
# Why every route injects X-Route
# ------------------------------------------------------------------------------
# The AWS Lambda dispatches on event["rawPath"] and the HTTP method, both of
# which API Gateway hands it directly.  The OCI FDK has no equivalent guarantee:
# ctx.RequestURL() reflects the backend invoke URL, not the matched route
# template, so reconstructing "/jobs/{job_id}/notes" from it is guesswork that
# breaks the moment the gateway path rewriting changes.
#
# Instead the gateway — which already knows exactly which route matched — states
# it explicitly in an X-Route header, and func.py dispatches on that string.
# The routing authority stays in one place, the function never parses a URL, and
# a mismatch shows up as an obvious unknown-route 404 instead of a subtle
# mis-dispatch.  Path parameters ride along the same way, using the proven
# ${request.path[...]} expression.
# ================================================================================

# --------------------------------------------------------------------------------
# API Gateway — public endpoint in the shared subnet
# --------------------------------------------------------------------------------
resource "oci_apigateway_gateway" "resume" {
  compartment_id = var.compartment_id
  display_name   = "resume-gateway"
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.public.id
}

# --------------------------------------------------------------------------------
# API Deployment — auth policy, routes, CORS, and the single function backend
# --------------------------------------------------------------------------------
resource "oci_apigateway_deployment" "resume" {
  compartment_id = var.compartment_id
  display_name   = "resume-api"
  gateway_id     = oci_apigateway_gateway.resume.id
  path_prefix    = "/"

  specification {

    request_policies {

      # CORS — applies to all routes; the gateway answers OPTIONS preflight
      # itself.  PATCH is required by /jobs/{id}/notes and /jobs/{id}/folder;
      # omitting it fails those two routes at preflight only, which reads like a
      # broken endpoint rather than a CORS problem.
      cors {
        allowed_origins              = ["*"]
        allowed_methods              = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
        allowed_headers              = ["Content-Type", "content-type", "Authorization", "authorization"]
        exposed_headers              = ["Content-Type"]
        is_allow_credentials_enabled = false
        max_age_in_seconds           = 300
      }

      # --------------------------------------------------------------------------
      # JWT authentication — validates the SPA's ID token against the domain JWKS
      # --------------------------------------------------------------------------
      # VERIFY BEFORE SHIP: `issuers` and `audiences` are config-dependent.
      #   issuers   — decode a real token; Identity Domains usually emits
      #               "https://identity.oraclecloud.com/" (trailing slash), but a
      #               domain-specific issuer can be enabled. Match it exactly.
      #   audiences — the app client_id, because the SPA sends the ID token
      #               (aud = client_id). Switching to access tokens + a custom
      #               API scope means changing this to that scope's audience.
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

    # ============================================================================
    # User — registration and token usage
    # ============================================================================

    routes {
      path    = "/register"
      methods = ["POST"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["register"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------------
    # GET /heartbeat — cold-start keep-alive
    # ------------------------------------------------------------------------
    # The SPA pings this on a timer while signed in so the api Function stays
    # warm between user actions. The handler returns immediately without
    # touching NoSQL or Object Storage — polling a real endpoint like /jobs
    # would work too, but would cost a query every minute for nothing.
    #
    # Authenticated like every other route. It only needs to run while someone
    # has the app open, so there is no reason to expose an unauthenticated
    # endpoint that anyone could use to keep the function spinning.
    # ------------------------------------------------------------------------
    routes {
      path    = "/heartbeat"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["heartbeat"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/usage"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["usage"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ============================================================================
    # Folders
    # ============================================================================

    routes {
      path    = "/folders"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["folders.list"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/folders"
      methods = ["POST"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["folders.create"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/folders/{folder_id}"
      methods = ["DELETE"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["folders.delete"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Folder-Id"
              values    = ["$${request.path[folder_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ============================================================================
    # Attachments — declared before /jobs/{job_id} so the more specific paths
    # are unambiguous; the AWS router has the same ordering requirement.
    # ============================================================================

    routes {
      path    = "/jobs/{job_id}/attachments"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["attachments.list"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}/attachments"
      methods = ["POST"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["attachments.upload"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # Two path parameters on one route — the case with no AWS analogue to copy.
    routes {
      path    = "/jobs/{job_id}/attachments/{attachment_id}"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["attachments.download"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Attachment-Id"
              values    = ["$${request.path[attachment_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}/attachments/{attachment_id}"
      methods = ["DELETE"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["attachments.delete"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Attachment-Id"
              values    = ["$${request.path[attachment_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ============================================================================
    # Jobs
    # ============================================================================

    routes {
      path    = "/jobs"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.list"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs"
      methods = ["POST"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.create"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}/notes"
      methods = ["PATCH"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.notes"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}/folder"
      methods = ["PATCH"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.folder"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.get"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/jobs/{job_id}"
      methods = ["DELETE"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["jobs.delete"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Job-Id"
              values    = ["$${request.path[job_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ============================================================================
    # Resumes
    # ============================================================================

    routes {
      path    = "/resumes"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["resumes.list"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/resumes"
      methods = ["POST"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["resumes.create"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/resumes/{resume_id}"
      methods = ["GET"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["resumes.get"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Resume-Id"
              values    = ["$${request.path[resume_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/resumes/{resume_id}"
      methods = ["PUT"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["resumes.update"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Resume-Id"
              values    = ["$${request.path[resume_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    routes {
      path    = "/resumes/{resume_id}"
      methods = ["DELETE"]
      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.api.id
      }
      request_policies {
        authorization { type = "AUTHENTICATION_ONLY" }
        header_transformations {
          set_headers {
            items {
              name      = "X-Route"
              values    = ["resumes.delete"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Resume-Id"
              values    = ["$${request.path[resume_id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }
  }
}
