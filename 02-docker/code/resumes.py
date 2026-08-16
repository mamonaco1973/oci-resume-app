# ================================================================================
# Resumes API
#
# Handles CRUD operations for user resumes.
#
# Design
# - Resume text is stored in Object Storage
# - Metadata is stored in NoSQL
# - Partition key groups all user objects together
#
# NoSQL keys
#   pk = USER#<user_id>
#   sk = RESUME#<resume_id>
#
# Object Storage path
#   users/USER#<user_id>/resumes/RESUME#<resume_id>.txt
# ================================================================================

import uuid

import nosql_util
import os_util
from common import ok, error, utc_now


# --------------------------------------------------------------------------------
# Function: build_keys
#
# Purpose
# Derives the NoSQL partition key, sort key, and object name for a given user
# and resume ID pair.
#
# Arguments
# - user_id   : authenticated user identifier
# - resume_id : UUID of the resume record
#
# Returns
# - tuple of (pk, sk, object_name)
# --------------------------------------------------------------------------------
def build_keys(user_id, resume_id):
    pk = f"USER#{user_id}"
    sk = f"RESUME#{resume_id}"
    return pk, sk, os_util.resume_key(user_id, resume_id)


# --------------------------------------------------------------------------------
# POST /resumes
#
# Creates a resume record. Stores text in Object Storage, metadata in NoSQL.
# --------------------------------------------------------------------------------

def create_resume(req):

    user_id = req.require_user()

    name        = (req.body.get("name") or "").strip()
    resume_text = (req.body.get("resume") or "").strip()

    if not name:
        return error(400, "name is required")

    if not resume_text:
        return error(400, "resume is required")

    resume_id = str(uuid.uuid4())
    pk, sk, object_name = build_keys(user_id, resume_id)
    now = utc_now()

    os_util.write_text(object_name, resume_text)

    nosql_util.put_item(pk, sk, {
        "name":        name,
        "object_name": object_name,
        "created_at":  now,
        "updated_at":  now,
    })

    return ok({"resume_id": resume_id, "name": name})


# --------------------------------------------------------------------------------
# GET /resumes
#
# Returns metadata for all resumes belonging to the authenticated user.
# --------------------------------------------------------------------------------

def list_resumes(req):

    items = nosql_util.query_items(req.pk, "RESUME#")

    resumes = [
        {
            "resume_id":  item["sk"].replace("RESUME#", "", 1),
            "name":       item.get("name", ""),
            "created_at": item.get("created_at"),
            "updated_at": item.get("updated_at"),
        }
        for item in items
    ]

    return ok(resumes)


# --------------------------------------------------------------------------------
# GET /resumes/{resume_id}
#
# Returns one resume with metadata and full resume text.
# --------------------------------------------------------------------------------

def get_resume(req):

    user_id   = req.require_user()
    resume_id = req.resume_id

    if not resume_id:
        return error(400, "resume_id is required")

    pk, sk, _ = build_keys(user_id, resume_id)

    item = nosql_util.get_item(pk, sk)
    if not item:
        return error(404, "resume not found")

    resume_text = os_util.read_text(item.get("object_name", ""))

    return ok({
        "resume_id":  resume_id,
        "name":       item.get("name", ""),
        "resume":     resume_text,
        "created_at": item.get("created_at"),
        "updated_at": item.get("updated_at"),
    })


# --------------------------------------------------------------------------------
# PUT /resumes/{resume_id}
#
# Replaces resume metadata and text.
#
# Note: editing a resume does NOT rescore past jobs. Each job snapshots the
# resume text it was scored against at submission time, so historical scores
# stay reproducible.
# --------------------------------------------------------------------------------

def update_resume(req):

    user_id   = req.require_user()
    resume_id = req.resume_id

    if not resume_id:
        return error(400, "resume_id is required")

    name        = (req.body.get("name") or "").strip()
    resume_text = (req.body.get("resume") or "").strip()

    if not name:
        return error(400, "name is required")

    if not resume_text:
        return error(400, "resume is required")

    pk, sk, object_name = build_keys(user_id, resume_id)

    item = nosql_util.get_item(pk, sk)
    if not item:
        return error(404, "resume not found")

    os_util.write_text(object_name, resume_text)

    def apply(it):
        it["name"]        = name
        it["object_name"] = object_name
        it["updated_at"]  = utc_now()

    nosql_util.update_doc(pk, sk, apply)

    return ok({"resume_id": resume_id, "name": name})


# --------------------------------------------------------------------------------
# DELETE /resumes/{resume_id}
#
# Deletes the metadata row and the stored resume text.
# --------------------------------------------------------------------------------

def delete_resume(req):

    user_id   = req.require_user()
    resume_id = req.resume_id

    if not resume_id:
        return error(400, "resume_id is required")

    pk, sk, _ = build_keys(user_id, resume_id)

    item = nosql_util.get_item(pk, sk)
    if not item:
        return error(404, "resume not found")

    os_util.delete_object(item.get("object_name", ""))
    nosql_util.delete_item(pk, sk)

    return ok({"resume_id": resume_id, "deleted": True})
