#!/usr/bin/env python3
"""Probe which Generative AI chat models actually work on demand.

Why this exists
    `list-models` returns every model the region's control plane knows about,
    including ones that are only available through a dedicated AI cluster. A
    model can therefore appear ACTIVE, advertise the CHAT capability, carry no
    retirement date, resolve to a valid OCID — and still 404 with "Entity with
    key <ocid> not found" the moment you call chat() with OnDemandServingMode.

    The only reliable test is to make the call. This does exactly that, against
    the same SDK path 02-docker/code/worker.py uses, and reports which models
    answer.

Usage
    python3 probe_genai.py              # probe every CHAT model in the region
    python3 probe_genai.py meta google  # only models whose name matches a filter

    Requires the `oci` Python SDK and a configured ~/.oci/config. If the SDK is
    not on the system python, the OCI CLI ships one:
        ~/lib/oracle-cli/bin/python probe_genai.py
"""

import sys

import oci
from oci.generative_ai import GenerativeAiClient
from oci.generative_ai_inference import GenerativeAiInferenceClient
from oci.generative_ai_inference.models import (
    ChatDetails,
    GenericChatRequest,
    Message,
    OnDemandServingMode,
    TextContent,
)

config = oci.config.from_file()
region = config["region"]
tenancy = config["tenancy"]

filters = [a.lower() for a in sys.argv[1:]]

print(f"region   : {region}")
print(f"tenancy  : {tenancy}")
print(f"filters  : {filters or '(none — probing all CHAT models)'}\n")

# ------------------------------------------------------------------------------
# List candidates from the control plane
# ------------------------------------------------------------------------------

ctl = GenerativeAiClient(config)
models = ctl.list_models(compartment_id=tenancy).data.items

candidates = []
for m in models:
    caps = m.capabilities or []
    if "CHAT" not in caps:
        continue
    name = m.display_name or ""
    if filters and not any(f in name.lower() for f in filters):
        continue
    candidates.append(m)

# Deduplicate by display name — the catalog carries multiple versions of some
# models under one name, and probing each is just repeated latency.
seen = set()
unique = []
for m in candidates:
    if m.display_name in seen:
        continue
    seen.add(m.display_name)
    unique.append(m)

print(f"{len(unique)} CHAT model(s) to probe\n")

# ------------------------------------------------------------------------------
# Probe each with a real, tiny chat call
# ------------------------------------------------------------------------------

inf = GenerativeAiInferenceClient(
    config,
    service_endpoint=f"https://inference.generativeai.{region}.oci.oraclecloud.com",
    timeout=(10, 60),
)

working = []

for m in unique:
    label = f"{m.display_name:<48}"

    chat_request = GenericChatRequest(
        api_format=GenericChatRequest.API_FORMAT_GENERIC,
        messages=[Message(role="USER", content=[TextContent(text="Reply with OK.")])],
        max_tokens=5,
        temperature=0,
    )

    details = ChatDetails(
        compartment_id=tenancy,
        serving_mode=OnDemandServingMode(model_id=m.id),
        chat_request=chat_request,
    )

    try:
        inf.chat(details)
        print(f"  OK    {label}")
        working.append(m.display_name)
    except oci.exceptions.ServiceError as exc:
        # 404 here is the interesting one: listed, but not served on demand.
        print(f"  {exc.status:<5} {label} {exc.message[:60]}")
    except Exception as exc:
        print(f"  ERR   {label} {type(exc).__name__}: {str(exc)[:50]}")

# ------------------------------------------------------------------------------
# Result
# ------------------------------------------------------------------------------

print()
if working:
    print("On-demand chat works with:")
    for name in working:
        print(f"  {name}")
    print(f"\nSet one of these as GENAI_MODEL_ID in genai-config.sh.")
else:
    print("No model answered an on-demand chat call in this region.")
    print("On-demand Generative AI may not be enabled for this tenancy.")
