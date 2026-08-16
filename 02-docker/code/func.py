"""func.py — OCI Function entry point for the resume scoring app.

One container image is deployed as two Functions, distinguished by the
FUNCTION_TYPE config value set in Terraform:

    api     Serves all twenty REST routes behind the API Gateway. The gateway
            states which route matched in the X-Route header and injects path
            parameters as X-Job-Id / X-Resume-Id / X-Folder-Id /
            X-Attachment-Id, so this function never parses a URL.
    worker  Invoked by Connector Hub with a batch drained from the Queue.
            Scrapes the posting if needed, calls Generative AI twice, and
            writes the score back.

Authentication:
    API Gateway validates the caller's JWT against the identity domain JWKS
    before any route runs. The gateway forwards the validated Authorization
    header and common.Request decodes the `sub` claim from it, which becomes
    the NoSQL shard key — so users only ever see their own rows.

    The function's own calls to OCI use a Resource Principal signer, so there
    are no secrets in the image.
"""

import io
import json
import logging
import os
import traceback

from fdk import response

import attachments
import folders
import jobs
import resumes
import users
from common import Request, Unauthorized, json_default

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Route table
# ---------------------------------------------------------------------------
# Keys match the X-Route values set per route in 03-functions/api.tf. Keeping
# them in one literal makes the gateway/function contract auditable in a single
# place — a route added on one side and not the other shows up immediately as
# an unknown-route 404 rather than a silent mis-dispatch.
# ---------------------------------------------------------------------------

ROUTES = {
    "register":             users.register_user,
    "usage":                users.get_usage,

    "folders.list":         folders.list_folders,
    "folders.create":       folders.create_folder,
    "folders.delete":       folders.delete_folder,

    "jobs.list":            jobs.list_jobs,
    "jobs.create":          jobs.create_job,
    "jobs.get":             jobs.get_job,
    "jobs.delete":          jobs.delete_job,
    "jobs.notes":           jobs.update_job_notes,
    "jobs.folder":          jobs.move_job_to_folder,

    "attachments.list":     attachments.list_attachments,
    "attachments.upload":   attachments.upload_attachment,
    "attachments.download": attachments.download_attachment,
    "attachments.delete":   attachments.delete_attachment,

    "resumes.list":         resumes.list_resumes,
    "resumes.create":       resumes.create_resume,
    "resumes.get":          resumes.get_resume,
    "resumes.update":       resumes.update_resume,
    "resumes.delete":       resumes.delete_resume,
}


def _resp(ctx, status: int, body) -> response.Response:
    """Build an FDK Response with a JSON payload.

    Args:
        ctx    : FDK invoke context.
        status : HTTP status code.
        body   : JSON-serializable response body.

    Returns:
        fdk.response.Response
    """
    return response.Response(
        ctx,
        status_code=status,
        headers={"Content-Type": "application/json"},
        response_data=json.dumps(body, default=json_default),
    )


def _handle_api(ctx, data: io.BytesIO = None) -> response.Response:
    """Dispatch one API request to its domain handler.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body stream.

    Returns:
        fdk.response.Response
    """
    req = Request(ctx, data)

    handler = ROUTES.get(req.route)
    if handler is None:
        log.warning("unknown route: %r", req.route)
        return _resp(ctx, 404, {"error": "not found"})

    try:
        status, body = handler(req)
    except Unauthorized as exc:
        return _resp(ctx, 401, {"error": str(exc)})

    return _resp(ctx, status, body)


def handler(ctx, data: io.BytesIO = None):
    """OCI Function entry point — dispatches by FUNCTION_TYPE.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body stream.

    Returns:
        fdk.response.Response
    """
    func_type = os.environ.get("FUNCTION_TYPE", "").strip()

    # Catch-all so an unexpected exception returns the real message, and logs a
    # full traceback to OCI Logging, instead of the gateway's opaque 500.
    try:
        if func_type == "api":
            return _handle_api(ctx, data)

        if func_type == "worker":
            # Imported lazily: the worker pulls in BeautifulSoup and the
            # Generative AI client, and the api function should not pay that
            # import cost on every cold start.
            import worker
            return _resp(ctx, 200, worker.handle_batch(data))

        return _resp(ctx, 400, {"error": f"Unknown FUNCTION_TYPE: {func_type}"})

    except Exception as exc:
        log.error(
            "Unhandled error in %s function:\n%s",
            func_type, traceback.format_exc(),
        )
        return _resp(ctx, 500, {"error": f"{type(exc).__name__}: {exc}"})
