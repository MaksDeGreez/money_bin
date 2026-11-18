# 0017. OCR batch mode: many receipts in one provider batch, as a separate opt-in

Status: accepted. Built off by default, for later use; the live check could only reach the account's
refusal (below).

## Context

Receipts are read one at a time: `ReceiptOcrJob` sends a receipt's photos to the ML service, which asks a
local model or a hosted one through OpenRouter (`docs/decisions/0012-hosted-ocr-backend.md`) and answers in
seconds. Hosted providers also offer a **batch mode**: many requests are submitted together, processed when
the provider has capacity (usually minutes, at most about 24 hours) and billed at about half the price. The
owner cannot use it today, but wants the option built for the day thousands of receipt photos have to be
read, when cost matters more than waiting.

Two facts from OpenRouter's Batch API documentation decide the design.

1. **Retention.** OpenRouter keeps a batch's requests and results for 30 days unless the batch is deleted
   earlier; batch endpoints do not train on the data; and a batch "cannot run when your privacy settings
   require ZDR for the model's provider". None of the `:batch` endpoints is on the zero-retention list. Zero
   data retention and batch mode are mutually exclusive.
2. **Images.** By default a batch takes only public image URLs. Inline base64 images are allowlist-only:
   the account must be allowed, and the provider must be one verified to read them, with its own size caps
   (5 MiB per image for Anthropic, 20 MiB for OpenAI, and so on).

The synchronous path's rule (0012) is that a hosted call goes only to endpoints that keep nothing. Batch
mode cannot meet it.

## Decision

### A separate, explicit opt-in that says what it gives up

Batch mode is its own capability (`app/batch/` in the ML service, `OcrBatch` in the app), switched on only
by `OPENROUTER_BATCH_ALLOW_RETENTION=true`. The name states the trade. Without it every batch endpoint of
the service refuses with 501 `openrouter_batch_not_allowed`, whose message says why, and the app shows no
"Read in a batch" button. No setting of the synchronous path enables it, and nothing in the synchronous
path changed: `/ocr` still routes only to strict zero-retention endpoints with `zdr: true` and
`data_collection: "deny"`, and the only shared code is the function that builds one receipt's request body
(now `receipt_request_body`, from which the synchronous path still builds its request and then adds its
privacy preferences). A halt of the synchronous path (an answer from an unverified provider) stops batches
as well.

Within batch mode the rules that can still hold, hold:

- **Named providers only.** `OPENROUTER_BATCH_PROVIDERS` names the endpoint slugs a batch may run on; the
  batch is sent with `provider.only` set to those that serve the model's `:batch` variant, and
  `allow_fallbacks: false`. A provider not known to read inline images in a batch is refused at
  configuration. The provider that ran the batch, and the one each answer names, are checked; an answer
  from anywhere else is not used.
- **Only the photos and the fixed prompt.** Each request is the synchronous request body (the same prompt,
  the same re-encoded photos without metadata, temperature, max tokens and answer schema) with the
  receipt's random key as `custom_id`. No file name, no id of the app, no ledger data, no attribution
  header.
- **Never a public URL.** No code path uploads a photo anywhere or sends a URL to one. When inline images
  are refused, the batch fails with `openrouter_batch_inline_images_refused`, its receipts are released,
  and they are read one at a time instead. There is no fallback that hosts a photo.
- **Deleted as soon as possible.** The app deletes each batch at OpenRouter as soon as its results are
  stored, or as soon as it fails or expires, and records what OpenRouter reports about the provider's copy
  (`deleted`, `unsupported`, `not_applicable`). The retention is then as short as the provider's processing
  plus one poll interval, not 30 days.
- **A model without a batch variant is refused**, as is a missing model or provider setting.

### What the owner must arrange, which this code cannot

1. Relax the OpenRouter account's privacy settings so that the batch provider does not require zero data
   retention. Without that every submission is refused (see "Verified live"). This also relaxes the
   account-level guard for any other request to that provider; the synchronous path's own per-request
   enforcement is unaffected.
2. Get the account on OpenRouter's allowlist for inline images in batches, and choose a provider that
   reads them.

The code never changes an account setting.

### The service stays stateless; the key mapping lives in the app

The service builds the provider batch and re-reads everything else from OpenRouter; it keeps nothing
between calls. The one mapping that must exist, from a provider result to a receipt, is kept by the app:
every receipt in a batch gets an entry (`OcrBatchEntry`) with a random 24-character key from SecureRandom,
sent as the request's `custom_id`. The key is opaque to the provider and to the service; it is not the
receipt id. A key in the app's database is the natural place: the app already is the record of every
receipt, and a mapping in the service would need its own storage and backup for the 30 days a batch can
live.

### Limits and splitting

The service accepts at most 100 receipts and 300 MB of photos per create request and refuses a provider
body over 190 MB (OpenRouter's limit is 200 MB; its cap on requests per batch is only reported in its 413).
The app splits a selection in the list's order into batches of at most 100 receipts and 150 MB of stored
photos, sends them one after the other (OpenRouter also limits the batches an account runs at once, and
each upload holds its photos in memory), and halves a batch that is still refused as too large. The
re-encoded photos of a receipt at the default 2048 px side are a few hundred kilobytes each, so a batch of
100 receipts is tens of megabytes.

### Polling, not a webhook

OpenRouter can call a webhook when a batch ends, but it needs a public HTTPS URL, and this local app has
none (and should not open one). So the app polls: a self-rescheduling Sidekiq job (`OcrBatchPollJob`),
no scheduler gem. It checks each batch when it is due: after 1 minute, then 1.5, 2.25, ... up to every 15
minutes (OpenRouter suggests once a minute, and most batches finish in minutes), backing off on errors. One
chain runs at a time, identified by a token in the cache; a lost chain (an emptied queue, a killed worker,
a cleared cache) is restarted by the batches page, the receipts list, a new batch and the worker's start
once it is ten minutes overdue. A PostgreSQL advisory lock keeps two runs from overlapping.

### Idempotency

- **Claiming.** The hold is a column on the receipt (`ocr_batch_id`), written under the row lock in the
  same way as `ocr_requested_at`; each claim takes only rows where the other is not set. One column means a
  receipt is in at most one open batch.
- **Submitting.** A batch moves `pending` -> `submitting` under its row lock, so a duplicate job does
  nothing. A failure where nothing reached the provider returns it to `pending` with a growing wait. A
  failure after the photos were sent (a lost answer, a server error after the upload) cannot be retried
  safely: it could pay for the batch twice and leave a second copy at the provider. Such a batch becomes
  `unknown`, its receipts are released, and the owner is told to look for it in OpenRouter's logs. A
  submission that is still `submitting` after 15 minutes died mid-send and is treated the same way.
- **Applying.** Each entry is resolved in its own transaction with the entry and the receipt locked, and
  only while it is `waiting`; the result is stored only while the receipt is still held by this batch and
  still `uploaded` or `failed`. A poll that runs twice applies nothing twice; one that dies half way leaves
  the rest `waiting` for the next poll; an unexpected error on one entry releases that receipt and goes on.
- **A person's work wins.** "Enter by hand" clears the hold under the same row lock, so the batch's result
  for that receipt is not used. A reviewed receipt is never held (only unread and failed receipts are
  sent), and `Receipts::ApplyOcr` still refuses a reviewed receipt.

### Answers that need the repair pass

A batch cannot run the synchronous path's repair pass (a second call with the first answer and its
problems). An answer that does not parse is reported per receipt as `ocr_parse_failed` with
`retry_sync: true`, and counted. The app hands such receipts to the normal queue (a read one at a time,
which has the repair pass), up to max(5, 10% of the batch). Beyond that something is systematically wrong,
and reading hundreds of receipts again at full price is not done unasked: those receipts are marked
`failed` with the reason, and "Read again" or "Read all" can retry them. Every other per-receipt error marks
the receipt `failed` with the reason; the message says when a read one at a time may help.

### What follows a result

A batch result goes through exactly what follows a synchronous read: `Receipts::ApplyOcr`, then the
category suggestions (`Receipts::SuggestCategories`). The suggestions are queued as one
`ReceiptCategoriseJob` per receipt on the OCR capsule's `receipt_categorise` queue rather than run in the
poller: a local categoriser reads one receipt at a time on that capsule, and a batch of thousands must not
hold up polling and deleting.

### Cost

Before submitting, the service estimates the cost from the model's batch price (the highest among the
allowed endpoints) and predicted tokens: the fixed prompt at 3 characters per token, 1,600 tokens per photo
and 1,200 answer tokens per receipt, plus a maximum with every answer at `OPENROUTER_MAX_TOKENS`. It is
rough, within a factor of two, because image tokens depend on the provider and each photo's size; the
confirmation page says "about". After the batch, OpenRouter's `usage.cost` is stored as the actual cost. All
costs are decimals end to end: `Decimal` in the service (JSON numbers parsed as `Decimal`), decimal strings
over HTTP, `BigDecimal` and `numeric` without a scale in the app, so no digit is rounded away.

## Verified live, and not

On 2026-11-18, with the owner's key, one tiny batch was submitted: a single text-only request ("Answer with
the single word ok.", no image, nothing from a receipt) to `anthropic/claude-haiku-5.5` (the plain slug of
a `:batch` variant), `provider: {"only": ["anthropic"], "allow_fallbacks": false}`, `requests` last.

- The submission answered **HTTP 422**: "Batch and other async APIs retain submitted data regardless of
  the provider's advertised retention policy, so this endpoint cannot be used with your Zero Data Retention
  settings. Update your privacy settings at https://openrouter.ai/settings/privacy." No batch was created
  (the account's batch list stayed empty) and nothing was charged. That refusal is the finding: the
  account is set to zero retention, as 0012 asks, and batch mode stays unusable until the owner decides
  otherwise. No account setting was changed.
- With the same key, `GET /api/v1/batches?limit=1` answered 200 with an empty list, and `GET` and `DELETE`
  of a made-up batch id answered 404 `{"error": {"code": 404, "message": "Batch job … not found."}}`: the
  keyed status and delete paths and the error shape the service maps (404 -> `batch_not_found`).
- The service maps a 422 whose message names zero data retention or the privacy settings to 424
  `openrouter_batch_zdr_required`.

Not verified live: a batch's statuses from `validating` to `completed`, the shape of `results` and of the
deletion answer, the timing, and above all inline images in a batch, which stay unverified until the
account allows retention for the batch provider and is on the allowlist. The code follows the documented
shapes and is tested against them with a fake transport. Before first use, the owner should repeat the
envelope check (one text-only request) once the account allows it.

## Consequences

- With batch mode allowed, receipt photos are kept by OpenRouter and the provider until the batch is
  deleted: minutes to a day in practice, 30 days at most if the deletion fails. The batches page shows what
  happened to each provider copy.
- The synchronous path keeps its zero-retention enforcement unchanged; the two paths share only the
  request body and the answer reading, so a batch result and a synchronous result of the same answer are
  identical.
- A receipt waiting in a batch is not read one at a time and opening it does not queue OCR; it can wait up
  to a day. "Enter by hand" stays available and wins.
- A lost submission (`unknown`) needs the owner to look in OpenRouter's logs; the app cannot find the batch
  without its id.
- Thousands of results queue thousands of short categorise jobs ahead of the synchronous OCR queue (the
  capsule works `receipt_categorise` first); with a local categoriser that is seconds per receipt.
