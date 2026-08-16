# ================================================================================
# nosql_util.py
#
# Purpose
# Thin data-access layer over the OCI NoSQL single table. Hides the `doc` JSON
# column so the domain modules see flat items shaped like the DynamoDB items
# they were ported from.
#
# Key Responsibilities
# - Flatten {pk, sk, doc:{...}} rows into {pk, sk, ...attrs} and back
# - Provide get / put / delete / prefix-query against the composite key
# - Page through query results so callers never see a truncated list
#
# Table shape (see 03-functions/nosql.tf)
#   pk  STRING   <user_id>               shard key (bare subject)
#   sk  STRING   RESUME#|JOB#|FOLDER#|USER#USAGE
#   doc JSON     everything else
# ================================================================================

import logging

from oci.nosql import NosqlClient
from oci.nosql.models import QueryDetails, UpdateRowDetails

from common import COMPARTMENT_ID, SIGNER, TABLE_NAME

log = logging.getLogger(__name__)

_client = NosqlClient(config={}, signer=SIGNER)

# OCI NoSQL rejects a composite primary key over 64 bytes. See the budget in
# common.py for how pk and sk are sized to fit.
MAX_KEY_BYTES = 64


def _check_key(pk, sk):
    """Raise before the SDK call if the composite key exceeds the limit.

    The service error for this is KeySizeLimitExceeded on update_row, which
    names a byte count but not which key or which entity produced it. Failing
    here instead reports both, and catches a too-long key on reads as well —
    where the service would otherwise just return no row and the bug would
    present as silently missing data.

    Args:
        pk : Partition key.
        sk : Sort key.

    Raises:
        ValueError: If the combined key is over MAX_KEY_BYTES.
    """
    total = len(str(pk).encode("utf-8")) + len(str(sk).encode("utf-8"))
    if total > MAX_KEY_BYTES:
        raise ValueError(
            f"primary key is {total} bytes, over the {MAX_KEY_BYTES}-byte "
            f"NoSQL limit (pk={len(str(pk))} chars, sk={sk!r}) — see the key "
            f"budget in common.py"
        )


# ================================================================================
# Row shaping
# ================================================================================

def _flatten(row):
    """Turn a stored row into the flat item shape the handlers expect.

    Args:
        row: Raw row value from the SDK, or None.

    Returns:
        dict: {"pk": ..., "sk": ..., **doc}, or {} when the row is absent.
    """
    if not row:
        return {}
    doc = row.get("doc") or {}
    if not isinstance(doc, dict):
        doc = {}
    item = dict(doc)
    item["pk"] = row.get("pk")
    item["sk"] = row.get("sk")
    return item


def _split(pk, sk, item):
    """Build a storable row from a flat item.

    pk/sk are promoted to their own columns and stripped from the payload so
    the key is never duplicated inside `doc`.

    Args:
        pk   : Partition key.
        sk   : Sort key.
        item : Flat attribute dict.

    Returns:
        dict: {"pk": ..., "sk": ..., "doc": {...}}
    """
    doc = {k: v for k, v in item.items() if k not in ("pk", "sk")}
    return {"pk": pk, "sk": sk, "doc": doc}


def _sql_literal(value: str) -> str:
    """Escape a string for inclusion in a NoSQL SQL string literal.

    The values interpolated here come from gateway-verified claims and
    server-generated UUIDs, but they are still concatenated into a SELECT, so
    single quotes are doubled as defence in depth.

    Args:
        value: Raw string to embed between single quotes.

    Returns:
        str: Escaped value, without surrounding quotes.
    """
    return str(value).replace("'", "''")


# ================================================================================
# Single-item operations
# ================================================================================

def get_item(pk, sk):
    """Fetch one item by its full composite key.

    Args:
        pk : Partition key.
        sk : Sort key.

    Returns:
        dict: Flat item, or {} if no such row exists.
    """
    _check_key(pk, sk)
    resp = _client.get_row(
        table_name_or_id=TABLE_NAME,
        key=[f"pk:{pk}", f"sk:{sk}"],
        compartment_id=COMPARTMENT_ID,
    )
    return _flatten(getattr(resp.data, "value", None))


def put_item(pk, sk, item):
    """Insert or overwrite one item.

    Args:
        pk   : Partition key.
        sk   : Sort key.
        item : Flat attribute dict; pk/sk inside it are ignored.
    """
    _check_key(pk, sk)
    _client.update_row(
        table_name_or_id=TABLE_NAME,
        update_row_details=UpdateRowDetails(
            value=_split(pk, sk, item),
            compartment_id=COMPARTMENT_ID,
        ),
    )


def delete_item(pk, sk):
    """Delete one item by its composite key. Missing rows are not an error.

    Args:
        pk : Partition key.
        sk : Sort key.
    """
    _check_key(pk, sk)
    _client.delete_row(
        table_name_or_id=TABLE_NAME,
        key=[f"pk:{pk}", f"sk:{sk}"],
        compartment_id=COMPARTMENT_ID,
    )


def update_doc(pk, sk, mutate):
    """Read an item, apply a mutation, and write it back.

    OCI NoSQL has no partial-update expression for a JSON column, and the
    attachments array needs read-modify-write regardless (the same equality
    fragility that made AWS avoid list_remove). Callers that only touch a few
    fields therefore go through here.

    Args:
        pk     : Partition key.
        sk     : Sort key.
        mutate : Callable taking the flat item and mutating it in place.

    Returns:
        dict: The written item, or {} if the row did not exist.
    """
    item = get_item(pk, sk)
    if not item:
        return {}
    mutate(item)
    put_item(pk, sk, item)
    return item


# ================================================================================
# Queries
# ================================================================================

def _prefix_upper_bound(prefix: str) -> str:
    """Return the exclusive upper bound for a sort-key prefix range.

    Incrementing the final character turns "JOB#" into "JOB$", so the range
    [prefix, bound) selects exactly the keys carrying that prefix. This lets the
    sort key do the filtering in the index instead of pulling every row for the
    user and discarding most of them in Python.

    Args:
        prefix: Sort key prefix, e.g. "JOB#".

    Returns:
        str: Exclusive upper bound for the range.
    """
    return prefix[:-1] + chr(ord(prefix[-1]) + 1)


def query_items(pk, sk_prefix=None):
    """Return every item for one user, optionally narrowed to a sort-key prefix.

    Results are paged through to completion — OCI NoSQL returns a bounded page
    per call, so a single query() would silently truncate once a user
    accumulates enough jobs.

    Args:
        pk        : Partition key.
        sk_prefix : Optional sort key prefix such as "JOB#".

    Returns:
        list[dict]: Flat items, in sort-key order.
    """
    where = f"pk = '{_sql_literal(pk)}'"
    if sk_prefix:
        lo = _sql_literal(sk_prefix)
        hi = _sql_literal(_prefix_upper_bound(sk_prefix))
        where += f" AND sk >= '{lo}' AND sk < '{hi}'"

    statement = f"SELECT * FROM {TABLE_NAME} WHERE {where}"

    items = []
    next_page = None
    while True:
        kwargs = {"opc_next_page": next_page} if next_page else {}
        resp = _client.query(
            query_details=QueryDetails(
                statement=statement,
                compartment_id=COMPARTMENT_ID,
            ),
            **kwargs,
        )
        items.extend(_flatten(r) for r in (resp.data.items or []))

        next_page = (resp.headers or {}).get("opc-next-page")
        if not next_page:
            return items


def count_items(sk_value):
    """Count rows across all users whose sort key equals `sk_value`.

    Used only by the registration cap, which needs a tenancy-wide count of
    USER#USAGE rows. This is a full scan and deliberately not on any hot path —
    it runs once per user, on their first sign-in.

    Args:
        sk_value: Exact sort key to match, e.g. "USER#USAGE".

    Returns:
        int: Number of matching rows.
    """
    statement = (
        f"SELECT * FROM {TABLE_NAME} WHERE sk = '{_sql_literal(sk_value)}'"
    )

    total = 0
    next_page = None
    while True:
        kwargs = {"opc_next_page": next_page} if next_page else {}
        resp = _client.query(
            query_details=QueryDetails(
                statement=statement,
                compartment_id=COMPARTMENT_ID,
            ),
            **kwargs,
        )
        total += len(resp.data.items or [])

        next_page = (resp.headers or {}).get("opc-next-page")
        if not next_page:
            return total
