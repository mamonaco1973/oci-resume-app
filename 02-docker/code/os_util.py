# ================================================================================
# os_util.py
#
# Purpose
# Object Storage access for the private backend bucket — the OCI stand-in for
# the S3 calls in aws-resume-app. Holds every blob too large or too free-form
# for NoSQL.
#
# Key Responsibilities
# - Read/write UTF-8 text and raw bytes by object name
# - Delete single objects and whole prefixes (job teardown)
# - Own the object-name conventions shared by the api and worker functions
#
# Object layout (identical to the AWS backend bucket, so the ported key
# builders needed no changes)
#   users/USER#{id}/resumes/RESUME#{id}.txt
#   users/USER#{id}/jobs/JOB#{id}/job_description.txt
#   users/USER#{id}/jobs/JOB#{id}/resume_snapshot.txt
#   users/USER#{id}/jobs/JOB#{id}/job_analysis.txt
#   users/USER#{id}/jobs/JOB#{id}/attachments/{att_id}/{filename}
# ================================================================================

import logging

from oci.object_storage import ObjectStorageClient

from common import BACKEND_BUCKET, OS_NAMESPACE, SIGNER

log = logging.getLogger(__name__)

_client = ObjectStorageClient(config={}, signer=SIGNER)


# ================================================================================
# Object name builders
# ================================================================================

def resume_key(user_id, resume_id):
    """Object name holding a resume's extracted text."""
    return f"users/USER#{user_id}/resumes/RESUME#{resume_id}.txt"


def job_prefix(user_id, job_id):
    """Common prefix for every object belonging to one job."""
    return f"users/USER#{user_id}/jobs/JOB#{job_id}"


def job_description_key(user_id, job_id):
    """Object name holding the scraped or pasted job description."""
    return f"{job_prefix(user_id, job_id)}/job_description.txt"


def resume_snapshot_key(user_id, job_id):
    """Object name holding the resume text as it was when the job was submitted.

    Snapshotted so a later resume edit cannot retroactively change what a past
    score was computed against.
    """
    return f"{job_prefix(user_id, job_id)}/resume_snapshot.txt"


def job_analysis_key(user_id, job_id):
    """Object name holding the model's written analysis for a job."""
    return f"{job_prefix(user_id, job_id)}/job_analysis.txt"


def notes_key(user_id, job_id):
    """Object name holding the user's free-text notes for a job."""
    return f"{job_prefix(user_id, job_id)}/notes.txt"


def attachment_key(user_id, job_id, attachment_id, filename):
    """Object name for one uploaded attachment."""
    return f"{job_prefix(user_id, job_id)}/attachments/{attachment_id}/{filename}"


# ================================================================================
# Read / write
# ================================================================================

def read_bytes(name):
    """Return an object's raw bytes, or None if it does not exist.

    Args:
        name: Object name.

    Returns:
        bytes | None
    """
    try:
        resp = _client.get_object(
            namespace_name=OS_NAMESPACE,
            bucket_name=BACKEND_BUCKET,
            object_name=name,
        )
        return resp.data.content
    except Exception:
        # A missing blob is an ordinary outcome — a job with no analysis yet,
        # or an attachment already deleted — so callers get None rather than an
        # exception they would all have to catch identically.
        log.info("object not found: %s", name)
        return None


def read_text(name):
    """Return an object's contents decoded as UTF-8, or "" if absent.

    Args:
        name: Object name.

    Returns:
        str
    """
    raw = read_bytes(name)
    if raw is None:
        return ""
    return raw.decode("utf-8", errors="replace")


def write_text(name, text):
    """Write a UTF-8 text object, overwriting any existing object.

    Args:
        name : Object name.
        text : Text to store.
    """
    _client.put_object(
        namespace_name=OS_NAMESPACE,
        bucket_name=BACKEND_BUCKET,
        object_name=name,
        put_object_body=(text or "").encode("utf-8"),
        content_type="text/plain; charset=utf-8",
    )


def write_bytes(name, payload, content_type="application/octet-stream"):
    """Write a binary object, overwriting any existing object.

    Args:
        name         : Object name.
        payload      : Raw bytes.
        content_type : MIME type recorded on the object.
    """
    _client.put_object(
        namespace_name=OS_NAMESPACE,
        bucket_name=BACKEND_BUCKET,
        object_name=name,
        put_object_body=payload,
        content_type=content_type or "application/octet-stream",
    )


# ================================================================================
# Delete
# ================================================================================

def delete_object(name):
    """Delete one object. A missing object is not an error.

    Args:
        name: Object name.
    """
    try:
        _client.delete_object(
            namespace_name=OS_NAMESPACE,
            bucket_name=BACKEND_BUCKET,
            object_name=name,
        )
    except Exception:
        log.info("delete skipped, object absent: %s", name)


def delete_prefix(prefix):
    """Delete every object under a prefix.

    Object Storage has no recursive delete, so deleting a job means listing its
    objects and removing them one at a time. Listing is paged because a job with
    many attachments would otherwise be partially cleaned up, leaving orphaned
    blobs that nothing ever reclaims.

    Args:
        prefix: Object name prefix, e.g. the return of job_prefix().
    """
    start = None
    while True:
        listing = _client.list_objects(
            namespace_name=OS_NAMESPACE,
            bucket_name=BACKEND_BUCKET,
            prefix=prefix,
            start=start,
        )
        for obj in listing.data.objects or []:
            delete_object(obj.name)

        start = getattr(listing.data, "next_start_with", None)
        if not start:
            return
