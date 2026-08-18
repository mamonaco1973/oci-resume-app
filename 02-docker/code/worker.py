# =================================================================================
# worker.py
#
# Purpose
# Connector Hub-driven scoring pipeline. Drains a job request from the Queue,
# obtains the job description (scraping the posting for URL jobs), asks OCI
# Generative AI to extract structured fields and then to score the resume
# against the job, and writes the result back.
#
# Key Responsibilities
# - Unwrap the Connector Hub batch envelope into individual job requests
# - Convert an arbitrary job posting page into clean text
# - Make the two Generative AI calls and parse their JSON defensively
# - Track token consumption and honour the per-user lifetime cap
#
# Why this runs asynchronously at all
# API Gateway's request ceiling is far below what a page fetch plus two model
# calls takes, so the synchronous version of this endpoint cannot exist. The
# queue is not a scaling nicety here; it is the only shape the platform allows.
# =================================================================================

import json
import logging
import random
import re
import time
import urllib.request

from bs4 import BeautifulSoup, Comment

import nosql_util
import os_util
from common import COMPARTMENT_ID, SIGNER, user_pk, utc_now

from oci.exceptions import ServiceError
from oci.generative_ai_inference import GenerativeAiInferenceClient
from oci.generative_ai_inference.models import (
    ChatDetails,
    GenericChatRequest,
    Message,
    OnDemandServingMode,
    TextContent,
)

import os

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# =================================================================================
# Environment
# =================================================================================

GENAI_MODEL_ID = os.environ.get("GENAI_MODEL_ID", "").strip()
GENAI_ENDPOINT = os.environ.get("GENAI_ENDPOINT", "").strip()

TOKEN_LIMIT_DEFAULT = 100_000

# =================================================================================
# Generative AI client
# =================================================================================
# Inference lives on its own regional endpoint rather than the generic OCI one,
# so service_endpoint is required.
#
# The read timeout is set below the function's 300s ceiling so a slow or hung
# model call raises a catchable exception and the job can be marked Error —
# rather than the platform killing the container mid-call and leaving the job
# stuck at "Scoring" forever with nothing to explain why.
# =================================================================================

_genai = GenerativeAiInferenceClient(
    config={},
    signer=SIGNER,
    service_endpoint=GENAI_ENDPOINT,
    timeout=(10, 240),
)

# =================================================================================
# Constants
# =================================================================================

# Throttling: OCI Generative AI caps concurrent on-demand inference per model,
# and several connectors scoring at once will hit it. Sleeps total ~45s worst
# case, which leaves room for two model calls inside the 300s function timeout.
THROTTLE_MAX_ATTEMPTS = 5
THROTTLE_BASE_DELAY   = 3.0

MAX_SOURCE_TEXT_CHARS = 120000
MIN_JOB_TEXT_CHARS = 100

# Tags that generally do not contain useful job-description content.
REMOVE_TAGS = {
    "script", "style", "noscript", "svg", "img", "picture", "source",
    "video", "audio", "canvas", "iframe", "object", "embed", "form",
    "input", "button", "select", "option", "textarea", "label", "nav",
    "footer",
}

# Tags that should introduce visible spacing in extracted text.
BLOCK_TAGS = {
    "p", "div", "section", "article", "main", "aside", "header", "li",
    "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr", "table",
}


# =================================================================================
# Generic helpers
# =================================================================================


def safe_status_message(message, max_len=500):
    """Keep status_message short enough for predictable storage and UI use."""
    message = str(message).strip()

    if len(message) <= max_len:
        return message

    return message[: max_len - 3] + "..."


def strip_code_fences(text):
    """Remove Markdown code fences if the model returns fenced JSON."""
    text = text.strip()

    if not text.startswith("```"):
        return text

    lines = text.splitlines()

    if lines:
        lines = lines[1:]

    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]

    return "\n".join(lines).strip()


def parse_json_object(text):
    """Parse the first complete JSON object out of a model response.

    Claude reliably returns bare JSON when told to. Llama is looser: it will
    sometimes prepend "Here is the JSON:" or append a closing remark despite
    instructions, and json.loads on the whole string then fails on output that
    is otherwise perfectly good. Slicing from the first brace to the last is
    enough to recover those cases without masking genuinely malformed output.

    Args:
        text: Raw model response text.

    Returns:
        dict: The parsed object.

    Raises:
        ValueError: If no parseable JSON object is present.
    """
    cleaned = strip_code_fences(str(text or "").strip())

    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("model response contained no JSON object")

    try:
        parsed = json.loads(cleaned[start:end + 1])
    except json.JSONDecodeError as exc:
        raise ValueError(f"model returned unparseable JSON: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ValueError("model response was not a JSON object")

    return parsed


# =================================================================================
# NoSQL helpers
# =================================================================================


def is_over_token_limit(user_id):
    """Return True if the user has exhausted their lifetime token allowance.

    Re-checked at worker time because several jobs may have been queued before
    the API submission check ran out of budget.
    """
    try:
        item = nosql_util.get_item(user_pk(user_id), "USER#USAGE") or {}
        used = int(item.get("tokens_used", 0) or 0)
        limit = int(
            item.get("token_limit", TOKEN_LIMIT_DEFAULT) or TOKEN_LIMIT_DEFAULT
        )
        return used >= limit
    except Exception:
        # On read failure, allow processing to continue.
        return False


def accumulate_tokens(user_id, input_tokens, output_tokens):
    """Add consumed tokens to the user's lifetime usage record.

    Read-modify-write rather than an atomic add: OCI NoSQL has no increment
    expression for a field inside a JSON column. Concurrent scoring runs for
    one user can therefore lose an update, which is acceptable because this
    drives a usage indicator and a soft cap, not billing.
    """
    total = int(input_tokens or 0) + int(output_tokens or 0)
    if total <= 0:
        return

    try:
        pk = user_pk(user_id)

        def apply(item):
            item["tokens_used"] = int(item.get("tokens_used", 0) or 0) + total

        # Create the record if the user somehow has none, so usage is never
        # silently discarded.
        if not nosql_util.update_doc(pk, "USER#USAGE", apply):
            nosql_util.put_item(pk, "USER#USAGE", {
                "tokens_used": total,
                "token_limit": TOKEN_LIMIT_DEFAULT,
                "created_at":  utc_now(),
            })
    except Exception:
        # Token tracking is best-effort — never let it block job completion.
        logger.exception(
            "Failed to update token usage. user_id=%s tokens=%s",
            user_id, total,
        )


def update_job_status(user_id, job_id, status, status_message):
    """Update the top-level processing status for a job."""
    def apply(item):
        item["status"] = status
        item["status_message"] = status_message
        item["updated_at"] = utc_now()

    nosql_util.update_doc(user_pk(user_id), f"JOB#{job_id}", apply)


def update_job_title_and_company(user_id, job_id, job_title, company_name):
    """Write job_title and company as soon as extraction completes.

    Done before scoring so the row stops reading as an anonymous "submitted"
    entry while the slower scoring call is still running.
    """
    def apply(item):
        item["job_title"] = job_title
        item["company"] = company_name
        item["updated_at"] = utc_now()

    nosql_util.update_doc(user_pk(user_id), f"JOB#{job_id}", apply)


def update_job_extracted_fields(user_id, job_id, job_title, company_name,
                                job_description_key, score):
    """Save extracted job metadata and the numeric score back to the job."""
    def apply(item):
        item["job_title"] = job_title
        item["company"] = company_name
        item["job_description_key"] = job_description_key
        item["score"] = score
        item["updated_at"] = utc_now()

    nosql_util.update_doc(user_pk(user_id), f"JOB#{job_id}", apply)


# =================================================================================
# URL retrieval helpers
# =================================================================================


def fetch_url_html(url):
    """Retrieve raw HTML from a job posting URL.

    A browser-like User-Agent improves compatibility with some job sites.
    """
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            )
        },
    )

    with urllib.request.urlopen(request, timeout=30) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


# =================================================================================
# HTML cleanup helpers
# =================================================================================


def collapse_whitespace(text):
    """Normalize whitespace so the text is easier for the model to process."""
    text = text.replace("\r", "\n")
    text = re.sub(r"[ \t\f\v]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def is_hidden(tag):
    """Detect common hidden-element patterns."""
    if not getattr(tag, "attrs", None):
        return False

    if "hidden" in tag.attrs:
        return True

    style = str(tag.attrs.get("style", "")).lower()
    if "display:none" in style or "display: none" in style:
        return True

    if "visibility:hidden" in style or "visibility: hidden" in style:
        return True

    aria_hidden = str(tag.attrs.get("aria-hidden", "")).lower()
    if aria_hidden == "true":
        return True

    return False


def remove_unwanted_nodes(soup):
    """Remove comments, junk tags, and hidden elements."""
    for comment in soup.find_all(string=lambda s: isinstance(s, Comment)):
        comment.extract()

    for tag_name in REMOVE_TAGS:
        for tag in soup.find_all(tag_name):
            tag.decompose()

    for tag in soup.find_all(True):
        if is_hidden(tag):
            tag.decompose()


def add_block_separators(soup):
    """Add newline spacing around block-like elements before text extraction."""
    for tag in soup.find_all(BLOCK_TAGS):
        if tag.name == "br":
            tag.replace_with("\n")
            continue

        if tag.string is not None:
            tag.insert_before("\n")
            tag.insert_after("\n")


def extract_visible_text(html):
    """Convert HTML into a cleaned text payload for model extraction."""
    soup = BeautifulSoup(html, "html.parser")

    remove_unwanted_nodes(soup)
    add_block_separators(soup)

    parts = []

    title_tag = soup.find("title")
    if title_tag:
        title_text = collapse_whitespace(title_tag.get_text(" ", strip=True))
        if title_text:
            parts.append(f"PAGE TITLE: {title_text}")

    meta_desc = soup.find("meta", attrs={"name": "description"})
    if meta_desc and meta_desc.get("content"):
        meta_text = collapse_whitespace(str(meta_desc["content"]))
        if meta_text:
            parts.append(f"META DESCRIPTION: {meta_text}")

    body = soup.body or soup
    body_text = body.get_text(separator="\n", strip=True)
    body_text = collapse_whitespace(body_text)

    if body_text:
        parts.append("VISIBLE TEXT:")
        parts.append(body_text)

    return "\n\n".join(parts).strip()


# =================================================================================
# Generative AI helpers
# =================================================================================


def _extract_usage(chat_response, prompt_text, output_text):
    """Return (input_tokens, output_tokens) for one chat response.

    OCI does not report usage consistently across model families, and the
    field has moved between SDK versions. Rather than let the usage ring go
    blank when it is absent, fall back to a coarse chars/4 estimate — the cap
    it feeds is a guard rail, so an approximate number is far better than none.

    Args:
        chat_response : The SDK's chat_response object.
        prompt_text   : Prompt that was sent, for the fallback estimate.
        output_text   : Text that came back, for the fallback estimate.

    Returns:
        tuple[int, int]
    """
    usage = getattr(chat_response, "usage", None)
    if usage is not None:
        prompt_tokens = getattr(usage, "prompt_tokens", None)
        completion_tokens = getattr(usage, "completion_tokens", None)
        if prompt_tokens is not None or completion_tokens is not None:
            return int(prompt_tokens or 0), int(completion_tokens or 0)

    return len(prompt_text) // 4, len(output_text) // 4


def _chat_with_retry(details, label):
    """Call chat(), retrying while the service throttles us.

    OCI Generative AI enforces a per-model service limit on on-demand
    inference, and it is low enough that a handful of concurrent workers trip
    it — which is exactly what raising worker_concurrency does. The service
    returns 429 with "service limit for this model has been reached".

    That is transient and worth waiting out: without a retry a throttled job
    lands in Error permanently, so the user loses work purely because a sibling
    job happened to be scoring at the same moment.

    Backoff is exponential WITH JITTER because the workers collide by
    construction — several were started at once by separate connectors, so a
    fixed schedule would have them all retry in lockstep and collide again.

    The budget is bounded deliberately: four sleeps of up to ~45s total, with
    two model calls per job, still fits inside the 300s function timeout
    alongside the calls themselves.

    Args:
        details : Fully-built ChatDetails.
        label   : Short tag used in log lines.

    Returns:
        The SDK chat response.

    Raises:
        ServiceError: The last 429 if every attempt is throttled, or any
        non-429 error immediately.
    """
    delay = THROTTLE_BASE_DELAY

    for attempt in range(1, THROTTLE_MAX_ATTEMPTS + 1):
        try:
            return _genai.chat(details)
        except ServiceError as exc:
            if exc.status != 429 or attempt == THROTTLE_MAX_ATTEMPTS:
                raise

            wait = delay + random.uniform(0, delay / 2)
            logger.warning(
                "GenAI %s throttled (429), attempt %s/%s — retrying in %.1fs",
                label, attempt, THROTTLE_MAX_ATTEMPTS, wait,
            )
            time.sleep(wait)
            delay *= 2


def _chat(prompt, max_tokens, user_id=None, label="call"):
    """Send one prompt to the configured model and return its text.

    Args:
        prompt     : Fully-formed prompt string.
        max_tokens : Output cap for this call.
        user_id    : When set, consumed tokens are added to this user's usage.
        label      : Short tag used in log lines.

    Returns:
        str: The model's raw response text.
    """
    chat_request = GenericChatRequest(
        api_format=GenericChatRequest.API_FORMAT_GENERIC,
        messages=[
            Message(role="USER", content=[TextContent(text=prompt)])
        ],
        max_tokens=max_tokens,
        temperature=0,
    )

    details = ChatDetails(
        compartment_id=COMPARTMENT_ID,
        serving_mode=OnDemandServingMode(model_id=GENAI_MODEL_ID),
        chat_request=chat_request,
    )

    logger.info(
        "GenAI %s starting. model=%s prompt_chars=%s",
        label, GENAI_MODEL_ID, len(prompt),
    )

    t0 = time.time()
    resp = _chat_with_retry(details, label)
    elapsed = time.time() - t0

    chat_response = resp.data.chat_response
    text = chat_response.choices[0].message.content[0].text

    input_tokens, output_tokens = _extract_usage(chat_response, prompt, text)

    logger.info(
        "GenAI %s completed. elapsed_sec=%.1f input_tokens=%s output_tokens=%s",
        label, elapsed, input_tokens, output_tokens,
    )

    if user_id:
        accumulate_tokens(user_id, input_tokens, output_tokens)

    return text


def extract_job_fields(visible_text, user_id=None):
    """Ask the model to extract structured job fields from page text.

    Expected output JSON:
    - job_title
    - company_name
    - job_text
    """
    # Reworked from the Claude prompt: Llama needs the output contract stated
    # first and last, and needs to be told explicitly that the response starts
    # with "{" — without that it tends to open with a sentence of preamble.
    prompt = f"""
You extract structured data from job postings.

Respond with a single JSON object and nothing else. The first character of
your response must be {{ and the last must be }}.

Required fields:
- "job_title": the job title as advertised, or "" if it cannot be determined
- "company_name": the hiring company, or "" if it cannot be determined
- "job_text": a plain-text job description of at most 3000 characters,
  containing only role responsibilities and candidate requirements

Do not use markdown. Do not add commentary before or after the JSON.

SOURCE TEXT:
{visible_text[:MAX_SOURCE_TEXT_CHARS]}
""".strip()

    return parse_json_object(
        _chat(prompt, max_tokens=1500, user_id=user_id, label="extraction")
    )


def score_resume(resume_text, job_text, user_id=None):
    """Ask the model to score a resume against a job description.

    Expected output JSON:
    - score
    - summary
    """
    # The three labelled paragraphs are load-bearing: the detail page renders
    # the summary verbatim, so the shape has to be stable across runs.
    prompt = f"""
You score how well a resume matches a job description.

Respond with a single JSON object and nothing else. The first character of
your response must be {{ and the last must be }}.

Required fields:
- "score": an integer from 0 to 100
- "summary": plain text containing exactly three labelled paragraphs, in this
  order and using these exact labels:
    "Overview:" 2-3 sentences explaining why the score is what it is
    "Strengths:" 2-3 sentences on resume positives relative to the job
    "Weaknesses:" 2-3 sentences on gaps or missing qualifications

Return "score" as a JSON number, not a string. Do not use markdown. Do not add
commentary before or after the JSON.

RESUME:
{resume_text[:MAX_SOURCE_TEXT_CHARS]}

JOB DESCRIPTION:
{job_text[:MAX_SOURCE_TEXT_CHARS]}
""".strip()

    return parse_json_object(
        _chat(prompt, max_tokens=4000, user_id=user_id, label="scoring")
    )


# =================================================================================
# Scoring helper
# =================================================================================


def score_job_against_resume(user_id, job_id, track_user_id=None):
    """Score the stored resume snapshot against the stored job description.

    Reads both artifacts, calls the model, stores the written analysis, and
    returns the numeric score.
    """
    resume_text = os_util.read_text(
        os_util.resume_snapshot_key(user_id, job_id)
    ).strip()
    job_text = os_util.read_text(
        os_util.job_description_key(user_id, job_id)
    ).strip()

    if not resume_text:
        raise RuntimeError("Stored resume snapshot is empty")

    if not job_text:
        raise RuntimeError("Stored job description is empty")

    try:
        scored = score_resume(resume_text, job_text, user_id=track_user_id)
    except ServiceError as exc:
        # Surface throttling in words the user can act on. The raw SDK dict
        # names a service limit but buries it in 300 characters of request ids.
        if exc.status == 429:
            raise RuntimeError(
                "Generative AI is at its service limit for this model. "
                "Too many jobs scoring at once — try again shortly, or lower "
                "worker_concurrency."
            ) from exc
        raise RuntimeError(f"Failed to score resume against job: {exc}") from exc
    except Exception as exc:
        raise RuntimeError(f"Failed to score resume against job: {exc}") from exc

    score = scored.get("score")
    summary = str(scored.get("summary", "")).strip()

    # Accept a numeric string if the model returns "82" instead of 82.
    if isinstance(score, str) and score.strip().isdigit():
        score = int(score.strip())

    # Llama returns a float more readily than Claude did; 82.0 is a valid score
    # and rejecting it would fail an otherwise good run.
    if isinstance(score, float) and score.is_integer():
        score = int(score)

    if not isinstance(score, int):
        raise RuntimeError("Scoring did not return an integer score")

    if score < 0 or score > 100:
        raise RuntimeError("Scoring returned a score outside 0-100")

    if not summary:
        raise RuntimeError("Scoring did not return analysis text")

    os_util.write_text(os_util.job_analysis_key(user_id, job_id), summary)

    return score


# =================================================================================
# Core worker logic
# =================================================================================


def process_url_job(user_id, job_id, job_url):
    """Process a URL-based job: fetch, clean, extract, score, save."""
    if not job_url:
        update_job_status(user_id, job_id, "Error", "Job URL is missing")
        return

    try:
        html = fetch_url_html(job_url)
        logger.info(
            "Retrieved job URL. user_id=%s job_id=%s bytes=%s",
            user_id, job_id, len(html),
        )
    except Exception as exc:
        logger.exception("Failed to retrieve job URL. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to retrieve job URL: {exc}"),
        )
        return

    try:
        visible_text = extract_visible_text(html)
        if not visible_text:
            update_job_status(
                user_id, job_id, "Error",
                "No visible job text extracted from URL",
            )
            return
    except Exception as exc:
        logger.exception("Failed to extract visible text. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to extract visible text: {exc}"),
        )
        return

    try:
        extracted = extract_job_fields(visible_text, user_id=user_id)

        job_title = str(extracted.get("job_title", "")).strip()
        company_name = str(extracted.get("company_name", "")).strip()
        job_text = str(extracted.get("job_text", "")).strip()

        if not job_text:
            update_job_status(
                user_id, job_id, "Error", "Model did not return job text"
            )
            return

        if len(job_text) < MIN_JOB_TEXT_CHARS:
            update_job_status(
                user_id, job_id, "Error",
                "Extracted job description is too short",
            )
            return
    except ServiceError as exc:
        logger.exception("Failed to extract job fields. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            "Generative AI is at its service limit for this model. Too many "
            "jobs scoring at once — try again shortly."
            if exc.status == 429 else
            safe_status_message(f"Failed to extract job fields: {exc}"),
        )
        return
    except Exception as exc:
        logger.exception("Failed to extract job fields. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to extract job fields: {exc}"),
        )
        return

    # Surface title and company immediately so the row stops looking anonymous
    # while the slower scoring call runs.
    update_job_title_and_company(user_id, job_id, job_title, company_name)

    try:
        job_description_key = os_util.job_description_key(user_id, job_id)
        os_util.write_text(job_description_key, job_text)
    except Exception as exc:
        logger.exception("Failed to store job description. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to store job description: {exc}"),
        )
        return

    # Re-check the budget: extraction may have pushed a concurrent sibling job
    # over the cap since the submission check.
    if is_over_token_limit(user_id):
        update_job_status(
            user_id, job_id, "Error",
            "Token limit reached. This job was not scored.",
        )
        return

    try:
        score = score_job_against_resume(user_id, job_id, track_user_id=user_id)
        update_job_extracted_fields(
            user_id, job_id, job_title, company_name,
            job_description_key, score,
        )
    except Exception as exc:
        logger.exception("Failed to score job. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to score job: {exc}"),
        )
        return

    update_job_status(user_id, job_id, "Scored", "")
    logger.info("URL job processed. user_id=%s job_id=%s", user_id, job_id)


def process_raw_text_job(user_id, job_id):
    """Process a pasted-text job: read stored text, extract, score, save."""
    job_description_key = os_util.job_description_key(user_id, job_id)

    try:
        job_text = os_util.read_text(job_description_key).strip()
    except Exception as exc:
        logger.exception("Failed to read job description. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to read stored job description: {exc}"),
        )
        return

    if not job_text:
        update_job_status(
            user_id, job_id, "Error", "Stored job description is empty"
        )
        return

    if len(job_text) < MIN_JOB_TEXT_CHARS:
        update_job_status(
            user_id, job_id, "Error", "Stored job description is too short"
        )
        return

    try:
        extracted = extract_job_fields(job_text, user_id=user_id)

        job_title = str(extracted.get("job_title", "")).strip()
        company_name = str(extracted.get("company_name", "")).strip()
        extracted_job_text = str(extracted.get("job_text", "")).strip()

        # Prefer the model-cleaned text, but only if it is not shorter than the
        # floor — a truncated rewrite would silently degrade the scoring input.
        if extracted_job_text and len(extracted_job_text) >= MIN_JOB_TEXT_CHARS:
            job_text = extracted_job_text
    except ServiceError as exc:
        logger.exception("Failed to extract job fields. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            "Generative AI is at its service limit for this model. Too many "
            "jobs scoring at once — try again shortly."
            if exc.status == 429 else
            safe_status_message(f"Failed to extract job fields: {exc}"),
        )
        return
    except Exception as exc:
        logger.exception("Failed to extract job fields. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to extract job fields: {exc}"),
        )
        return

    update_job_title_and_company(user_id, job_id, job_title, company_name)

    try:
        os_util.write_text(job_description_key, job_text)
    except Exception as exc:
        logger.exception("Failed to store job description. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to store job description: {exc}"),
        )
        return

    if is_over_token_limit(user_id):
        update_job_status(
            user_id, job_id, "Error",
            "Token limit reached. This job was not scored.",
        )
        return

    try:
        score = score_job_against_resume(user_id, job_id, track_user_id=user_id)
        update_job_extracted_fields(
            user_id, job_id, job_title, company_name,
            job_description_key, score,
        )
    except Exception as exc:
        logger.exception("Failed to score job. job_id=%s", job_id)
        update_job_status(
            user_id, job_id, "Error",
            safe_status_message(f"Failed to score job: {exc}"),
        )
        return

    update_job_status(user_id, job_id, "Scored", "")
    logger.info("Raw-text job processed. user_id=%s job_id=%s", user_id, job_id)


def process_job_message(message):
    """Process one job request drawn from the queue."""
    user_id = str(message.get("user_id", "")).strip()
    job_id = str(message.get("job_id", "")).strip()
    resume_id = str(message.get("resume_id", "")).strip()
    source_type = str(message.get("source_type", "")).strip()
    job_url = str(message.get("job_url", "")).strip()

    if not user_id or not job_id:
        logger.error("Message missing required fields: %s", message)
        return

    # Guard against batch over-runs — several jobs may have been queued before
    # the API submission check saw the limit was approaching.
    if is_over_token_limit(user_id):
        update_job_status(
            user_id, job_id, "Error",
            "Token limit reached. This job was not scored.",
        )
        return

    update_job_status(user_id, job_id, "Scoring", "Started job scoring")

    logger.info(
        "Processing job. user_id=%s job_id=%s resume_id=%s source_type=%s",
        user_id, job_id, resume_id, source_type,
    )

    if source_type == "url":
        process_url_job(user_id, job_id, job_url)
        return

    if source_type == "raw_text":
        process_raw_text_job(user_id, job_id)
        return

    update_job_status(
        user_id, job_id, "Error", f"Unsupported source_type: {source_type}"
    )


# =================================================================================
# Connector Hub entry point
# =================================================================================


def iter_batch(payload):
    """Yield job request dicts from a Connector Hub batch payload.

    Connector Hub is not consistent about the shape it delivers: depending on
    version and source it can be a bare object, a list of objects, a list of
    JSON strings, or the queue message envelope {"content": "<json>"}. Rather
    than pin one shape and break on the others, unwrap each layer if present.

    A malformed entry is logged and skipped rather than raising, so one bad
    message cannot cost the rest of the batch.

    Args:
        payload: Parsed JSON body delivered by Connector Hub.

    Yields:
        dict: One job request.
    """
    entries = payload if isinstance(payload, list) else [payload]

    for entry in entries:
        if isinstance(entry, str):
            try:
                entry = json.loads(entry)
            except json.JSONDecodeError:
                logger.warning("skipping non-JSON batch entry: %r", entry[:200])
                continue

        if not isinstance(entry, dict):
            logger.warning("skipping unexpected batch entry type: %s", type(entry))
            continue

        # Queue message envelope — the request is JSON inside `content`.
        if "job_id" not in entry and "content" in entry:
            try:
                entry = json.loads(entry["content"])
            except (json.JSONDecodeError, TypeError):
                logger.warning("skipping bad envelope content: %r", entry.get("content"))
                continue

        if isinstance(entry, dict) and entry.get("job_id"):
            yield entry


def handle_batch(data):
    """Process one Connector Hub delivery.

    Each request is handled independently so a single failure cannot abort the
    rest of the batch. Failures are recorded on the job row rather than raised:
    re-raising would have Connector Hub redeliver the message, and a posting
    that reliably breaks the scraper would then burn model tokens on every
    retry until the queue gives up on it.

    Args:
        data: FDK request body stream.

    Returns:
        dict: {"processed": <count>}
    """
    try:
        raw = data.getvalue() if data else b"[]"
        payload = json.loads(raw or b"[]")
    except (json.JSONDecodeError, TypeError):
        logger.error("Malformed batch payload")
        return {"processed": 0, "error": "malformed batch payload"}

    processed = 0
    for message in iter_batch(payload):
        try:
            process_job_message(message)
            processed += 1
        except Exception:
            logger.exception("Unhandled error while processing job request")

    return {"processed": processed}
