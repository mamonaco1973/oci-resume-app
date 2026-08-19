# CLAUDE.md — oci-resume-app

OCI port of the resume scoring application ("My Jobs"). Users upload resumes and
submit job postings (URL or pasted text); the app uses **OCI Generative AI** to
score resume-to-job compatibility (0–100) **asynchronously**. Scored jobs support
file attachments in Object Storage. Token usage is tracked per user with a
configurable lifetime cap enforced at submission time.

Completes the set alongside `aws-resume-app`, `gcp-resume-app` and the Azure
build. Ported from **`aws-resume-app`** (closest architecture: single-table key
design, two functions, same module split) on the auth scaffolding of
**`oci-identity-app`**, with the async tier from **`oci-queue-keygen`**.

---

## Deployment Commands

```bash
./apply.sh      # check_env → setup_domain → 01-ocir → 02-docker → 03-functions → 04-webapp
./destroy.sh    # tears down app resources (see teardown caveat below)
./delete_domain.sh  # then removes the identity domain
./check_env.sh  # tools, OCI connectivity, Gen AI model availability
./validate.sh   # asserts auth is enforced and the async tier is live
```

There are no test or lint commands configured.

---

## Architecture

```
Browser (SPA on Object Storage)
   │  1. PKCE login → Identity Domain /oauth2/v1/authorize
   │  2. callback.html exchanges code → tokens at /oauth2/v1/token
   │  3. stores id_token in localStorage
   ▼
API Gateway — resume-gateway (PUBLIC)
   │  authentication: JWT_AUTHENTICATION (REMOTE_JWKS = domain SigningCert/jwk)
   │  every route: authorization = AUTHENTICATION_ONLY
   │  injects X-Route + path params as headers; forwards Authorization
   ▼
Function: resume-api  (FUNCTION_TYPE=api, 60s)
   │  dispatches on X-Route → jobs / resumes / folders / users / attachments
   │  POST /jobs writes the row, snapshots the resume, enqueues, returns
   ▼
OCI Queue: resume-job-requests
   ▼
Connector Hub: resume-queue-to-worker-1..4  (batch_size_in_num = 1)
   │  4 connectors: ONE connector invokes its Function SERIALLY.
   │  Ceiling is the GenAI on-demand throttle, not compute — a slow
   │  model 429s at 4; openai.gpt-oss-120b runs 4 cleanly.
   ▼
Function: resume-worker (FUNCTION_TYPE=worker, 300s, 2GB)
   │  scrape → GenAI extract → GenAI score → write analysis + score
   ▼
NoSQL: resume_app          Object Storage: resume-backend-<hex> (private)
  pk=USER#<sub>, sk=..., doc JSON      blobs; resume-web-<hex> is the public SPA
```

### Request Flow

**Resume upload:** `POST /resumes` → api Function → Object Storage (text) +
NoSQL (metadata)

**Job scoring:**
1. `POST /jobs` → api Function → snapshots resume into the job prefix, puts a
   Queue message → returns `submitted`
2. Connector Hub flushes (1 message) → worker Function → fetches URL if needed →
   Gen AI field extraction → Gen AI score → analysis to Object Storage → NoSQL
   updated with score and `Scored`
3. Frontend polls `GET /jobs` to show updated scores

---

## Repository Layout

```
01-ocir/        OCIR container repository (Terraform)
02-docker/      Image build + push (build.sh); code/ = all handler modules
                  func.py         FDK entry; FUNCTION_TYPE + X-Route dispatch
                  common.py       Request shim, RP signer, auth, config
                  nosql_util.py   single-table access; hides the `doc` column
                  os_util.py      Object Storage + object-name conventions
                  jobs.py resumes.py folders.py users.py attachments.py
                  worker.py       scrape + Generative AI scoring pipeline
03-functions/   Backend Terraform:
                  network.tf   VCN + public subnet + IGW + security list
                  nosql.tf     single table, pk/sk + doc JSON
                  functions.tf Application + api Function + worker Function
                  queue.tf     OCI Queue
                  sch.tf       Connector Hub (Queue → worker)
                  identity.tf  Identity Domains app (SPA, PKCE) + domain lookup
                  api.tf       API Gateway + JWT auth + 20 routes
                  storage.tf   web bucket (public) + backend bucket (private)
                  iam.tf       Dynamic Group + policies
                  logging.tf   Functions resource logs
                  outputs.tf
04-webapp/      SPA upload only (buckets created in 03):
                  index.html job.html callback.html css/ js/
                  js/config.js.tmpl → js/config.js rendered by apply.sh
genai-config.sh Model selection — single source of truth
setup_domain.sh One-time domain bootstrap; writes env.sh
delete_domain.sh Inverse of setup_domain.sh
apply.sh / destroy.sh / check_env.sh / validate.sh
```

---

## Data Model (NoSQL single table `resume_app`)

```
pk  STRING   <user_id>            shard key — the bare `sub` claim
sk  STRING   RESUME#|JOB#|FOLDER#|USER#USAGE
doc JSON     everything else
```

- `pk=<id>`, `sk=RESUME#<id>` — resume metadata
- `pk=<id>`, `sk=JOB#<id>` — job metadata + `attachments` array
- `pk=<id>`, `sk=FOLDER#<id>` — folder name + metadata
- `pk=<id>`, `sk=USER#USAGE` — `tokens_used`, `token_limit`

**The 64-byte key limit.** OCI NoSQL caps the *combined* pk + sk at 64 bytes;
DynamoDB allows 2048 for the partition key alone. The AWS key design therefore
does not fit as written — `USER#` + a 22-char subject (27) plus `RESUME#` + a
36-char UUID (43) is 70 bytes, and every write fails with
`KeySizeLimitExceeded`. Two changes bring it inside:

1. `pk` is the bare subject, no `USER#` prefix — the prefix carried no
   information, since every partition key here is a user.
2. Entity ids are `common.new_id()` — 20 hex chars — not a 36-char UUID.

Worst case at a 32-char subject is 59 bytes. `nosql_util._check_key()` enforces
the limit on every get/put/delete so a future key change fails with a message
naming the offending key rather than an opaque service error — or, on reads,
rather than silently returning no row.

Object Storage names still use the readable `users/USER#{id}/jobs/JOB#{id}/…`
layout; object names have a 1024-char limit, so the budget does not apply there.

**Why `doc JSON`:** DynamoDB is schemaless and the four entity types differ
freely; OCI NoSQL requires a declared schema. A JSON payload column keeps the
entities heterogeneous (and lets a job carry a nested attachments array) while
the key columns stay typed so `SHARD()` still partitions. `nosql_util.py`
flattens rows to `{pk, sk, ...attrs}` so the ported handlers read like their
DynamoDB originals.

### Object Storage layout (private backend bucket)

```
users/USER#{id}/resumes/RESUME#{id}.txt
users/USER#{id}/jobs/JOB#{id}/job_description.txt
users/USER#{id}/jobs/JOB#{id}/resume_snapshot.txt
users/USER#{id}/jobs/JOB#{id}/job_analysis.txt
users/USER#{id}/jobs/JOB#{id}/notes.txt
users/USER#{id}/jobs/JOB#{id}/attachments/{att_id}/{filename}
```

Attachments transfer as base64 JSON (10 MB cap, 5 per job) — no pre-authenticated
requests, no multipart.

---

## Key Differences From aws-resume-app

1. **X-Route header dispatch.** The AWS Lambda routes on `event["rawPath"]`; the
   FDK has no equivalent guarantee (`ctx.RequestURL()` reflects the backend
   invoke URL, not the matched route template). API Gateway states the matched
   route in `X-Route` and injects path params as `X-Job-Id` / `X-Resume-Id` /
   `X-Folder-Id` / `X-Attachment-Id`. Adding a route means editing `api.tf` **and**
   the `ROUTES` table in `func.py`.
2. **Queue + Connector Hub instead of SQS → Lambda.** There is no
   invoke-on-arrival semantic; the connector polls and flushes on a size or time
   threshold, and `batch_time_in_sec` cannot go below 60. `batch_size_in_num = 1`
   is what makes delivery prompt. Leaving it at the default is the most common
   way to conclude the pipeline is broken when it is only batching.
3. **Generative AI, not Bedrock.** `GenericChatRequest` + `OnDemandServingMode`
   against a per-region inference endpoint. Prompts were reworked for an
   open-weight model and the JSON parse is more defensive (see below).
4. **`doc JSON` single table** rather than native schemaless items.
5. **Two buckets, no CloudFront.** The SPA is served straight from Object
   Storage under `/n/<ns>/b/<bucket>/o/`, which is *not* a domain root — see the
   webapp note below.
6. **Token accumulation is read-modify-write.** DynamoDB's atomic `ADD` has no
   equivalent for a field inside a JSON column, so concurrent scoring for one
   user can lose an update. Acceptable: it drives a usage ring and a soft cap.

---

## Generative AI

Model selection lives in **`genai-config.sh`** and flows to Terraform as
`TF_VAR_genai_model_id`. Default: **`openai.gpt-oss-120b`**, in
**`us-chicago-1`**.

**Region is part of the model choice.** What is *callable* differs sharply from
what is *listed*, and it differs by region. In `us-ashburn-1` every Meta Llama 4
entry, both OpenAI gpt-oss sizes and all Cohere models are listed and none
answer; only Grok and Gemini do, and Grok ranged from 0.4s to 68s on an
identical 5-token call. In `us-chicago-1` ten models answer, the slowest in
2.6s. That is why this project deploys to Chicago while the other OCI builds in
this set use Ashburn. `probe_genai.py` makes real `chat()` calls to establish
this; the catalog cannot tell you.

**Why gpt-oss.** Open weights, so no upstream retirement schedule — the
consideration that ruled out Gemini 2.5 (retiring on GCP) and the Grok line (ten
variants retired on a single day). `check_env.sh` still fails the deploy if the
configured model does not answer.

**It is a reasoning model.** A mixture-of-experts design, ~117B parameters total
but only ~5B active per token, which is how it answers in ~0.1s. It emits
chain-of-thought before its answer, which has two consequences here:

- **Token accounting runs high.** Reasoning tokens are generated tokens, so the
  usage ring and lifetime cap climb faster per job than on Llama for the same
  visible output. Not comparable to the AWS, GCP and Azure builds.
- **Preamble is more likely, not less.** `parse_json_object()` slices from the
  first `{` to the last `}` rather than trusting the whole string. That was
  written for Llama and matters more now.

**Prompts state the output contract first and last** and say explicitly that the
response begins with `{`. This was tuned for Llama and kept for gpt-oss because
it is the reason parsing is reliable — a reasoning model has more opportunity to
narrate, not less. The score check accepts a float (`82.0`) as well as an int.

**Token usage** is not reported consistently across model families, so
`_extract_usage()` falls back to a chars/4 estimate rather than letting the
usage ring go blank.

---

## Notes / gotchas

- **Resource Principal propagation.** A Function container caches its dynamic
  group membership at boot. A container that started before the DG or policy
  propagated keeps a groupless token and returns 404 `NotAuthorizedOrNotFound`
  for its entire life, while a container started later works — same image, same
  policy. Worse, the OCI SDK treats that 404 as *transient* and retries it, so
  the first calls hang for the full function timeout and later ones fail
  instantly once the circuit breaker opens: one fault, two symptoms. **Recycle
  the container; do not keep editing the policy.**
- **The SPA is not served from a domain root.** Object Storage hosts it under
  `/n/<ns>/b/<bucket>/o/`, so `window.location.origin` drops the path. All
  browser-side URLs derive from `CONFIG.WEB_BASE_URL`, and asset references in
  the HTML are relative (`css/styles.css`, not `/css/styles.css`).
- **PKCE is mandatory.** The Identity Domains app is a public client with no
  secret; the token endpoint rejects an exchange without a verifier. `getLoginUrl()`
  is therefore async (it hashes an S256 challenge) — await it.
- **`crypto.subtle` needs a secure context**, so this only works over HTTPS.
- **Identity Domains rotates refresh tokens** (Cognito does not), so the new one
  must be stored or the next refresh fails.
- **JWKS is private by default** → gateway 500s until Access Signing Certificate
  is enabled. `setup_domain.sh` handles it.
- **`issuers`** in `api.tf` = `https://identity.oraclecloud.com/` (trailing
  slash). If a domain emits a domain-specific issuer, decode a live token's
  `iss` and match it, or the gateway 401s.
- **PATCH must be in the CORS allowed_methods** — `/jobs/{id}/notes` and
  `/jobs/{id}/folder` are the only PATCH routes, and omitting it fails just
  those two at preflight.
- **`destroy.sh` must empty the backend bucket first.** The functions fill it at
  runtime with objects Terraform knows nothing about, and Object Storage refuses
  to delete a non-empty bucket.

---

## Teardown

`destroy.sh` removes the Terraform-managed resources and deactivates the SPA app
so it can be deleted. **It does NOT touch the identity domain** — Terraform
cannot manage domain lifecycle:

```bash
./destroy.sh          # 1. purge backend bucket, remove Terraform resources
./delete_domain.sh    # 2. deactivate + delete the domain, remove env.sh
```

External User domains bill per monthly active user, so run `delete_domain.sh`
when finished.

---

## Modifying Function Code

1. Edit any file under `02-docker/code/`.
2. Re-run `./apply.sh` — `build.sh` content-hashes **every** file in that
   directory (globbed, not listed), so any change produces a new image tag and
   forces the Functions to update. A hand-maintained file list here is how an
   edit silently stops deploying.

Keep bytecode out of the tree: compile with `PYTHONDONTWRITEBYTECODE=1` and
never commit `__pycache__/` or `*.pyc`.

---

## Code Commenting Standards

Comment lines ≤ 80 characters. Explain intent and rationale, not what the code
already says. Python modules get a structured `# ===` header and non-trivial
functions get docstrings; Terraform uses section banners explaining why the
infrastructure exists; shell keeps `set -euo pipefail` and bannered sections.
