# ================================================================================
# Folders API
#
# Purpose
# Handles CRUD operations for job folder objects.
#
# Design
# - Folder metadata stored in the NoSQL single table alongside jobs/resumes
# - pk = USER#<user_id>, sk = FOLDER#<folder_id>
# - Deleting a folder clears folder_id from any jobs that referenced it, so the
#   jobs survive; only the grouping goes away
# ================================================================================

import uuid

import nosql_util
from common import ok, error, utc_now


# --------------------------------------------------------------------------------
# GET /folders
# --------------------------------------------------------------------------------

def list_folders(req):
    """Return the caller's folders, oldest first."""
    items = nosql_util.query_items(req.pk, "FOLDER#")

    folders = [
        {
            "folder_id": item["sk"].replace("FOLDER#", "", 1),
            "name":       item.get("name", ""),
            "created_at": item.get("created_at", ""),
        }
        for item in items
    ]

    # Sort in Python — the sort key is a UUID, so key order is not time order.
    folders.sort(key=lambda f: f["created_at"])
    return ok(folders)


# --------------------------------------------------------------------------------
# POST /folders
# --------------------------------------------------------------------------------

def create_folder(req):
    """Create a named folder for the caller."""
    name = (req.body.get("name") or "").strip()
    if not name:
        return error(400, "name is required")

    folder_id = str(uuid.uuid4())

    nosql_util.put_item(req.pk, f"FOLDER#{folder_id}", {
        "folder_id":  folder_id,
        "name":       name,
        "created_at": utc_now(),
    })

    return ok({"folder_id": folder_id, "name": name})


# --------------------------------------------------------------------------------
# DELETE /folders/{folder_id}
# --------------------------------------------------------------------------------

def delete_folder(req):
    """Delete a folder and detach any jobs that pointed at it."""
    folder_id = req.folder_id
    if not folder_id:
        return error(400, "folder_id is required")

    pk = req.pk

    # Clear folder_id from any jobs that referenced this folder. Jobs are
    # deliberately kept — losing a folder should never lose scored work.
    for job in nosql_util.query_items(pk, "JOB#"):
        if job.get("folder_id") == folder_id:
            nosql_util.update_doc(
                pk, job["sk"], lambda it: it.pop("folder_id", None)
            )

    nosql_util.delete_item(pk, f"FOLDER#{folder_id}")
    return ok({"deleted": True})
