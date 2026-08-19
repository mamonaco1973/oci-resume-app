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
    python3 probe_genai.py                  # probe every CHAT model, timed
    python3 probe_genai.py google           # only names matching a filter
    python3 probe_genai.py --tokens 800     # longer generation, realistic timing
    python3 probe_genai.py --region us-chicago-1   # probe another region
    python3 probe_genai.py --check <name>   # exact one; exit 0 works, 1 does not

    --check is what check_env.sh calls as a pre-flight, so a model that has been
    withdrawn from on-demand fails the deploy instead of failing every scoring
    job later.

    Requires the `oci` Python SDK and a configured ~/.oci/config. If the SDK is
    not on the system python, the OCI CLI ships one:
        PY=$(head -1 ~/bin/oci | sed 's/^#!//; s/ .*//'); "$PY" probe_genai.py
"""

import os
import shutil
import subprocess
import sys
import time

_T0 = time.perf_counter()


def _reexec_with_oci_python():
    """Re-run this script under an interpreter that has the oci SDK.

    The SDK is not usually on the system python — the OCI CLI installs it into
    its own bundled interpreter. Running this file via its shebang therefore
    dies with ModuleNotFoundError even on a machine where the CLI works fine.

    Rather than make the caller remember the interpreter path, locate it: read
    the shebang of whatever `oci` resolves to, then fall back to the standard
    install location. Each candidate is import-tested before exec, so a shell
    wrapper (shebang /bin/bash) is skipped rather than exec'd, and the re-exec
    cannot loop.
    """
    candidates = []

    oci_cli = shutil.which("oci")
    if oci_cli:
        try:
            with open(oci_cli, "r", encoding="utf-8", errors="replace") as fh:
                first = fh.readline()
            if first.startswith("#!"):
                candidates.append(first[2:].strip().split()[0])
        except OSError:
            pass

    candidates += [
        os.path.expanduser("~/lib/oracle-cli/bin/python"),
        os.path.expanduser("~/lib/oracle-cli/bin/python3"),
    ]

    for cand in candidates:
        if not cand or not os.path.isfile(cand) or not os.access(cand, os.X_OK):
            continue
        # find_spec RESOLVES the module without executing it. The obvious
        # test -- "-c import oci" -- would fully load the SDK just to decide
        # whether it exists, and the SDK is slow to import, so the cost would
        # be paid twice: once here and once after the exec.
        probe = subprocess.run(
            [cand, "-c",
             "import importlib.util,sys;"
             "sys.exit(0 if importlib.util.find_spec('oci') else 1)"],
            capture_output=True,
        )
        if probe.returncode == 0:
            os.execv(cand, [cand, os.path.abspath(__file__)] + sys.argv[1:])

    sys.exit(
        "ERROR: the oci Python SDK is not available.\n"
        "  Tried: system python, the shebang of `oci`, "
        "~/lib/oracle-cli/bin/python\n"
        "  Fix with a throwaway venv:\n"
        "    python3 -m venv /tmp/genai "
        "&& /tmp/genai/bin/pip install -q oci "
        "&& /tmp/genai/bin/python probe_genai.py"
    )


try:
    import oci
except ModuleNotFoundError:
    _reexec_with_oci_python()

_T_IMPORT = time.perf_counter() - _T0

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
tenancy = config["tenancy"]

args = sys.argv[1:]

# --region NAME probes a region other than the one in ~/.oci/config, without
# editing the config. Both the control-plane client and the inference endpoint
# are built from config["region"], so overriding it here is sufficient.
#
# NOTE: this only works for a region the tenancy is SUBSCRIBED to. An
# unsubscribed region rejects the call rather than silently returning nothing,
# so a failure here is informative, not ambiguous.
if "--region" in args:
    i = args.index("--region")
    try:
        config["region"] = args[i + 1]
    except IndexError:
        sys.exit("ERROR: --region needs a region, e.g. --region us-chicago-1")
    del args[i:i + 2]

region = config["region"]

# Kept tiny by default: --check runs on every apply.sh as a pre-flight, and a
# liveness test has no reason to generate real output.
PROMPT = "Reply with OK."
MAX_TOKENS = 5

# --tokens N asks for a longer generation, which makes the timings closer to
# what the worker actually experiences (it requests 1500-4000).
if "--tokens" in args:
    i = args.index("--tokens")
    try:
        MAX_TOKENS = int(args[i + 1])
    except (IndexError, ValueError):
        sys.exit("ERROR: --tokens needs a number, e.g. --tokens 800")
    if MAX_TOKENS > 50:
        # A one-word prompt with a big cap just makes the model stop early.
        # Give it something it will actually keep writing about.
        PROMPT = (
            "Write a short paragraph explaining what a resume is, "
            "in plain language."
        )
    del args[i:i + 2]

# --check <name>: verify one exact model and communicate through the exit code
# so a shell pre-flight can gate on it.
check_mode = len(args) >= 2 and args[0] == "--check"
check_name = args[1] if check_mode else None
filters = [] if check_mode else [a.lower() for a in args]

if not check_mode:
    print(f"region     : {region}")
    print(f"tenancy    : {tenancy}")
    print(f"max_tokens : {MAX_TOKENS}")
    print(f"filters    : {filters or '(none — probing all CHAT models)'}\n")

# ------------------------------------------------------------------------------
# List candidates from the control plane
# ------------------------------------------------------------------------------

ctl = GenerativeAiClient(config)

_t = time.perf_counter()
models = ctl.list_models(compartment_id=tenancy).data.items
_T_LIST = time.perf_counter() - _t

candidates = []
for m in models:
    caps = m.capabilities or []
    if "CHAT" not in caps:
        continue
    name = m.display_name or ""
    if check_mode and name != check_name:
        continue
    if filters and not any(f in name.lower() for f in filters):
        continue
    candidates.append(m)

if check_mode and not candidates:
    print(f"NOT LISTED: {check_name} is not a CHAT model in {region}")
    sys.exit(1)

# Deduplicate by display name — the catalog carries multiple versions of some
# models under one name, and probing each is just repeated latency.
seen = set()
unique = []
for m in candidates:
    if m.display_name in seen:
        continue
    seen.add(m.display_name)
    unique.append(m)

if not check_mode:
    print(f"{len(unique)} CHAT model(s) to probe\n")

# ------------------------------------------------------------------------------
# Probe each with a real chat call, timed
# ------------------------------------------------------------------------------
# The timing is comparative, not representative. A few-token generation mostly
# measures connection setup plus time-to-first-token; it does NOT reflect the
# 1500-4000 token generations the worker actually asks for. Use it to rank
# models against each other and to spot ones that are egregiously slow, then
# re-run with --tokens for something closer to real output length.
#
# The first call also carries client and TLS setup, so it reads high. A warm-up
# call against the first model absorbs that rather than unfairly penalising
# whichever model happens to sort first.
# ------------------------------------------------------------------------------

inf = GenerativeAiInferenceClient(
    config,
    service_endpoint=f"https://inference.generativeai.{region}.oci.oraclecloud.com",
    timeout=(10, 120),
)


def build_details(model, tokens):
    """Build a minimal ChatDetails for one model."""
    return ChatDetails(
        compartment_id=tenancy,
        serving_mode=OnDemandServingMode(model_id=model.id),
        chat_request=GenericChatRequest(
            api_format=GenericChatRequest.API_FORMAT_GENERIC,
            messages=[
                Message(role="USER", content=[TextContent(text=PROMPT)])
            ],
            max_tokens=tokens,
            temperature=0,
        ),
    )


# Absorb TLS/client setup so it is not billed to the first model probed. Only
# worth an extra round trip when models are being RANKED against each other --
# for a single model there is nothing to be unfair to, and the warm-up would
# just be latency the user waits through.
if len(unique) > 1 and not check_mode:
    _t = time.perf_counter()
    try:
        inf.chat(build_details(unique[0], 1))
    except Exception:
        pass
    print(f"  warm-up  {time.perf_counter() - _t:7.2f}s  (discarded)\n")

working = []

for m in unique:
    label = f"{m.display_name:<44}"

    t0 = time.perf_counter()
    try:
        inf.chat(build_details(m, MAX_TOKENS))
        elapsed = time.perf_counter() - t0

        if check_mode:
            print(f"OK: {m.display_name} answers on-demand chat ({elapsed:.2f}s)")
            sys.exit(0)
        print(f"  OK    {label} {elapsed:7.2f}s")
        working.append((m.display_name, elapsed))
    except oci.exceptions.ServiceError as exc:
        elapsed = time.perf_counter() - t0
        # 404 here is the interesting one: listed, but not served on demand.
        if check_mode:
            print(f"NOT ON DEMAND: {m.display_name} -> {exc.status} {exc.message}")
            sys.exit(1)
        print(f"  {exc.status:<5} {label} {elapsed:7.2f}s  {exc.message[:44]}")
    except Exception as exc:
        elapsed = time.perf_counter() - t0
        if check_mode:
            print(f"ERROR probing {m.display_name}: {type(exc).__name__}: {exc}")
            sys.exit(1)
        print(f"  ERR   {label} {elapsed:7.2f}s  {type(exc).__name__}")

# ------------------------------------------------------------------------------
# Result — fastest first
# ------------------------------------------------------------------------------

print()
if working:
    working.sort(key=lambda pair: pair[1])
    print(f"On-demand chat works with ({MAX_TOKENS} max_tokens, fastest first):")
    for name, elapsed in working:
        print(f"  {elapsed:7.2f}s  {name}")
    print()
    print("Set one of these as GENAI_MODEL_ID in genai-config.sh.")
    print("Timings rank models; they are not a throughput measure — re-run with")
    print("  --tokens 800   for something closer to real generation length.")
else:
    print("No model answered an on-demand chat call in this region.")
    print("On-demand Generative AI may not be enabled for this tenancy.")
