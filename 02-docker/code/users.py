# ================================================================================
# users.py
#
# Purpose
# Handles user registration and token usage tracking.
#
# Key Responsibilities
# - Enforce the user cap at registration time (returns 403 once full)
# - Track Generative AI token consumption per user in NoSQL
# - Expose GET /usage so the frontend ring indicator can show remaining tokens
#
# NoSQL keys
#   pk = USER#<user_id>
#   sk = USER#USAGE
# ================================================================================

import nosql_util
from common import ok, error, utc_now

TOKEN_LIMIT_DEFAULT = 100_000

# Hard cap — registration is rejected once this many user records exist.
USER_CAP = 100

USAGE_SK = "USER#USAGE"


# --------------------------------------------------------------------------------
# Function: register_user
#
# Purpose
# Idempotent registration endpoint. Creates a user usage record the first time
# a user signs in, and enforces USER_CAP before creating it.
#
# Returns 200 for existing users, 403 with error "user_limit_reached" when the
# cap is hit so the frontend can show the waitlist message and sign out.
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, {"status": "ok"}) or (403, {"error": "user_limit_reached"})
# --------------------------------------------------------------------------------
def register_user(req):
    pk = req.pk

    if nosql_util.get_item(pk, USAGE_SK):
        return ok({"status": "ok"})

    # AWS counts with a DynamoDB scan + Select="COUNT"; OCI NoSQL has no
    # server-side count projection here, so this walks the matching rows. At a
    # cap of 100 that is trivially small, and it runs once per user ever.
    if nosql_util.count_items(USAGE_SK) >= USER_CAP:
        return error(403, "user_limit_reached")

    nosql_util.put_item(pk, USAGE_SK, {
        "tokens_used": 0,
        "token_limit": TOKEN_LIMIT_DEFAULT,
        "created_at":  utc_now(),
    })
    return ok({"status": "ok"})


# --------------------------------------------------------------------------------
# Function: get_usage
#
# Purpose
# Returns the current user's Generative AI token consumption and their limit.
# Returns zero values when no usage record exists yet.
#
# Arguments
# - req : common.Request
#
# Returns
# - (200, {"tokens_used": int, "token_limit": int})
# --------------------------------------------------------------------------------
def get_usage(req):
    item = nosql_util.get_item(req.pk, USAGE_SK)

    if not item:
        return ok({
            "tokens_used": 0,
            "token_limit": TOKEN_LIMIT_DEFAULT,
        })

    return ok({
        "tokens_used": int(item.get("tokens_used", 0) or 0),
        "token_limit": int(
            item.get("token_limit", TOKEN_LIMIT_DEFAULT) or TOKEN_LIMIT_DEFAULT
        ),
    })
