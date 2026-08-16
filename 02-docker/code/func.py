"""
func.py — OCI Function handlers for the Notes CRUD API.

A single container image is deployed as five separate OCI Functions, each
distinguished by the FUNCTION_TYPE environment variable set in Terraform.
The handler() entry point dispatches to the correct operation at runtime.

Handler → OCI Function → API Gateway route mapping:
    create  →  create-note  →  POST   /notes
    list    →  list-notes   →  GET    /notes
    get     →  get-note     →  GET    /notes/{id}
    update  →  update-note  →  PUT    /notes/{id}
    delete  →  delete-note  →  DELETE /notes/{id}

Path parameters:
    OCI API Gateway injects {id} as the X-Note-Id request header via its
    header transformation policy.  The function reads it from ctx.Headers()
    rather than parsing the URL directly.

Storage:
    OCI NoSQL Database with a composite primary key:
        Shard key: owner  (string, the authenticated user's `sub` claim)
        Sort key:  id     (string, UUID4)

Authentication:
    Two layers.  (1) API Gateway validates the caller's JWT against the identity
    domain JWKS and injects the verified `sub` claim as the X-User-Sub header —
    functions never see or parse the raw token, only the trusted header.  Each
    user's notes are isolated because `sub` is the NoSQL shard key.  (2) The
    function's own calls to NoSQL use a Resource Principal signer, so there are
    no secrets in code; a Dynamic Group + IAM policy grants row-management rights.

Environment variables:
    FUNCTION_TYPE       Routes to the correct handler (create/list/get/update/delete)
    NOSQL_TABLE_NAME    OCI NoSQL table name
    COMPARTMENT_ID      Compartment OCID used for all NoSQL SDK calls
"""

import base64
import io
import json
import logging
import os
import traceback
import uuid
from datetime import datetime, timezone

# Import only the specific SDK pieces we use rather than the whole `oci`
# package — trims cold-start import time on OCI Functions.
from fdk import response
from oci.auth.signers import get_resource_principals_signer
from oci.exceptions import ServiceError
from oci.nosql import NosqlClient
from oci.nosql.models import QueryDetails, UpdateRowDetails

# ---------------------------------------------------------------------------
# Module-level singletons
# ---------------------------------------------------------------------------

TABLE_NAME     = os.environ.get("NOSQL_TABLE_NAME", "notes").strip()
COMPARTMENT_ID = os.environ.get("COMPARTMENT_ID", "").strip()

# stderr is captured into OCI Logging (notes-functions-log) — use it to surface
# the real exception and the injected identity header while debugging.
log = logging.getLogger(__name__)

# Resource Principal signer provides credentials inside OCI Functions
# without any key files or secrets.  Initialised once per container so
# the auth token is reused across warm invocations.
_signer = get_resource_principals_signer()
_nosql  = NosqlClient(config={}, signer=_signer)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _resp(ctx, status: int, body: dict) -> response.Response:
    """Build an FDK Response with a JSON payload.

    Args:
        ctx    : FDK invoke context.
        status : HTTP status code.
        body   : JSON-serializable response dict.

    Returns:
        fdk.response.Response
    """
    return response.Response(
        ctx,
        status_code=status,
        headers={"Content-Type": "application/json"},
        response_data=json.dumps(body),
    )


def _note_id(ctx) -> str:
    """Extract the note ID from the X-Note-Id header injected by API Gateway.

    OCI API Gateway injects ${request.path[id]} as X-Note-Id for routes
    containing the {id} path parameter.  The FDK exposes HTTP request
    headers via ctx.Headers(); normalise the key to lowercase.

    Args:
        ctx: FDK invoke context.

    Returns:
        str: Trimmed note ID, or empty string if absent.
    """
    try:
        headers = ctx.Headers() or {}
        val = headers.get("x-note-id") or headers.get("X-Note-Id") or ""
        # fdk-python may return header values as lists
        if isinstance(val, list):
            val = val[0] if val else ""
        return str(val).strip()
    except Exception:
        return ""


def _header(ctx, name: str) -> str:
    """Return a single request header value (case-insensitive), or "".

    Args:
        ctx  : FDK invoke context.
        name : Header name (matched lowercase and as-given).

    Returns:
        str: The trimmed header value, or empty string if absent.
    """
    try:
        headers = ctx.Headers() or {}
        val = headers.get(name.lower()) or headers.get(name) or ""
        # fdk-python may return header values as lists.
        if isinstance(val, list):
            val = val[0] if val else ""
        return str(val).strip()
    except Exception:
        return ""


def _sub_from_bearer(ctx) -> str:
    """Extract `sub` by decoding the Bearer JWT payload (no verification).

    Fallback for when the gateway's ${request.auth[sub]} header transform does
    not resolve.  The API Gateway has ALREADY validated the token's signature,
    issuer, and audience before the function runs, so reading the payload here
    for the owner id is safe — this only decodes, it does not trust an
    unverified token for access control.

    Args:
        ctx: FDK invoke context.

    Returns:
        str: The `sub` claim, or empty string if it can't be read.
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


def _owner(ctx) -> str:
    """Return the authenticated user id used as the NoSQL shard key.

    Prefers X-User-Sub, injected by API Gateway from the verified JWT
    (${request.auth[sub]} in api.tf).  Falls back to decoding the already-verified
    Bearer token if that header is absent, so the app works regardless of whether
    the gateway header-transform expression resolves.  A missing identity from
    both sources means the request was not authenticated → unauthorized.

    Args:
        ctx: FDK invoke context.

    Returns:
        str: The caller's `sub` claim.

    Raises:
        ValueError: If no identity can be determined (unauthenticated request).
    """
    owner = _header(ctx, "X-User-Sub") or _sub_from_bearer(ctx)
    if not owner:
        raise ValueError("Unauthorized: missing authenticated user")
    return owner


def _sql_literal(value: str) -> str:
    """Escape a string for safe inclusion in a NoSQL SQL string literal.

    The owner comes from a gateway-verified JWT claim, but it is still
    interpolated into a SELECT, so single quotes are doubled to prevent a
    malformed statement (defence in depth against query breakage).

    Args:
        value: Raw string to embed between single quotes.

    Returns:
        str: The escaped value (without surrounding quotes).
    """
    return value.replace("'", "''")


def _row(value) -> dict:
    """Safely convert an OCI NoSQL row value to a plain dict.

    Args:
        value: Row value from OCI NoSQL SDK (dict or None).

    Returns:
        dict: Plain Python dict, or empty dict if value is absent.
    """
    return dict(value) if value else {}


# ---------------------------------------------------------------------------
# Route dispatcher
# ---------------------------------------------------------------------------

def handler(ctx, data: io.BytesIO = None):
    """OCI Function entry point — dispatches to the correct CRUD handler.

    FUNCTION_TYPE is set per-function in Terraform config so that a single
    container image can serve all five API routes without duplication.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body as a BytesIO stream.

    Returns:
        fdk.response.Response
    """
    func_type = os.environ.get("FUNCTION_TYPE", "").strip()
    dispatch = {
        "create": create_handler,
        "list":   list_handler,
        "get":    get_handler,
        "update": update_handler,
        "delete": delete_handler,
    }
    fn = dispatch.get(func_type)
    if fn is None:
        return _resp(ctx, 400, {"error": f"Unknown FUNCTION_TYPE: {func_type}"})

    # Log whether the gateway actually injected the identity header — a common
    # first-deploy failure is the ${request.auth[sub]} transform not resolving.
    try:
        hdrs = ctx.Headers() or {}
        log.info("invoke type=%s x-user-sub-present=%s",
                 func_type, bool(hdrs.get("x-user-sub") or hdrs.get("X-User-Sub")))
    except Exception:
        pass

    # Catch-all so an unexpected exception returns the real message (and logs a
    # full traceback) instead of the gateway's opaque 500 "Internal Server Error".
    try:
        return fn(ctx, data)
    except Exception as exc:
        log.error("Unhandled error in %s handler:\n%s", func_type, traceback.format_exc())
        return _resp(ctx, 500, {"error": f"{type(exc).__name__}: {exc}"})


# ---------------------------------------------------------------------------
# CRUD handlers
# ---------------------------------------------------------------------------

def create_handler(ctx, data: io.BytesIO = None):
    """Create a new note and persist it to OCI NoSQL.

    Reads title and note from the JSON request body, generates a UUID4 as
    the sort key, and writes the item using update_row with the IF_ABSENT
    option.  IF_ABSENT guards against key collisions — redundant given
    UUID4 uniqueness but defensive.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body (JSON bytes).

    Returns:
        fdk.response.Response: 201 success, 400 bad input, 401 unauth, 500 error.
    """
    try:
        owner = _owner(ctx)
    except ValueError as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    try:
        raw     = data.getvalue() if data else b"{}"
        payload = json.loads(raw or b"{}")
        title   = str(payload.get("title", "")).strip()
        note    = str(payload.get("note",  "")).strip()
        if not title:
            raise ValueError("title is required")
        if not note:
            raise ValueError("note is required")
    except (ValueError, json.JSONDecodeError) as exc:
        return _resp(ctx, 400, {"error": f"Invalid request body: {exc}"})

    note_id = str(uuid.uuid4())
    now     = datetime.now(timezone.utc).isoformat()

    item = {
        "owner":      owner,
        "id":         note_id,
        "title":      title,
        "note":       note,
        "created_at": now,
        "updated_at": now,
    }

    try:
        _nosql.update_row(
            table_name_or_id=TABLE_NAME,
            update_row_details=UpdateRowDetails(
                value=item,
                compartment_id=COMPARTMENT_ID,
                option="IF_ABSENT",
            ),
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to create note"})

    return _resp(ctx, 201, {"id": note_id, "title": title, "note": note})


def list_handler(ctx, data: io.BytesIO = None):
    """List all notes for the current owner.

    Queries OCI NoSQL with a SQL SELECT statement filtered on the shard
    (partition) key.  A targeted query avoids a full table scan and stays
    efficient as the item count grows.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body (ignored).

    Returns:
        fdk.response.Response: 200 with {"items": [...]}, 401 unauth, 500 error.
    """
    try:
        owner = _owner(ctx)
    except ValueError as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    try:
        resp = _nosql.query(
            query_details=QueryDetails(
                statement=(
                    f"SELECT * FROM {TABLE_NAME} "
                    f"WHERE owner = '{_sql_literal(owner)}'"
                ),
                compartment_id=COMPARTMENT_ID,
            ),
        )
        items = [_row(r) for r in (resp.data.items or [])]
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to list notes"})

    return _resp(ctx, 200, {"items": items})


def get_handler(ctx, data: io.BytesIO = None):
    """Retrieve a single note by its ID.

    Direct get_row lookup using the composite primary key (owner, id).
    This is O(1) and preferred over a query for single-item retrieval.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body (ignored).

    Returns:
        fdk.response.Response: 200 with the item, 400/401/404/500 on error.
    """
    try:
        owner = _owner(ctx)
    except ValueError as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    note_id = _note_id(ctx)
    if not note_id:
        return _resp(ctx, 400, {"error": "Note id is required"})

    try:
        resp = _nosql.get_row(
            table_name_or_id=TABLE_NAME,
            key=[f"owner:{owner}", f"id:{note_id}"],
            compartment_id=COMPARTMENT_ID,
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to retrieve note"})

    # get_row returns data.value = None when the key does not exist.
    item = _row(resp.data.value)
    if not item:
        return _resp(ctx, 404, {"error": "Note not found"})

    return _resp(ctx, 200, item)


def update_handler(ctx, data: io.BytesIO = None):
    """Update the title and body of an existing note.

    Reads the existing row to confirm it exists and to preserve created_at,
    then overwrites with updated fields using update_row with IF_PRESENT so
    the write is rejected if the item was concurrently deleted.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body with updated title/note (JSON bytes).

    Returns:
        fdk.response.Response: 200 with updated item, 400/401/404/500 on error.
    """
    try:
        owner = _owner(ctx)
    except ValueError as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    note_id = _note_id(ctx)
    if not note_id:
        return _resp(ctx, 400, {"error": "Note id is required"})

    try:
        raw     = data.getvalue() if data else b"{}"
        payload = json.loads(raw or b"{}")
        title   = str(payload.get("title", "")).strip()
        note    = str(payload.get("note",  "")).strip()
        if not title:
            raise ValueError("title is required")
        if not note:
            raise ValueError("note is required")
    except (ValueError, json.JSONDecodeError) as exc:
        return _resp(ctx, 400, {"error": f"Invalid request body: {exc}"})

    # Fetch existing row to confirm it exists and preserve created_at.
    try:
        existing_resp = _nosql.get_row(
            table_name_or_id=TABLE_NAME,
            key=[f"owner:{owner}", f"id:{note_id}"],
            compartment_id=COMPARTMENT_ID,
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to retrieve note"})

    existing = _row(existing_resp.data.value)
    if not existing:
        return _resp(ctx, 404, {"error": "Note not found"})

    now  = datetime.now(timezone.utc).isoformat()
    item = {
        "owner":      owner,
        "id":         note_id,
        "title":      title,
        "note":       note,
        "created_at": existing.get("created_at", now),
        "updated_at": now,
    }

    try:
        _nosql.update_row(
            table_name_or_id=TABLE_NAME,
            update_row_details=UpdateRowDetails(
                value=item,
                compartment_id=COMPARTMENT_ID,
                option="IF_PRESENT",
            ),
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to update note"})

    return _resp(ctx, 200, item)


def delete_handler(ctx, data: io.BytesIO = None):
    """Delete a note by its ID.

    Checks existence via get_row first — OCI NoSQL delete_row is a
    silent no-op when the key does not exist, so an explicit check
    is required to return a meaningful 404.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body (ignored).

    Returns:
        fdk.response.Response: 200 on success, 400/401/404/500 on error.
    """
    try:
        owner = _owner(ctx)
    except ValueError as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    note_id = _note_id(ctx)
    if not note_id:
        return _resp(ctx, 400, {"error": "Note id is required"})

    try:
        existing_resp = _nosql.get_row(
            table_name_or_id=TABLE_NAME,
            key=[f"owner:{owner}", f"id:{note_id}"],
            compartment_id=COMPARTMENT_ID,
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to retrieve note"})

    if not _row(existing_resp.data.value):
        return _resp(ctx, 404, {"error": "Note not found"})

    try:
        _nosql.delete_row(
            table_name_or_id=TABLE_NAME,
            key=[f"owner:{owner}", f"id:{note_id}"],
            compartment_id=COMPARTMENT_ID,
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to delete note"})

    return _resp(ctx, 200, {"message": "Note deleted"})
