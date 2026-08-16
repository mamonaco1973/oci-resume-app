# ================================================================================
# attachments.py
#
# Purpose
# Handles file attachment CRUD for scored jobs.
#
# Key Responsibilities
# - Upload attachments as base64 JSON (no pre-authenticated requests, no
#   multipart) — avoids per-object PAR lifecycle and content-type wrangling
# - Download attachments as base64 JSON
# - Delete attachments from Object Storage and from the job's attachments array
# - Enforce a 5-attachment cap per job and a 10 MB per-file size limit
#
# NoSQL
#   Attachments live as a list inside the job item's JSON document.
#   Delete is read-modify-write: filtering by attachment_id rather than
#   removing by value, which would depend on exact dict equality.
#
# Object Storage layout
#   users/USER#<user_id>/jobs/JOB#<job_id>/attachments/<att_id>/<filename>
# ================================================================================

import base64

import nosql_util
import os_util
from common import ok, error, new_id, user_pk, utc_now

MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024   # 10 MB
MAX_ATTACHMENTS      = 5


def _get_job_item(user_id, job_id):
    """Fetch a job item, or {} when it does not exist."""
    return nosql_util.get_item(user_pk(user_id), f"JOB#{job_id}")


def _save_attachments(pk, job_id, attachments):
    """Persist a replacement attachments list onto the job item."""
    def apply(item):
        item["attachments"] = attachments
        item["updated_at"]  = utc_now()

    nosql_util.update_doc(pk, f"JOB#{job_id}", apply)


# ------------------------------------------------------------------------------
# GET /jobs/{job_id}/attachments
# ------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# Function: list_attachments
#
# Purpose
# Returns the attachments array stored on the job item.
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, [attachment metadata dicts])
# --------------------------------------------------------------------------------
def list_attachments(req):
    user_id = req.require_user()
    job_id  = req.job_id

    item = _get_job_item(user_id, job_id)
    if not item:
        return error(404, "job not found")

    return ok(list(item.get("attachments") or []))


# ------------------------------------------------------------------------------
# POST /jobs/{job_id}/attachments
# ------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# Function: upload_attachment
#
# Purpose
# Decodes base64 file data from the request body, writes it to Object Storage,
# and appends an attachment metadata dict to the job item.
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, attachment metadata dict) on success
# --------------------------------------------------------------------------------
def upload_attachment(req):
    user_id = req.require_user()
    job_id  = req.job_id

    item = _get_job_item(user_id, job_id)
    if not item:
        return error(404, "job not found")

    existing = list(item.get("attachments") or [])
    if len(existing) >= MAX_ATTACHMENTS:
        return error(400, "attachment limit reached (5 max)")

    filename     = (req.body.get("filename") or "").strip()
    content_type = (req.body.get("content_type") or "application/octet-stream").strip()
    data_b64     = req.body.get("data") or ""

    if not filename or not data_b64:
        return error(400, "filename and data are required")

    try:
        raw = base64.b64decode(data_b64)
    except Exception:
        return error(400, "invalid base64 data")

    if len(raw) > MAX_ATTACHMENT_BYTES:
        return error(400, "file exceeds 10 MB limit")

    att_id      = new_id()
    object_name = os_util.attachment_key(user_id, job_id, att_id, filename)

    os_util.write_bytes(object_name, raw, content_type)

    att = {
        "attachment_id": att_id,
        "filename":      filename,
        "content_type":  content_type,
        "size":          len(raw),
        "uploaded_at":   utc_now(),
    }
    existing.append(att)

    _save_attachments(user_pk(user_id), job_id, existing)

    return ok(att)


# ------------------------------------------------------------------------------
# GET /jobs/{job_id}/attachments/{attachment_id}
# ------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# Function: download_attachment
#
# Purpose
# Reads the attachment and returns it base64-encoded in the response body so
# the browser can reconstruct a blob and trigger a download.
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, {"attachment_id", "filename", "content_type", "data"}), data is b64
# --------------------------------------------------------------------------------
def download_attachment(req):
    user_id = req.require_user()
    job_id  = req.job_id
    att_id  = req.attachment_id

    item = _get_job_item(user_id, job_id)
    if not item:
        return error(404, "job not found")

    att = next(
        (a for a in (item.get("attachments") or [])
         if a.get("attachment_id") == att_id),
        None
    )
    if not att:
        return error(404, "attachment not found")

    object_name = os_util.attachment_key(
        user_id, job_id, att_id, att["filename"]
    )
    raw = os_util.read_bytes(object_name)
    if raw is None:
        return error(404, "attachment file not found in storage")

    return ok({
        "attachment_id": att_id,
        "filename":      att["filename"],
        "content_type":  att.get("content_type", "application/octet-stream"),
        "data":          base64.b64encode(raw).decode("utf-8"),
    })


# ------------------------------------------------------------------------------
# DELETE /jobs/{job_id}/attachments/{attachment_id}
# ------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# Function: delete_attachment
#
# Purpose
# Removes the attachment object, then filters it out of the job's attachments
# list by attachment_id (read-modify-write).
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, {"deleted": <attachment_id>})
# --------------------------------------------------------------------------------
def delete_attachment(req):
    user_id = req.require_user()
    job_id  = req.job_id
    att_id  = req.attachment_id

    item = _get_job_item(user_id, job_id)
    if not item:
        return error(404, "job not found")

    attachments = list(item.get("attachments") or [])
    att = next(
        (a for a in attachments if a.get("attachment_id") == att_id),
        None
    )
    if not att:
        return error(404, "attachment not found")

    # Object may already be gone; the metadata still has to be cleaned up or
    # the UI keeps offering a download that can never succeed.
    os_util.delete_object(
        os_util.attachment_key(user_id, job_id, att_id, att["filename"])
    )

    updated = [a for a in attachments if a.get("attachment_id") != att_id]
    _save_attachments(user_pk(user_id), job_id, updated)

    return ok({"deleted": att_id})
