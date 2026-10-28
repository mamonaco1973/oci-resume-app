# Resume Scorer on OCI: Identity Domains, API Gateway, Queue and Generative AI

An AI **resume scoring** app on OCI. Users sign in through an **OCI IAM
identity domain** (authorization code with PKCE), store one or more resumes,
and submit job postings as a URL or pasted text. An **API Gateway** checks
the token and sends every route to one **OCI Function**; submitted jobs go
on an **OCI Queue**, and **Connector Hub** hands them to a worker function
that scrapes the posting, has a model on **OCI Generative AI**
(`openai.gpt-oss-120b` by default) extract the job description, and scores
the resume from 0 to 100 with strengths and gaps. Data lives in **OCI
NoSQL** and **Object Storage**.

This is the OCI member of a four-cloud set with
[aws-resume-app](https://github.com/mamonaco1973/aws-resume-app),
[azure-resume-app](https://github.com/mamonaco1973/azure-resume-app) and
[gcp-resume-app](https://github.com/mamonaco1973/gcp-resume-app); the
workload is the same, only the plumbing differs.

| Piece | Where | Role |
|---|---|---|
| **Identity domain** | `resume-app`, External User tier | created by `setup_domain.sh`; public signing certificate for the JWKS; a self-registration profile `spa-signup`; Terraform adds the public SPA app `resume-spa` |
| **resume-gateway** | API Gateway, public | twenty routes, all behind `JWT_AUTHENTICATION` against the domain's JWKS; injects an `X-Route` header and path parameters |
| **resume-app** | OCI Functions | `resume-api` (1 GB, 60 s) and `resume-worker` (2 GB, 300 s), both from one image in the OCIR repository `resume-functions`; signed in with a resource principal |
| **resume-job-requests** | OCI Queue | 15 min visibility, 1 day retention; dead-letter queue after 3 deliveries |
| **resume-queue-to-worker-1..4** | Connector Hub | `worker_concurrency` (default 4) connectors, each with batch size 1, invoking the worker |
| **resume_app** | OCI NoSQL | one table with a composite key and a JSON column for users, resumes, jobs and folders; 50 read and 50 write units |
| **resume-backend-&lt;hex&gt;** | Object Storage | private; resume text, snapshots, analyses and attachments |
| **resume-web-&lt;hex&gt;** | Object Storage | public-read bucket with the SPA |
| **resume-vcn** | VCN | one public subnet with an internet gateway for the gateway and functions |

Everything deploys to `us-chicago-1` (set `OCI_REGION` to change it).

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A browser loads the single-page app from the public resume-web bucket and signs in to an OCI IAM identity domain with the authorization code flow and PKCE. It calls resume-gateway, a public API Gateway that validates the ID token against the domain's JWKS and sends all twenty routes to the resume-api function, which keeps rows in the resume_app NoSQL table and text and attachments in the private backend bucket. Submitting a job puts it on the resume-job-requests queue; four Connector Hub connectors, each with a batch size of one, invoke the resume-worker function, which fetches the posting, calls openai.gpt-oss-120b on OCI Generative AI to extract the job and score the resume, writes the analysis to the bucket, and records the status and token usage in NoSQL." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`setup_domain.sh`** / **`delete_domain.sh`**: create and delete the
  identity domain, outside Terraform.
- **`01-ocir/`**: the container repository.
- **`02-docker/`**: `build.sh` and the functions code in `code/` (`func.py`
  dispatches to `users.py`, `resumes.py`, `jobs.py`, `folders.py`,
  `attachments.py` and `worker.py`).
- **`03-functions/`**: the VCN, both functions, the gateway, the queue and
  connectors, the NoSQL table, both buckets, the SPA app in the domain,
  logging, and the IAM policies.
- **`04-webapp/`**: the SPA; `apply.sh` renders `js/config.js` from its
  template and uploads it.
- **`genai-config.sh`**: the model ID. **`probe_genai.py`** shows which
  models actually answer in a region.

## Why this is asynchronous

Scoring is not done inline, and that is not a design preference.

A page fetch plus two model calls takes far longer than **API Gateway will hold a
request open**. The synchronous version of this endpoint cannot exist — on any of
the four clouds. So `POST /jobs` writes the job row, snapshots the resume, drops
a message on a queue and returns immediately with `submitted`. A separate worker
drains the queue, does the slow work, and writes the score back. The browser
polls until the status changes.

Every cloud in this set solves that the same way and names it differently:

| Cloud | Queue | Bridge to compute |
|---|---|---|
| AWS | SQS | Lambda event source mapping |
| GCP | Pub/Sub | Eventarc |
| Azure | Service Bus | Functions trigger |
| **OCI** | **Queue** | **Connector Hub** |

OCI's bridge works differently from the other three, and the difference is worth
knowing only because of one default. Connector Hub polls rather than triggering
on arrival, flushing a batch when either a size or a time threshold is reached.
`batch_time_in_sec` cannot be set below 60, so at the default batch size a
single submitted job waits a full minute before the worker sees it — which reads
as a dead pipeline.

Set `batch_size_in_num = 1`, as this project does, and delivery takes 1–2
seconds. That is perfectly adequate for a workload measured in tens of seconds;
the gap against an event-driven trigger is irrelevant here. The default is the
problem, not the mechanism.

The **second** difference is not a default, and matters more. A connector
invokes its Function *serially* — Oracle's documentation states that invocations
"are handled sequentially". One connector is one worker, so submitting two jobs
scores them one after the other while AWS, GCP and Azure all process them at
once. `batch_size_in_num` does not help: it controls messages per invocation,
not invocations in flight.

Oracle's recommended fix is to point **multiple connectors** at the same queue,
which is what `worker_concurrency` (default 4) does here. The consequence is
that scoring concurrency is chosen at deploy time rather than scaled to load —
four connectors means at most four jobs at once, whether one was submitted or
forty.

There is a second ceiling behind the first: Generative AI throttles on-demand
inference per tenancy, and that limit is **not raisable** — OCI applies dynamic
throttling, so the rate is undocumented, moves with system-wide demand, and has
no requestable service-limit name (named limits exist only for dedicated AI
clusters). Oracle's own advice for a 429 is exponential backoff, which the
worker implements.

How tight that ceiling is depends heavily on the model. Four connectors running
a slow model produced constant 429s — and because the retry turns throttling
into waiting, the jobs *looked* serialized. The same four connectors on
`openai.gpt-oss-120b` run cleanly: a faster model holds its throttle slot for
much less time, so contention drops. If `GenAI ... throttled (429)` starts
appearing in the worker log, lower `worker_concurrency`; workers sitting in
backoff are worse than fewer workers that actually run.

## API

All twenty routes go to `resume-api`, which dispatches on the `X-Route`
header. Every route needs `Authorization: Bearer <id_token>`; the verified
`sub` claim is the NoSQL shard key, so users only see their own data.

| Area | Routes |
|---|---|
| Account | `POST /register` (creates the user record, up to 100 users), `GET /usage` |
| Resumes | `GET`/`POST /resumes`, `GET`/`PUT`/`DELETE /resumes/{resume_id}` |
| Jobs | `GET`/`POST /jobs` (URL or pasted text; returns `submitted` immediately), `GET`/`DELETE /jobs/{job_id}`, `PATCH /jobs/{job_id}/notes`, `PATCH /jobs/{job_id}/folder` |
| Attachments | `GET`/`POST /jobs/{job_id}/attachments`, `GET`/`DELETE /jobs/{job_id}/attachments/{attachment_id}`; base64 JSON, up to 10 MB each and 5 per job |
| Folders | `GET`/`POST /folders`, `DELETE /folders/{folder_id}` |

## Choosing the model

Model selection lives in **`genai-config.sh`**, the single source of truth shared
by the deploy scripts and Terraform. The default is **`openai.gpt-oss-120b`**,
deployed to **`us-chicago-1`**.

**What is callable varies by region, and the difference is large.** Measured by
calling `chat()` against every listed CHAT model in each region:

| | us-ashburn-1 | us-chicago-1 |
|---|---|---|
| Models that answer | 8 | **10** |
| Meta Llama | none | **both** |
| OpenAI gpt-oss | none | **both** |
| Slowest model | **67.9s** | **2.6s** |

Same tenancy, same script, same request. Ashburn's Grok models ranged from 0.4s
to 68s on an identical 5-token call, and which ones were slow changed between
runs. Chicago showed no such outliers. That is why this project deploys to
Chicago while the other OCI builds in this set use Ashburn.

`openai.gpt-oss-120b` is the fastest measured there and is open-weight, so
unlike Gemini 2.5 (retiring on GCP) or the Grok line (ten variants retired on a
single day) it has no upstream vendor schedule hanging over it.

**It is a reasoning model, and that changes two things.** `gpt-oss-120b` is a
mixture-of-experts model — roughly 117B parameters total but only ~5B active per
token, which is why a model this size answers in a tenth of a second — and it
generates chain-of-thought before its answer. Consequences worth knowing:

- **Token counts run higher.** Reasoning tokens are generated tokens, so the
  per-user usage ring and the lifetime cap climb faster per job than they did on
  Llama for the same visible output. The numbers are not comparable to the AWS,
  GCP and Azure builds in this set.
- **Responses are more likely to carry preamble**, which is why
  `parse_json_object()` slices from the first `{` to the last `}` instead of
  trusting the whole string. That was written for Llama's occasional
  "Here is the JSON:" and matters more now, not less.

Note that `google.gemini-2.5-flash-lite` does **not** exist in Chicago — it
carries `flash` and `pro` only. Models do not necessarily move with you across
regions.

**Do not trust the model catalog.** `list-models` is the control plane and
returns every model the region knows about, including ones served only through a
dedicated AI cluster. A model can be `ACTIVE`, advertise the `CHAT` capability,
carry no retirement date, resolve to a valid OCID — and still fail every call
with `404 Entity with key <ocid> not found`. Nothing in the listing
distinguishes the two groups.

`us-ashburn-1` is the clearest demonstration: every Meta Llama 4 entry, both
OpenAI gpt-oss sizes and every Cohere model are listed there and none of them
answer a call. Only xAI Grok and Google Gemini do, and there is no Anthropic
model at all. The identical catalog entries in `us-chicago-1` — same names,
different OCIDs — answer in about a tenth of a second. The listing is a
statement about what the region knows, not about what it will serve you.

`check_env.sh` therefore makes a real chat call rather than inspecting metadata,
and refuses to deploy if the configured model does not answer.

To see what actually answers in your tenancy — this makes real calls, it does
not read the catalog:

```bash
python3 probe_genai.py                        # probe every CHAT model
python3 probe_genai.py --check openai.gpt-oss-120b   # exit 0 / 1
python3 probe_genai.py --region us-ashburn-1         # compare another region
```

## Prerequisites

* [An OCI Account](https://cloud.oracle.com/) with Generative AI available
  in `us-chicago-1`
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm),
  configured with a `DEFAULT` profile in `~/.oci/config`
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install Docker](https://docs.docker.com/engine/install/)
* [Install jq](https://jqlang.github.io/jq/download/), `envsubst` and
  Python 3 (for `probe_genai.py`)

Your user needs to create identity domains, policies and dynamic groups.
Set `OCI_COMPARTMENT_ID` to deploy into a compartment; otherwise everything
goes into the root compartment.

## Deploy

```bash
git clone https://github.com/mamonaco1973/oci-resume-app.git
cd oci-resume-app
./setup_domain.sh     # once: identity domain, signing cert, sign-up profile, env.sh
./apply.sh
```

`setup_domain.sh` is idempotent and writes `env.sh` (gitignored), which
`apply.sh` reads. `apply.sh` checks that the configured model answers a real
chat call, gets or creates an OCIR auth token (`resume-app-ocir`), and runs
four phases: `01-ocir`, the image build and push, `03-functions`, and
`04-webapp`.

It ends by running `validate.sh`, which waits for the gateway to resolve,
checks that unauthenticated requests are rejected, and checks that the queue
and the connectors are `ACTIVE`. Without a live connector, `POST /jobs`
still returns 200 and the job still appears, but it never leaves
`submitted`.

## Try it

1. Open the web URL and sign in; on first use, create an account through the
   domain's sign-up page.
2. Create a resume and paste in its text.
3. Submit a job as a URL or pasted description and pick the resume. The
   dashboard polls until the job is scored, then shows the score, the
   analysis and the extracted description. Add notes, folders and
   attachments as needed.

If `GenAI ... throttled (429)` shows up in the worker's logs, lower
`worker_concurrency` (see above).

## Teardown

```bash
./destroy.sh          # 1. empty the backend bucket, remove Terraform resources
./delete_domain.sh    # 2. deactivate and delete the domain, remove env.sh
```

Run them in that order: the functions fill the backend bucket with objects
Terraform doesn't know about, and Object Storage won't delete a non-empty
bucket. External User domains bill per monthly active user, so delete the
domain when you're finished.

## Notes

- **Resource Principal propagation.** A Function container caches its dynamic
  group membership at boot. A container that started before the DG or its
  policies propagated keeps a groupless token and returns 404
  `NotAuthorizedOrNotFound` for its entire life, while one started later works.
  The OCI SDK treats that 404 as *transient* and retries it, so the first calls
  hang for the full function timeout and later ones fail instantly once the
  circuit breaker opens — one fault presenting as two different bugs. Recycle
  the container rather than editing the policy.
- **The SPA is not served from a domain root.** Object Storage hosts it under
  `/n/<namespace>/b/<bucket>/o/`, so `window.location.origin` silently drops the
  path. Every browser-side URL derives from `CONFIG.WEB_BASE_URL`, and asset
  references are relative.
- **HTTPS is required**, not merely advisable: PKCE uses `crypto.subtle`, which
  is undefined outside a secure context.
- **Identity Domains rotates refresh tokens**, unlike Cognito, so the new one has
  to be stored or the next refresh fails.
- **Editing a resume does not rescore past jobs.** Each job snapshots the resume
  text it was scored against, so historical scores stay reproducible.
- **Lab only.** Anyone can create an account through the self-registration
  profile, up to the 100-user cap. The default token limit is 500,000 per
  user for the account's lifetime.
- `destroy.sh` lists images with only `--compartment-id`, so it deletes
  **every** container image in the compartment, not just
  `resume-functions`.
- `02-docker/.build_output` is committed with an image path from a previous
  build; `build.sh` overwrites it.
- `03-functions/api.tf` still carries a "VERIFY BEFORE SHIP" comment on the
  JWT `issuers` and `audiences`.
