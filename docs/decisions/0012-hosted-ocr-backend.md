# 0012. Hosted OCR backend: a vision model through OpenRouter, zero data retention only

Status: accepted.

## Context

The ML service reads receipts with a local Qwen VL model (`docs/decisions/0005-local-ocr-backend.md`).
Two jobs need a hosted model next to it:

- **pre-filling the labelling form**: a strong model proposes the items a person then checks, so the item
  ground truth is cheaper to make. That model is a tool, not a subject of the evaluation;
- **a hosted comparison model** in the evaluation: accuracy, seconds per receipt and cost per 1,000
  receipts against the local models, on the same receipts, with the same prompt.

Receipt photos are personal data. The app is local-first, and the rule so far was that photos never leave
the machine. The owner decided to allow one exception, under strict conditions: only the receipt photos
and the fixed prompt may go to a hosted model, and only to endpoints that keep nothing and train on
nothing.

## Decision

### `OCR_BACKEND=openrouter` calls one model through OpenRouter

[OpenRouter](https://openrouter.ai) puts many vision models from many providers behind one
OpenAI-compatible chat-completions API, one key and one bill. Three things decide it for this project:
the model can be changed with one setting (the evaluation compares several), its routing can be limited
per request to endpoints with zero data retention (below), and every answer reports its own cost. A
direct contract with one vendor would give one model, a vendor-specific API, and a retention promise that
has to be checked per vendor by hand.

The backend (`ml/app/backends/openrouter.py`) uses the same prompt, the same parsing with one repair
pass and the same post-processing as the local backend (`ml/app/ocr/`), so a comparison differs only in
the model. All the photos of a receipt go in one request, in order; the temperature is 0. The repair pass
is a second request with the same photos, the first answer and the problems found.

`OPENROUTER_OCR_MODEL` has no default: a hosted model costs money and has its own data policy, so it is
always chosen on purpose. Without it the service refuses to start.

### Zero data retention, enforced by the code

OpenRouter's documentation (pages "Zero Data Retention" and "Provider Routing", and the API reference,
read on 2026-11-18) gives these tools:

- the request field `provider.zdr: true` limits routing to endpoints in OpenRouter's zero-data-retention
  list. It is combined with the account's and a guardrail's settings as an OR: it can turn enforcement on,
  never off;
- `provider.data_collection: "deny"` limits routing to providers that do not store or train on the data;
- **but** the ZDR list also holds **Safety Retention** endpoints: the provider may keep prompts its safety
  classifiers flag, up to 90 days, to fight abuse (Google's models on Vertex since October 2026, and some
  open-weight models on Vertex). A request with `zdr: true` reaches them unless the account's privacy
  settings or a guardrail say "ZDR only", and self-serve accounts allow them by default. There is no
  request field that excludes them;
- `provider.only` limits routing to the listed endpoints; a full endpoint slug (`provider/variant/...`)
  matches exactly one endpoint;
- the public list `GET /api/v1/endpoints/zdr` gives every ZDR endpoint with its `model_id`, its slug
  (`tag`), its provider name, its supported parameters and a `safety_retention` flag.

So the backend does not rely on the account setting alone:

1. Before the first call, and again when the list is an hour old, it reads the public model list and the
   ZDR list (two GETs without the key, without any receipt data), and keeps the configured model's
   endpoints whose `safety_retention` is explicitly `false`, minus any slug that would also match a
   retaining endpoint of the model (in `only`, `vendor` also matches `vendor/eu`; none such exists in the
   list today, but the guard costs nothing). A model that is unknown, takes no images or
   has no such endpoint stops the service at start-up (HTTP 501 if asked anyway). A list that cannot be
   read means no call: 503 `openrouter_catalogue_unavailable`.
2. Every request carries `provider: {"only": [those endpoint slugs], "zdr": true, "data_collection":
   "deny", ...}`. The two privacy fields come from a constant applied last, and no setting reaches them:
   there is nothing to switch off.
3. Every answer names the provider that served it. An answer from a provider outside the list (or without
   one) is discarded with 424 `openrouter_provider_unverified`, and from then on the backend sends
   nothing until the service is restarted (an evaluation run stops): a photo may already have gone to the
   wrong place, and a person has to look before any more do.

The owner should still set the account's privacy settings to "ZDR only" for every model group and leave
prompt logging off: it closes the same door twice and also covers any request made outside this code.

What zero data retention covers, by OpenRouter's documentation: the provider routing of inference
requests. OpenRouter itself does not keep prompts or answers unless the account opts in to logging, with
one exception it announced for 2026-10-27: screening for child sexual abuse material, which covers ZDR
traffic too. In-memory prompt caching does not count as retention. OpenRouter records the request's
metadata (time, model, token counts, cost) for billing; that is not the content.

### Only the photos and the fixed prompt are sent

- **Photos.** Each photo is decoded, turned upright, scaled to `OPENROUTER_OCR_IMAGE_MAX_SIDE` and then
  copied pixel by pixel into a new image that is encoded as a fresh JPEG: no EXIF (camera, time, GPS),
  ICC profile, XMP or comment survives, and a test proves it on a photo that carries GPS tags. They are
  sent as data URLs, so no file name goes with them.
- **Text.** Only the fixed system and user prompt of `ml/app/ocr/prompt.py`; in the repair pass also the
  model's own first answer and the list of problems (field names and error types).
- **Nothing else**: no receipt id, file name, transaction, payee, comment, bank description, ledger data
  or user id. The request has no `user`, `session_id`, `metadata`, `trace` or `plugins` field.
- **Headers.** `Authorization` (the key), `Content-Type`, `Accept`, a generic `User-Agent: ocr-client`,
  and httpx's own `Host`, `Content-Length`, `Accept-Encoding` and `Connection`. No `HTTP-Referer` or
  `X-Title` (OpenRouter's optional attribution headers, which would name the app), nothing that names
  the owner or the machine. The client reads nothing from the environment (`trust_env=False`: no proxy
  variables, no `.netrc`), follows no redirect, and drops cookies before every request, so a cookie set
  on an anonymous catalogue read never ties it to the keyed chat request. The network still sees the
  machine's IP address.
- **The key** (`OPENROUTER_API_KEY`) is read in `ml/app/config.py` as a secret (`SecretStr`), sent only in
  the chat request's `Authorization` header (the catalogue is read without it), and never logged, put in
  an error, or written to a run folder. A key with spaces or control characters (a pasted line break) is
  refused (501 `openrouter_key_invalid`) before it reaches the HTTP stack, whose own errors and debug
  logs would quote the header. Upstream error bodies are never passed on: they can echo the
  request; the service answers with its own short message.

What leaves the machine is still the photo: whatever is printed on the receipt (the shop, the items, the
time, the masked card number) reaches the provider, which processes it and keeps nothing.

### No card-digit blurring

A card slip prints a masked card number (`**** 1234`). Blurring it before the call was considered and not
built: finding the digits on the photo is OCR in itself, either the local model (which takes 10 to 75
seconds per receipt and would make the hosted call pointless for pre-filling) or a separate text detector
(a new dependency, unreliable on thermal paper, and a missed digit gives a false sense of safety). The
digits shown are the last four of the card, which the receipts print by law precisely because they are
not enough to use the card. They go to a zero-retention endpoint like the rest of the photo. This is a
documented limitation; if it matters later, the ingest tool's crops could mask a fixed region per known
terminal layout.

### Structured output when the endpoints support it

When some of the allowed endpoints list `structured_outputs` and `response_format`, the request asks for
the answer's JSON schema (`response_format: json_schema`, strict) and `only` names just those
endpoints; otherwise it asks for plain JSON and the shared parser takes the object out
of the text. Every call records which was used. `OPENROUTER_STRUCTURED_OUTPUT=false` turns it off (to
compare with free generation, or when a provider refuses the schema). Either way the answer is parsed and
checked, as with the local model's constrained decoding. `require_parameters` is not sent: `only` already
names endpoints that support the schema, and the flag would also drop any endpoint that does not list
`temperature` or `max_tokens`, turning a usable model into a misleading "no endpoint" error.

### Errors follow the service contract

The Rails job retries a 5xx other than 501 and treats a 4xx or 501 as permanent:

| Situation | Status | Code |
| --- | --- | --- |
| `OPENROUTER_OCR_MODEL` / `OPENROUTER_API_KEY` missing; a malformed key | 501 | `openrouter_model_missing` / `openrouter_key_missing`; `openrouter_key_invalid` |
| model unknown, without image input, or without a strict ZDR endpoint | 501 | `openrouter_model_unknown`, `openrouter_model_without_images`, `openrouter_no_zdr_endpoint` |
| ZDR list cannot be read | 503 | `openrouter_catalogue_unavailable` |
| OpenRouter 429 | 503 | `openrouter_rate_limited` |
| OpenRouter 408 or 5xx | 502 | `openrouter_upstream_error` |
| the receipt's `OPENROUTER_TIMEOUT` runs out | 504 | `openrouter_timeout` |
| OpenRouter cannot be reached | 502 | `openrouter_unreachable` |
| an answer that is not a chat completion | 502 | `openrouter_bad_response` |
| OpenRouter 401 / 402 / 403 | 424 | `openrouter_auth_failed` / `openrouter_payment_required` / `openrouter_refused` |
| OpenRouter 404 (no allowed endpoint can serve the request now) | 424 | `openrouter_no_matching_endpoint` |
| any other OpenRouter 4xx | 424 | `openrouter_bad_request` |
| an answer from a provider outside the list | 424 | `openrouter_provider_unverified` |
| the answer unreadable after the repair pass | 422 | `ocr_parse_failed` (as for the local model) |

An error reported inside an answer with HTTP 200 (at the top level or in the choice) is mapped by its
numeric code in the same way, and to 502 without one.

424 (Failed Dependency) is a 4xx, so the job marks the receipt failed at once instead of paying for five
attempts that would be refused the same way. A missing key starts the service anyway (it logs the
problem and `/ocr` answers 501), so the receipt page shows the reason instead of an unreachable service.

### Cost and latency are measured per call

OpenRouter puts `usage` (prompt and completion tokens, and `cost`, the amount charged in credits, which
are US dollars) in every answer without any request option. The answer is parsed with JSON numbers as
`Decimal`, so the cost keeps its exact digits, and costs are added as `Decimal` with enough precision to
stay exact (`ml/app/decimals.py`; a cost of more than 50 digits counts as unknown). A receipt's cost is
the sum of its calls, null when any call did not report one (a partial sum would understate it). A call
whose answer was lost after it was sent (a read timeout, a cut connection, an unreadable answer) may
have been charged, so it counts as a call with an unknown cost; a call refused with an error status
counts as not charged. Token counts are null, not zero, when a call did not report them. Each call
also records its latency, the upstream provider, the served model and whether structured output was used.

`ocr_run` writes this per receipt into `predictions.jsonl` (also for a receipt that failed after a call:
it was paid for) and sums it in `run.json`; `ocr_fields` reports the cost per receipt and per 1,000
receipts next to the seconds per receipt. The averages cover the receipts with a reported cost, and the
summary says how many had none. The averages are rounded for the report (a millionth of a dollar per
receipt, a ten-thousandth per 1,000); the totals are exact.

### `model_version` is the model's dated slug

For a hosted model there are no weights to name. `/health` and `/ocr` report as `model_version` the
model's `canonical_slug` from OpenRouter's model list (for example `vendor/model-20260101`), which changes
when the model behind the id changes; `model_name` is the id that was configured. The model each call was
actually served by (the answer's `model`) is recorded per call in the evaluation run.

### What stays local, always

The transaction categoriser (`docs/decisions/0006-transaction-categoriser.md`) and all ledger data:
transactions, payees, comments, bank descriptions, accounts, categories. `/categorise` answers 501 on this
backend. Nothing in this backend reads the database; it sees only the photos it is handed.

## Consequences

- With `OCR_BACKEND=openrouter`, receipt photos leave the machine, to the endpoints described above. The
  default stays `stub`, and the local `mlx` backend is unchanged.
- The service needs the network at start-up (to read the lists) and for every receipt. A model whose only
  ZDR endpoints use Safety Retention (most Google models today) cannot be used.
- The ZDR list is trusted for an hour. A provider that changes its policy within that hour is still
  excluded by `zdr: true` if OpenRouter drops it from ZDR routing; a move to Safety Retention would be
  caught at the next read.
- A hosted model can be retired or changed behind its id; `model_version` and the per-call `model` make
  that visible in stored results and runs.
- Hosted providers scale large images themselves, and they count image tokens differently, so the same
  photo costs different amounts on different models. The cost is measured, not estimated.
- A receipt that needs the repair pass makes two calls and costs about twice as much.
  `OPENROUTER_TIMEOUT` (100 seconds by default) is one budget for the whole receipt, kept under the
  Rails client's 120-second OCR timeout: the client should not give up and retry (sending the photos
  again, and paying again) while the service is still waiting for a call. httpx's read timeout restarts
  when data arrives, so the budget is close but not exact; a provider that trickles its answer could
  overrun it. A 504 is still retried by the job, which sends the photos again.
