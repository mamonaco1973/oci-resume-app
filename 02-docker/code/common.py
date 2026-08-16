# ================================================================================
# common.py
#
# Purpose
# Shared request/response plumbing and OCI SDK singletons for every handler
# module. This is the only file that knows about the FDK, so the domain modules
# (jobs, resumes, folders, users, attachments) stay ordinary Python.
#
# Key Responsibilities
# - Build the Resource Principal signer and SDK clients once per container
# - Normalise an FDK invocation into a Request object the modules can read
# - Derive the caller identity from the gateway-validated bearer token
# ================================================================================

import base64
import io
import json
import logging
import os
import secrets
from datetime import datetime, timezone

from oci.auth.signers import get_resource_principals_signer

# --------------------------------------------------------------------------------
# Configuration — all injected by Terraform as Function config
# --------------------------------------------------------------------------------

TABLE_NAME     = os.environ.get("NOSQL_TABLE_NAME", "resume_app").strip()
COMPARTMENT_ID = os.environ.get("COMPARTMENT_ID", "").strip()
BACKEND_BUCKET = os.environ.get("BACKEND_BUCKET", "").strip()
OS_NAMESPACE   = os.environ.get("OS_NAMESPACE", "").strip()
QUEUE_ID       = os.environ.get("QUEUE_ID", "").strip()
QUEUE_ENDPOINT = os.environ.get("QUEUE_ENDPOINT", "").strip()

log = logging.getLogger(__name__)

# --------------------------------------------------------------------------------
# Resource Principal signer
# --------------------------------------------------------------------------------
# Built once per container so the token is reused across warm invocations.
#
# The token caches this function's dynamic group membership at container boot.
# If a container started before the DG or its policies had propagated, every SDK
# call it makes returns 404 NotAuthorizedOrNotFound for the container's whole
# life — and the SDK treats that 404 as transient and retries it until the
# function times out. Recycling the container is the fix; editing the policy is
# not. See the propagation note in 03-functions/iam.tf.
# --------------------------------------------------------------------------------

SIGNER = get_resource_principals_signer()


# ================================================================================
# Key construction — and the 64-byte budget it has to fit inside
# ================================================================================
# OCI NoSQL limits the TOTAL primary key (pk + sk) to 64 bytes. DynamoDB allows
# 2048 bytes for the partition key alone, so the single-table key design ported
# from AWS unchanged did not fit: "USER#" + a 22-char subject (27) plus
# "RESUME#" + a 36-char UUID (43) is 70 bytes, and every write failed with
# KeySizeLimitExceeded.
#
# Two changes bring it inside the limit with room to spare:
#
#   1. pk is the bare subject, with no "USER#" prefix. The prefix carried no
#      information — every partition key in this table is a user.
#   2. Entity ids are 20 hex characters instead of a 36-character UUID.
#
# Worst-case budget, assuming a 32-char subject (Identity Domains issues a GUID
# of that length; the observed one is 22):
#
#   pk  32  +  sk "RESUME#" + 20  = 27   ->  59
#   pk  32  +  sk "JOB#"    + 20  = 24   ->  56
#   pk  32  +  sk "FOLDER#" + 20  = 27   ->  59
#   pk  32  +  sk "USER#USAGE"    = 10   ->  42
#
# Anything added to a sort key has to be checked against this. The sort-key
# prefixes are kept readable deliberately — they cost a few bytes and make rows
# legible in the console, which the budget can afford.
# ================================================================================

# 10 bytes -> 20 hex chars, 80 bits. Collision risk across the per-user id
# volumes this app allows (1000 jobs, a handful of resumes and folders) is far
# below anything worth engineering against.
ID_BYTES = 10


def new_id():
    """Return a short, URL-safe unique id for a resume, job, folder or file.

    Deliberately not uuid4(): its 36-character string form does not fit the
    NoSQL primary key budget documented above.

    Returns:
        str: 20 lowercase hex characters.
    """
    return secrets.token_hex(ID_BYTES)


def user_pk(user_id):
    """Return the partition key for a user.

    The key is the subject claim verbatim. This exists as a function rather
    than an inline f-string so the convention has exactly one definition — the
    previous inline "USER#{user_id}" was repeated across six modules, which is
    what made the key-size fix a fourteen-site edit instead of a one-line one.

    Args:
        user_id: The caller's `sub` claim.

    Returns:
        str: The partition key.
    """
    return str(user_id)


# ================================================================================
# Time and JSON helpers
# ================================================================================

def utc_now():
    """Return the current UTC time as a second-resolution ISO-8601 string."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def json_default(value):
    """Fallback JSON encoder for types the stdlib encoder rejects.

    Args:
        value: Object the encoder could not serialise.

    Returns:
        A JSON-safe representation.

    Raises:
        TypeError: If the type is genuinely unsupported.
    """
    if isinstance(value, datetime):
        return value.isoformat()
    raise TypeError(
        f"Object of type {type(value).__name__} is not JSON serializable"
    )


# ================================================================================
# Request
# ================================================================================

def _header(ctx, name: str) -> str:
    """Return a single request header value (case-insensitive), or "".

    Args:
        ctx  : FDK invoke context.
        name : Header name; matched lowercase and as given.

    Returns:
        str: Trimmed header value, or empty string if absent.
    """
    try:
        headers = ctx.Headers() or {}
        val = headers.get(name.lower()) or headers.get(name) or ""
        # fdk-python may hand back header values as lists.
        if isinstance(val, list):
            val = val[0] if val else ""
        return str(val).strip()
    except Exception:
        return ""


def _sub_from_bearer(ctx) -> str:
    """Extract the `sub` claim by decoding the bearer JWT payload.

    API Gateway has ALREADY validated the token's signature, issuer and
    audience before the function runs, so reading the payload here purely to
    learn the owner id is safe. This decodes; it never treats an unverified
    token as grounds for access.

    Args:
        ctx: FDK invoke context.

    Returns:
        str: The `sub` claim, or empty string if it cannot be read.
    """
    auth = _header(ctx, "Authorization")
    if not auth:
        return ""
    token = auth[7:] if auth.lower().startswith("bearer ") else auth
    try:
        payload_b64 = token.split(".")[1]
        # Restore base64url padding before decoding.
        payload_b64 += "=" * (-len(payload_b64) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload_b64))
        return str(claims.get("sub", "")).strip()
    except Exception:
        return ""


class Unauthorized(Exception):
    """Raised when no caller identity can be established."""


class Request:
    """Normalised view of one API invocation.

    The AWS handlers read an API Gateway `event` dict; the FDK gives a context
    plus a body stream instead. This wraps the FDK shape so the ported modules
    read fields rather than digging through either vendor's envelope.

    Attributes:
        route         : Route key injected by the gateway as X-Route.
        user_id       : Caller's `sub` claim; the NoSQL shard key.
        body          : Parsed JSON request body, or {} when absent/invalid.
        job_id        : X-Job-Id path parameter, or "".
        resume_id     : X-Resume-Id path parameter, or "".
        folder_id     : X-Folder-Id path parameter, or "".
        attachment_id : X-Attachment-Id path parameter, or "".
    """

    def __init__(self, ctx, data: io.BytesIO = None):
        self.ctx = ctx
        self.route = _header(ctx, "X-Route")

        self.job_id        = _header(ctx, "X-Job-Id")
        self.resume_id     = _header(ctx, "X-Resume-Id")
        self.folder_id     = _header(ctx, "X-Folder-Id")
        self.attachment_id = _header(ctx, "X-Attachment-Id")

        # An unparseable body is treated as empty; handlers that require fields
        # report the specific missing field rather than a JSON syntax error.
        try:
            raw = data.getvalue() if data else b"{}"
            self.body = json.loads(raw or b"{}")
            if not isinstance(self.body, dict):
                self.body = {}
        except Exception:
            self.body = {}

        self.user_id = _sub_from_bearer(ctx)

    def require_user(self) -> str:
        """Return the caller id, or raise if the request carried no identity.

        Returns:
            str: The caller's `sub` claim.

        Raises:
            Unauthorized: If no identity could be derived.
        """
        if not self.user_id:
            raise Unauthorized("missing authenticated user")
        return self.user_id

    @property
    def pk(self) -> str:
        """Partition key for the caller's rows."""
        return user_pk(self.require_user())


# ================================================================================
# Handler return convention
# ================================================================================
# Domain modules return (status_code, body_dict); func.py converts that into an
# FDK Response. Keeping the modules free of FDK types means they read almost
# identically to their AWS counterparts and can be unit-tested without the SDK.
# ================================================================================

def ok(body):
    """Return a 200 response tuple."""
    return 200, body


def error(code, message):
    """Return an error response tuple with a consistent body shape."""
    return code, {"error": message}
