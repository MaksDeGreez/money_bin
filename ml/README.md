# money_bin ML service

A small HTTP service for the money_bin app. It does three jobs:

- **Receipt OCR.** It reads a receipt from 1 to 3 photos and returns the
  merchant, date, total and items.
- **Item categorisation.** It suggests a category, with a confidence, for each
  item of one receipt, from the categories the request lists.
- **Transaction categorisation.** It suggests the three most probable
  categories of each ledger transaction with the transaction categoriser
  trained in `categoriser/` (see "The transaction categoriser"). Always local:
  it has no backend setting and no hosted variant.

The Rails app calls this service and stores the results.

Each job has its own backend setting: `OCR_BACKEND` for OCR and
`CATEGORISE_BACKEND` for categorisation, each one of:

- **`stub`** (the default) returns fixed, invented data in the final response
  shapes. The tests and CI use it.
- **`mlx`** runs a local model with [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)
  on a Mac with Apple silicon: a Qwen VL model reads receipts, and the same
  model (by default) categorises items. Nothing leaves the machine.
- **`openrouter`** calls a hosted model through [OpenRouter](https://openrouter.ai),
  only through endpoints with zero data retention. For OCR the receipt photos
  and the fixed prompt leave the machine; for categorisation the item names and
  the fixed prompt with the category list. Nothing else does (see "The
  openrouter backend" and "The hosted categoriser").
- **`decisions`** (categorisation only) asks a hosted *decision model* (for
  example TypeSafe's Jev) through OpenRouter's Decisions API, with the same
  zero-retention rules: one typed question per item, answered with a
  probability for every category. Only the item names and the category list
  leave the machine (see "The decision-model categoriser").

So OCR can run locally while categorisation is hosted, or the other way round.

With `OCR_BACKEND=openrouter` the service can also read many receipts in one
provider **batch**, at about half the price and with a wait of minutes to a
day. A batch is not zero-retention, so it is off unless explicitly allowed
(`OPENROUTER_BATCH_ALLOW_RETENTION`, see "Batch mode").

## Requirements

- [uv](https://docs.astral.sh/uv/)
- Python 3.12 (uv installs it if it is missing)
- For the `mlx` backend: macOS on Apple silicon, about 7 GB of free memory
  while it runs, and about 6 GB of disk per model in the Hugging Face cache.

## Install

```sh
cd ml
uv sync
```

A plain `uv sync` installs the `dev`, `categoriser` and `mlx` dependency
groups (`[tool.uv] default-groups`). The `mlx` group (mlx-vlm, pinned exactly, and
with it MLX and transformers) carries the markers
`sys_platform == 'darwin' and platform_machine == 'arm64'`, so on any other
machine, Linux CI included, it installs nothing. The `stub` backend and every
test work without it.

## Run

```sh
uv run uvicorn app.main:app --host 127.0.0.1 --port 8100
OCR_BACKEND=mlx CATEGORISE_BACKEND=mlx uv run uvicorn app.main:app --host 127.0.0.1 --port 8100
```

With `OCR_BACKEND=mlx` the service loads the model when it starts and is ready
when uvicorn prints "Application startup complete" (a few seconds once the
weights are in the cache). The first start downloads the weights from Hugging
Face (about 5.5 GB); later starts read the cache and do not contact the Hub. A
model that cannot be loaded stops the service at startup.

The interactive API docs are at <http://127.0.0.1:8100/docs>.

## Test and lint

```sh
uv run pytest                 # tests with coverage; fails below 70%
uv run ruff check .           # lint
uv run ruff format --check .  # format check (use `ruff format .` to fix)
```

The tests never load a model and never reach the network: the `mlx` backend
is tested with a fake generator, the `openrouter` backend with a fake
transport (and httpx's mock transport for the real client), the local
categoriser with a fake character-level model. `app/backends/mlx_vlm_generator.py`
and `app/categorise/mlx_token_model.py`, the only code that calls mlx-vlm, are
left out of the coverage measurement; they were checked by hand on the real
model (`python -m evaluation.item_sanity`, below).

## Settings

| Variable                       | Default                                     | Values                      | Meaning |
| ------------------------------ | ------------------------------------------- | --------------------------- | ------- |
| `OCR_BACKEND`                  | `stub`                                      | `stub`, `mlx`, `openrouter` | The OCR backend. |
| `CATEGORISE_BACKEND`           | `stub`                                      | `stub`, `mlx`, `openrouter`, `decisions`, `off` | The item categoriser, chosen apart from OCR. `off` switches suggestions off: `/categorise` answers 501, and the Rails app, which reads the same setting, asks nothing and fills nothing, not even from its label memory (labelling with no suggestions on screen, `docs/domain.md`). |
| `MLX_CATEGORISE_MODEL`         | empty: `MLX_OCR_MODEL`                      | a Hugging Face id or a folder | The local categoriser's model. Empty means the OCR model: with `OCR_BACKEND=mlx` the one loaded model does both jobs (see "One model or two"). A text model such as `mlx-community/Qwen3-4B-Instruct-2507-4bit` works too. |
| `CATEGORISE_CALIBRATION_FILE`  | none                                        | a path outside the repository | A calibration of the categoriser's scores (see "Calibration"). It must have been fitted for the configured categoriser and model, or the service does not start. |
| `OPENROUTER_CATEGORISE_MODEL`  | none                                        | a model id from openrouter.ai/models | The hosted categoriser's model (text only is fine). No default: with `CATEGORISE_BACKEND=openrouter` the service does not start without it. |
| `DECISIONS_MODEL`              | none                                        | a decision model's id on openrouter.ai | The decision-model categoriser's model, for example `typesafe/jev-1.14`. No default: with `CATEGORISE_BACKEND=decisions` the service does not start without it. A moving alias (`~typesafe/jev-latest`) is refused: it has no zero-retention endpoint of its own. |
| `DECISIONS_STRATEGY`           | `flat`                                      | `flat`, `two-stage`         | One question per item over every category, or the group first and then the category within it (see "The decision-model categoriser"). |
| `DECISIONS_RECEIPT_CONTEXT`    | `true`                                      | `true`, `false`             | Give each item the other item names of its receipt; `false` sends each item alone (for comparison only). |
| `DECISIONS_MAX_QUESTIONS`      | `16`                                        | 1 to 64                     | The most items (questions) in one request; a request is also cut below 24,000 bytes. |
| `TRANSACTION_CATEGORISER_MODEL` | empty: the newest `transaction-categoriser-*.serving.joblib` in `~/Documents/money_bin_data/models/` | a path outside the repository | The transaction categoriser's artefact (`python -m categoriser.serving`). Read on the first request that needs it, once; missing or unreadable, `/categorise/transaction` answers 501 and nothing else is affected. |
| `ML_MAX_IMAGE_BYTES`           | `15728640`                                  | a whole number above 0      | The largest image file, in bytes (15 MB). |
| `MLX_OCR_MODEL`                | `mlx-community/Qwen3-VL-8B-Instruct-4bit` | a Hugging Face id or a folder | The `mlx` backend's model. `mlx-community/Qwen3-VL-8B-Instruct-4bit` works too. |
| `MLX_OCR_MAX_TOKENS`           | `3072`                                      | a whole number above 0      | The most tokens the model may write for one answer. A receipt with 40 items needs about 2,000. |
| `MLX_OCR_IMAGE_MAX_SIDE`       | `2048`                                      | 256 to 4096                 | Each photo is scaled down so that its longer side is at most this many pixels. |
| `MLX_OCR_CONSTRAINED_DECODING` | `true`                                      | `true`, `false`             | Constrain the model's answer to the JSON schema (see "The mlx backend"). |
| `OPENROUTER_API_KEY`           | none                                        | an OpenRouter API key       | The `openrouter` backend's key. A secret: keep it in the git-ignored `.env`. Without it the service starts and `/ocr` answers 501 `openrouter_key_missing` (`openrouter_key_invalid` for a key with spaces or control characters). |
| `OPENROUTER_OCR_MODEL`         | none                                        | a model id from openrouter.ai/models | The `openrouter` backend's model. No default: without it the service does not start. |
| `OPENROUTER_TIMEOUT`           | `100`                                       | seconds, 10 to 600          | A hard deadline for one receipt: reading the endpoint list when it is due, the call and the repair call together, connecting and uploading included; an answer still arriving at the deadline is abandoned. A call is not started with less than 10 seconds left, a repair call not with less than the first call took. Keep it under the Rails client's `ML_SERVICE_OCR_TIMEOUT` (120), so the client does not retry (and pay again) while a call is still running. |
| `OPENROUTER_MAX_TOKENS`        | `3072`                                      | a whole number above 0      | The most tokens the model may write for one answer, as `MLX_OCR_MAX_TOKENS`. |
| `OPENROUTER_OCR_IMAGE_MAX_SIDE` | `2048`                                     | 256 to 4096                 | As `MLX_OCR_IMAGE_MAX_SIDE`, for the photos sent to the hosted model. |
| `OPENROUTER_STRUCTURED_OUTPUT` | `true`                                      | `true`, `false`             | Ask for the answer's JSON schema when the endpoints support it (see "The openrouter backend"). |
| `OPENROUTER_BATCH_ALLOW_RETENTION` | `false`                                 | `true`, `false`             | Allow batch mode, which is not zero-retention (see "Batch mode"). Off: every batch endpoint answers 501. |
| `OPENROUTER_BATCH_MODEL`       | none                                        | a model id with a `:batch` variant | The model batches read receipts with. |
| `OPENROUTER_BATCH_PROVIDERS`   | none                                        | endpoint slugs, comma-separated | The providers a batch may run on (`provider.only`, no fallbacks). |

An unknown `OCR_BACKEND` or `CATEGORISE_BACKEND` value stops the service at
startup. The error message lists the valid names. The other `OPENROUTER_*`
settings (key, timeout, structured output) are shared by the two hosted tasks.

Each model backend has its own image-size setting with the same default
(2048), not one shared setting: the local and the hosted backend can then be
tuned apart (a hosted model's cost grows with the pixels), while a comparison
run with the defaults sends both the same pixels. `MLX_OCR_IMAGE_MAX_SIDE`
keeps its name and its behaviour.

The service reads its settings from the real environment only. `bin/dev`
starts it through foreman, which loads the repository's `.env`; for a command
run by hand, pass the file: `uv run --env-file ../.env ...`.

## Endpoints

### `GET /health`

```sh
curl http://127.0.0.1:8100/health
```

```json
{"status": "ok", "backend": "stub", "model_name": "stub-ocr", "model_version": "0.1.0",
 "categoriser": {"backend": "stub", "model_name": "stub-categoriser", "model_version": "0.2.0", "calibration": false}}
```

`backend`, `model_name` and `model_version` are the OCR backend's; `categoriser`
is the categoriser's, with whether a calibration file is loaded.

With `mlx`, `model_name` is the model id (`MLX_OCR_MODEL`) and
`model_version` the revision of the weights: the Hugging Face commit, or
`local` for a model in a plain folder.

With `openrouter`, `model_name` is `OPENROUTER_OCR_MODEL` (`not-configured`
without it) and `model_version` the model's dated slug from OpenRouter's model
list (`canonical_slug`, for example `vendor/model-20260101`), which changes
when the model behind the id changes; `not-started` until the list was read.

### `POST /ocr`

Send `multipart/form-data` with the field `images`, 1 to 3 times. Allowed
types: `image/jpeg`, `image/png`, `image/webp`, `image/heic`. Several images
are overlapping photos of one long receipt, top to bottom.

Each file is checked before the backend sees it:

- its size must be at most `ML_MAX_IMAGE_BYTES` (15 MB by default). The
  multipart parser keeps uploads in temporary files, so an oversized file is
  refused from its size and never read into memory. The Rails app refuses a
  receipt photo over the same 15 MB before it stores it
  (`Receipt::MAX_IMAGE_BYTES`, a constant that does not read this setting);
- its first bytes (the file signature) must match the declared type: JPEG
  `FF D8 FF`, PNG `89 50 4E 47 0D 0A 1A 0A`, WebP `RIFF....WEBP`, HEIC/HEIF an
  `ftyp` box with a HEIF brand (`heic`, `heix`, `mif1`, ...). The declared
  content type alone is not trusted.

```sh
curl -F "images=@receipt.jpg;type=image/jpeg" http://127.0.0.1:8100/ocr
```

```json
{
  "receipt": {
    "kind": "fiscal",
    "merchant": "Example Market",
    "fiscal_number": "0000000000",
    "receipt_number": "000123",
    "issued_at": "2026-01-15T12:34:00+02:00",
    "total": "123.45",
    "currency": "UAH",
    "card_last4": null,
    "sum_matches_total": true,
    "items": [
      {"name": "Milk 2.5% 900 g", "quantity": "1.000", "unit_price": "42.50", "amount": "42.50", "discount": "0.00"},
      {"name": "White bread", "quantity": "1.000", "unit_price": "28.90", "amount": "28.90", "discount": "0.00"},
      {"name": "Bananas", "quantity": "0.850", "unit_price": "64.00", "amount": "52.05", "discount": "2.35"}
    ]
  },
  "prompt_version": null,
  "repaired": false,
  "elapsed_seconds": "0.001",
  "backend": "stub",
  "model_name": "stub-ocr",
  "model_version": "0.1.0"
}
```

The receipt:

- Money and quantities are decimal **strings**, never floats. Money has two
  decimal places and a quantity three. A value that was printed with more is
  returned as null, never rounded.
- Every key is always present; most values may be `null` when the model could
  not read them: `kind`, `merchant`, `fiscal_number`, `receipt_number`,
  `issued_at`, `total`, `currency`, `card_last4`, `sum_matches_total`, and an
  item's `quantity` and `unit_price`. An item always has a `name`, an
  `amount` and a `discount` (`0.00` when there is none). `items` may be empty.
- `kind`: `fiscal` (a fiscal receipt with items) or `card_slip` (a card
  terminal slip: merchant, date and time, total and masked card number, no
  items).
- `fiscal_number` is the cash register's fiscal number (10 digits, the `fn` of
  the receipt's QR code); `receipt_number` is the receipt's own fiscal number
  (the QR code's `id`).
- `issued_at` is the printed date and time read as Kyiv time, with its offset.
- `card_last4`: the last four digits of the card, when the document shows one.
- `amount` is the price of the line after the discount.
- `sum_matches_total`: whether the item amounts add up exactly to `total`;
  null when there is no total or no item, or an item was left out because its
  amount or its discount was unreadable.
- `currency` is an ISO 4217 code.

The rest of the answer:

- `prompt_version`: a short hash of the prompt and the answer schema the model
  was given (null for the stub). It changes whenever either changes.
- `repaired`: the model's first answer was not valid and the repair pass
  fixed it.
- `elapsed_seconds`: how long the backend took, as a decimal string. With
  `mlx` it includes the wait for an earlier request (one receipt is read at a
  time); with `openrouter` it includes both calls when the repair pass ran.

### `POST /categorise`

Send JSON with the items of ONE receipt (1 to 200 non-empty texts of at most
300 characters), the categories to choose from (2 to 100, unique slugs), and
optionally the shop's name:

```sh
curl -H "Content-Type: application/json" -d '{
  "texts": ["Мол2,5%900г", "Парацетамол №10"],
  "categories": [
    {"slug": "groceries/groceries", "name": "Groceries", "description": "Food and everyday groceries.", "group": "Groceries"},
    {"slug": "health/health-pharmacy", "name": "Health & pharmacy", "description": "Pharmacy, medicine and medical treatment.", "group": "Health"}
  ],
  "merchant": "Example Market"
}' http://127.0.0.1:8100/categorise
```

```json
{
  "results": [
    {"text": "Мол2,5%900г", "candidates": [
      {"category_slug": "groceries/groceries", "score": 0.981},
      {"category_slug": "health/health-pharmacy", "score": 0.019}]},
    {"text": "Парацетамол №10", "candidates": [
      {"category_slug": "health/health-pharmacy", "score": 0.997},
      {"category_slug": "groceries/groceries", "score": 0.003}]}
  ],
  "score_kind": "label_probability",
  "calibrated": false,
  "prompt_version": "0123456789ab",
  "categories_version": "ba9876543210",
  "elapsed_seconds": "1.204",
  "cost_usd": null,
  "backend": "mlx",
  "model_name": "mlx-community/Qwen3-VL-8B-Instruct-4bit",
  "model_version": "<weights commit>"
}
```

**The category list comes with every request.** The Rails app owns the
taxonomy and its slugs (`Categories::ItemCandidates`); the service never
hard-codes a category and never builds a slug. A category is `slug` (the
app's form, `group-part/category-part`), `name`, `description` (may be empty)
and `group` (the group's name). The answer may only name slugs from the
request: a categoriser that answered anything else would be a 500, and the
Rails client refuses such an answer too. So a taxonomy change on the app's side
cannot be silently ignored here: the next request carries the new list.
`categories_version` is a hash of the list as sent.

The response:

- `results`, in the order of `texts`: 1 to 3 candidates per item, best first,
  scores in 0..1 adding up to at most 1;
- `score_kind`: where the scores come from (`label_probability`,
  `token_logprobs`, `fixed`, `stub`, `decision_probability`; see "How
  confidence is computed");
- `calibrated`: the best candidate's score went through a calibration fitted on
  labelled items for exactly this categoriser, model, prompt and score kind;
  otherwise it is the raw score;
- `prompt_version`: the hash of the categorisation prompt (null for the stub);
- `elapsed_seconds`; `cost_usd`: what a hosted call cost (a decimal string), or
  null for a local model or when a call reported no cost;
- `backend`, `model_name`, `model_version`: the categoriser's.

The texts and the shop's name are put on one line each (a line break inside a
name would make a fake item). The stub picks slugs from a hash of the text, so
the same text and list always get the same answer.

### `GET` and `POST /categorise/transaction`

The transaction categoriser (see "The transaction categoriser"). `GET` says
which artefact answers (it loads the artefact, not the sentence encoder):

```json
{"model_name": "transaction-categoriser", "model_version": "2026-11-18-0123456789ab",
 "fitted_at": "2026-11-18T15:18:39+00:00", "configuration": "tfidf+emb:e5-base+recency+classweight+mix",
 "encoder": "e5-base", "encoder_loaded": false, "load_seconds": "0.081"}
```

`POST` takes the app's category list (the same hand-over shape as
`/categorise`) and 1 to 500 transactions:

```sh
curl -s -X POST -H 'Content-Type: application/json' -d '{
  "categories": [{"slug": "groceries/groceries", "name": "Groceries", "description": "", "group": "Groceries"}, ...],
  "transactions": [{"payee": "Example Market", "comment": null, "bank_description": "EXAMPLE MARKET STORE",
                    "merchant": "Example Market", "mcc": "5411", "amount": "-120.50", "currency": "UAH",
                    "account_kind": "debit"}]
}' http://127.0.0.1:8100/categorise/transaction
```

```json
{"results": [{"candidates": [{"category_slug": "groceries/groceries", "probability": 0.962},
                             {"category_slug": "groceries/snacks", "probability": 0.021}, ...],
              "source": "mix", "history": "payee", "history_weight": 0.952}],
 "model_name": "transaction-categoriser", "model_version": "2026-11-18-0123456789ab",
 "fitted_at": "2026-11-18T15:18:39+00:00", "elapsed_seconds": "0.014"}
```

- Every field of a transaction is optional, but a payee, comment, bank
  description, merchant or MCC must be there. `amount` is the signed amount
  in the account's currency as a decimal string with at most two places
  (an expense is negative); a JSON number, an exponent or a third place is a
  422, never rounded. `mcc` is four digits, `currency` three capital letters,
  `account_kind` the app's account kind. Unknown fields are refused. Without
  an amount, the transaction is scored as an expense of no size (the sign
  field says "out", the size bucket adds nothing).
- Each result has the three best categories, best first, with their
  probability in the served distribution (the model's probabilities mixed
  with the payee's or the MCC's category history, as the selected hybrid
  does), and where the answer came from: `source` `model` (no history weighed
  in), `mix` (the history of the payee, or of the MCC for an unknown payee,
  with weight `history_weight`) or `history` (the history decided; only a
  `switch` hybrid does that). The probabilities are the model's own, not
  calibrated: the precision at each confidence threshold measured on the
  validation slice is in the selection JSON.
- **Categories.** The model's classes are its training labels, the export's
  English group and category names (`"Group / Category"`). Each class is
  matched to the listed category with the same group and name (whitespace
  squished), and the answer names that category's slug; Python never builds a
  slug. A class the list does not name is a 422 `categories_mismatch` naming
  it: the model would otherwise suggest a category the app cannot store, or
  drop part of its probability silently. The app sends every category except
  Uncategorised (`Categories::TransactionCandidates`); a renamed category means
  refitting the model.
- `model_version` names the artefact: its fit date and the first 12 hex digits
  of the file's SHA-256. The app stores it with each suggestion and refreshes
  the suggestions when it changes.

### Errors

Every error has the same shape:

```json
{"error": {"code": "too_many_images", "message": "Send at most 3 files, got 4."}}
```

| Status | `code`                    | When                                           |
| ------ | ------------------------- | ---------------------------------------------- |
| 404    | `not_found`               | Unknown path.                                  |
| 405    | `method_not_allowed`      | Wrong HTTP method.                             |
| 413    | `image_too_large`         | An image is larger than `ML_MAX_IMAGE_BYTES`.  |
| 415    | `unsupported_media_type`  | An image has a type that is not allowed, or its content does not match its type. |
| 422    | `validation_error`        | Bad request body, e.g. no `images` field, bad `texts`. |
| 422    | `too_many_images`         | More than 3 images.                            |
| 422    | `empty_image`             | An image file is empty.                        |
| 422    | `image_unreadable`        | An image has the right signature but cannot be decoded (a cut-off file). |
| 422    | `ocr_parse_failed`        | The model's answer was not valid receipt JSON, even after one repair pass. |
| 422    | `categories_mismatch`     | `/categorise/transaction`: the model can answer a category the request does not list. |
| 501    | `transaction_categoriser_not_configured`, `transaction_categoriser_unavailable` | `/categorise/transaction`: no artefact is set up, or it cannot be served (unreadable, another format, fitted with another scikit-learn, the sentence encoder's weights are not in the local cache). Only this endpoint answers so; `/ocr` and `/categorise` are unaffected. |
| 422    | `categorise_parse_failed` | `openrouter` categoriser only: the answer did not name one listed slug for every item. Permanent (temperature 0). |
| 424    | `openrouter_auth_failed`, `openrouter_payment_required`, `openrouter_refused`, `openrouter_no_matching_endpoint`, `openrouter_bad_request`, `openrouter_provider_unverified` | `openrouter` only: OpenRouter refused the request (HTTP 401, 402, 403, 404, another 4xx, also when reported inside an answer with HTTP 200), or an answer came from a provider outside the zero-retention list (then nothing more is sent until the service restarts). Permanent. |
| 501    | `backend_not_implemented` | The selected backend cannot do this. |
| 501    | `openrouter_model_missing`, `openrouter_key_missing`, `openrouter_key_invalid`, `openrouter_model_unknown`, `openrouter_model_without_images`, `openrouter_no_zdr_endpoint` | `openrouter` only: a setting is missing, or the model is unknown, takes no images (OCR only) or has no strict zero-retention endpoint. |
| 502    | `openrouter_upstream_error`, `openrouter_unreachable`, `openrouter_bad_response` | `openrouter` only: the hosted service failed (HTTP 408 or 5xx, an error in the answer), cannot be reached, or answered in an unexpected shape. Transient. |
| 503    | `openrouter_rate_limited`, `openrouter_catalogue_unavailable` | `openrouter` only: rate limited (HTTP 429), or the list of zero-retention endpoints cannot be read (nothing is sent then). Transient. |
| 504    | `openrouter_timeout`      | `openrouter` only: no answer within the receipt's `OPENROUTER_TIMEOUT`. Transient. |
| 404, 409, 413, 422, 424, 501, 504 | `batch_*`, `openrouter_batch_*` | Batch mode only: see "Batch mode". |
| 500    | `internal_error`          | An unexpected error. Details go to the log.    |

The Rails job retries a 5xx other than 501 and treats a 4xx or 501 as
permanent. An `openrouter` error message is the service's own short text: an
upstream error body is never passed on, since it can echo the request.

`ocr_parse_failed` is a 4xx on purpose: the model is deterministic
(temperature 0), so sending the same photos again gives the same answer. The
message names the fields and the kind of problem, never what the model read.

## The mlx backend

`app/backends/mlx.py`. In short (the reasons are in
`docs/decisions/0005-local-ocr-backend.md`):

- **One worker thread.** MLX keeps its GPU streams per thread, and FastAPI runs
  each request in a thread of its own pool. So one dedicated thread (a
  single-thread executor, `app/backends/mlx_worker.py`) loads the model at
  startup and runs every generation; a request hands its work to that thread
  and waits. One receipt is read at a time; others wait in the queue. With
  `CATEGORISE_BACKEND=mlx` the categoriser shares this thread (and the model,
  when it is the same), so OCR and categorisation never use MLX at once.
- **One call per receipt.** All the photos of a receipt go to the model in
  one call, in order. Each is decoded, turned upright from its EXIF
  orientation and scaled to `MLX_OCR_IMAGE_MAX_SIDE` first
  (`app/ocr/images.py`).
- **Greedy decoding** (temperature 0): the same photos give the same answer.
- **Constrained decoding.** mlx-vlm's
  `structured.build_json_schema_logits_processor` (llguidance) lets the model
  write only tokens that keep the answer valid against the answer's JSON
  schema. This works with both Qwen2.5-VL and Qwen3-VL. It does not make the
  values right, and an answer cut off at `MLX_OCR_MAX_TOKENS` is still
  incomplete, so the answer is checked anyway (below).
- **The model call** is behind the small `VisionGenerator` protocol; the real
  one is `app/backends/mlx_vlm_generator.py`, imported only on the worker
  thread.

### Shared OCR modules

Everything except the model call lives in `app/ocr/`, so a hosted backend can
use the same prompt and rules and the two differ only in the model:

- `prompt.py`: the instructions (Ukrainian fiscal receipts and card slips,
  receipts in up to 3 overlapping photos, which number is which), the answer's
  JSON schema and `PROMPT_VERSION`. The model copies values as printed, as
  strings; it never calculates.
- `parsing.py`: takes the JSON object out of the model's text and checks its
  shape. When that fails, the model is asked once more with its answer and the
  problems found; when that fails too, the API answers 422 `ocr_parse_failed`.
- `postprocess.py`: plain code, never the model. Comma or dot decimals,
  thousands separators (only in groups of three), currency signs and the tax
  letter after an amount (`12,50 А`); a quantity line (`2 x 34.50`) the model
  listed as an item of its own is merged into the item it belongs to (above
  or below, when the numbers fit its amount); a discount line with a negative
  amount (`Знижка -5.00`) is folded into the item above, while a positive one
  (`Акційний набір 20.00`) stays an item; an item whose printed discount cannot
  be read is left out rather than given no discount; a number with more than
  10 digits before the point is refused; the date and time become Kyiv time;
  a fiscal number that is not 10 digits is refused; `sum_matches_total` is
  computed. It never rounds money: a value with more than 2 decimal places (3
  for a quantity) becomes null and is counted. Only `Decimal`, never a float.

## The openrouter backend

`app/backends/openrouter.py`. The reasons are in
`docs/decisions/0012-hosted-ocr-backend.md`. It uses the shared prompt,
parsing with its repair pass (a second request with the same photos, the first
answer and the problems found) and post-processing, so it differs from the
local backend only in the model. All the photos of a receipt go in one
chat-completions request, in order, at temperature 0.

### Zero data retention

Every request is routed only to endpoints that keep nothing and train on
nothing. The code enforces it; no setting can switch it off:

1. Before the first call, and again once the list is an hour old, the backend
   reads OpenRouter's public model list and its list of zero-data-retention
   endpoints (`GET /api/v1/models`, `GET /api/v1/endpoints/zdr`, without the
   key and without any receipt data). It keeps the configured model's
   endpoints whose `safety_retention` flag is explicitly `false`: a Safety
   Retention endpoint may keep prompts flagged by the provider's safety
   classifiers, and OpenRouter's `zdr` request flag alone still lets requests
   reach them on a default self-serve account. A slug that would also match a
   retaining endpoint of the model (in `only`, `vendor` also matches
   `vendor/eu`) is not used, nor is any endpoint of a provider that also has a
   retaining endpoint for the model (an answer names its provider, not its
   endpoint, so step 3 could not tell them apart). A retaining entry with
   neither a slug nor a provider name blocks the model.
2. Every request carries `provider: {"only": [those endpoints], "zdr": true,
   "data_collection": "deny", "allow_fallbacks": true}`. `zdr` and
   `data_collection` come from a constant applied last.
3. The provider each answer names must be one of those endpoints' providers
   (compared without case); any other answer is discarded (424
   `openrouter_provider_unverified`), and from then on the backend sends
   nothing until the service is restarted (`ocr_run` stops the run). Chat
   calls go one at a time, from sending to this check, so no request slips
   out while another one's answer is being checked; the Rails OCR queue reads
   one receipt at a time anyway. `/health` does not show the halt; the log
   does, and every `/ocr` answers 424 until the restart.

A model that is unknown, takes no images or has no such endpoint stops the
service at start-up. When the list cannot be read, no request is sent (503).
Still set the OpenRouter account's privacy settings to "ZDR only" for every
model group and leave prompt logging off: it covers requests made outside this
code too.

### What is sent

- the photos, decoded, turned upright, scaled to
  `OPENROUTER_OCR_IMAGE_MAX_SIDE` and re-encoded from their pixels as new
  JPEGs (no EXIF, GPS, ICC profile or comment), as data URLs: no file name;
- the fixed prompt of `app/ocr/prompt.py` (and, in the repair pass, the
  model's own first answer and the problems found);
- `model`, `temperature`, `max_tokens`, `stream`, `provider` and, with
  structured output, `response_format`. No `user`, `session_id`, `metadata`,
  `trace` or `plugins` field; no receipt id, ledger data or user id;
- headers: `Authorization: Bearer <key>`, `Content-Type`, `Accept`,
  `User-Agent: ocr-client`, and httpx's `Host`, `Content-Length`,
  `Accept-Encoding`, `Connection`. No `HTTP-Referer` or `X-Title` (the
  attribution headers that would name the app). The client ignores proxy
  variables and `.netrc`, follows no redirect, and keeps no cookie (no
  `Cookie` header ever goes out). The anonymous catalogue reads and the keyed
  chat requests use separate clients, so they share no connection.

The limits: what is printed on the receipt goes with the photo, including the
masked card number of a card slip (`**** 1234`). It is not blurred: finding it
needs OCR first (see the decision record). The provider processes the photo
and keeps nothing; OpenRouter keeps the request's metadata (time, model,
tokens, cost) for billing, and screens all traffic, ZDR included, for child
sexual abuse material. The network sees the machine's IP address.

The key is read as a secret (`SecretStr`), sent only in the chat request's
`Authorization` header, and never logged, put in an error or written to a run
folder. A key with spaces or control characters is refused before it reaches
the HTTP client, whose errors would quote the header. The tests use an obvious
fake key and a fake transport, and a fixture makes every socket connection in
the test run fail, so no test can reach the network.

### Structured output

When some of the allowed endpoints support structured outputs, the request
asks for the answer's JSON schema (`response_format` with `json_schema`,
strict) and `only` names just those endpoints; otherwise it asks for plain
JSON.
The answer is parsed and checked either way. `OPENROUTER_STRUCTURED_OUTPUT=false`
turns the schema off. Each call records which was used.

### Cost

Every OpenRouter answer carries `usage`: prompt and completion tokens and
`cost`, the amount charged in credits (US dollars). The answer is parsed with
numbers as `Decimal`, so the cost keeps its exact digits, and costs are added
with enough precision to stay exact (`app/decimals.py`; a cost of more than 50
digits counts as unknown). A call whose answer was lost after it was sent (a
read timeout, a cut connection, an unreadable answer) may still have been
charged: it counts as a call with an unknown cost, so the receipt's cost is
null rather than too low. A call refused with an error status is counted as
not charged. Each call records its
latency, tokens, cost, the provider that served it, the model it ran
(`model`) and whether structured output was used; the evaluation scripts sum
them (below).

## Batch mode

`app/batch/`. Off unless explicitly allowed. The reasons are in
`docs/decisions/0017-ocr-batch-mode.md`.

A hosted provider's batch mode reads many receipts in one submission,
whenever it has capacity (usually minutes, at most about a day), at about half
the price of the same requests one at a time. It is for the day thousands of
receipt photos have to be read and cost matters more than waiting. Only the
`openrouter` backend has it; every other backend answers 501
`backend_not_implemented`.

### What it gives up

**A batch is not zero-retention.** OpenRouter keeps a batch's requests (the
photos and the prompt) and its results for 30 days unless the batch is deleted
earlier, and the provider holds them while it works. OpenRouter states that
batch endpoints do not train on the data, that a batch cannot run when the
account's privacy settings require zero data retention for the provider, and
none of the `:batch` endpoints is on its zero-retention list. So batch mode
cannot meet the rule of the synchronous path, and it is a separate opt-in:

- `OPENROUTER_BATCH_ALLOW_RETENTION=true` turns it on. Without it every batch
  endpoint refuses with 501 `openrouter_batch_not_allowed`, whose message says
  why, and `/ocr/batches/capability` reports the same as "not available". No
  setting of the synchronous path turns it on, and nothing here changes the
  synchronous path: `/ocr` still sends only to strict zero-retention endpoints.
- The Rails app deletes each batch at OpenRouter as soon as its results are
  stored (or as soon as it fails or expires). OpenRouter then also deletes the
  provider's copy where the provider supports it (Anthropic, Fireworks, Google
  AI Studio, Google Vertex and Mistral); the deletion answer says which
  (`upstream_status`: `deleted`, `unsupported` or `not_applicable`), and the
  app records it.
- A halt of the synchronous path (an answer from a provider outside the
  zero-retention list) stops batches too, until the service restarts.

**What the owner must arrange in the OpenRouter account** (this code cannot
and never does change account settings):

1. **Privacy settings.** An account whose privacy settings require zero data
   retention for the batch provider refuses every batch. Verified on
   2026-11-18: the submission answered HTTP 422 "Batch and other async APIs
   retain submitted data regardless of the provider's advertised retention
   policy, so this endpoint cannot be used with your Zero Data Retention
   settings" (the service reports it as 424 `openrouter_batch_zdr_required`).
   Relaxing it for the batch provider also stops the account from enforcing
   zero retention for anything else sent to that provider; the synchronous
   path's own enforcement (the request's `zdr` flag and the endpoint list)
   does not depend on the account setting.
2. **Inline images.** By default a batch takes only public image URLs. Inline
   base64 images are "allowlist-only": the account must be on OpenRouter's
   allowlist, and the provider must be one that reads them (Anthropic up to
   5 MiB per image, OpenAI 20 MiB, DeepInfra, Mistral, xAI, Google Vertex,
   Alibaba, Sail Research). **Receipt photos are never put on a public URL**,
   by any code path: when inline images are refused, the batch fails with
   `openrouter_batch_inline_images_refused` and the receipts are read one at a
   time instead. Inline images in a batch are unverified until the account is
   on the allowlist.

### Settings

- `OPENROUTER_BATCH_ALLOW_RETENTION` (`false`): the opt-in above. Only `true` or
  `false` (any case); anything else (`1`, `yes`, `on`) stops the service at start.
- `OPENROUTER_BATCH_MODEL` (no default): the model, as its plain slug; it must
  have a `:batch` variant that takes images on openrouter.ai/models
  (`?variant=batch`), or batches are refused (`openrouter_batch_model_unsupported`).
- `OPENROUTER_BATCH_PROVIDERS` (no default): the endpoint slugs a batch may run
  on, separated by commas (for example `anthropic`). Each must be a provider
  known to read inline images in a batch (the list above), and at least one of
  them must serve the model's batch variant.
- `OPENROUTER_API_KEY`, and the request settings shared with the synchronous
  path: `OPENROUTER_MAX_TOKENS`, `OPENROUTER_OCR_IMAGE_MAX_SIDE`,
  `OPENROUTER_STRUCTURED_OUTPUT`.

### What is sent

One provider batch per create request: `{"endpoint": "/v1/chat/completions",
"model": ..., "provider": {"only": [OPENROUTER_BATCH_PROVIDERS that serve it],
"allow_fallbacks": false}, "completion_window": "24h", "requests": [...]}`,
with `requests` last (OpenRouter reads the body as a stream). Each request is
`{"custom_id": <the caller's key>, "body": <the synchronous request body>}`:
the same prompt, photos (decoded, turned upright, scaled, re-encoded as new
JPEGs from their pixels, as inline data URLs), temperature, max tokens and
answer schema as `/ocr` sends (`receipt_request_body`), without the
synchronous `provider` preferences, which a batch ignores inside a request
body. No file name, no app id, no ledger data, no `user`, `metadata` or
attribution header; the HTTP client is the synchronous path's (no proxy
settings, no `.netrc`, no redirects, no cookies).

**Keys.** The caller gives every receipt an opaque key of 16 to 64 URL-safe
characters; the Rails app uses 24 random characters per receipt
(`OcrBatchEntry.new_custom_id`) and keeps the mapping to the receipt in its own
database. The service keeps no state between calls: the key travels as the
`custom_id` and comes back with the result, and everything else is re-read
from OpenRouter.

### The answers

Each result is read exactly as `/ocr` reads an answer (`parse_answer`, then
`postprocess`), so the same answer gives the same receipt. The repair pass
cannot run inside a batch: an answer that does not parse is reported as
`ocr_parse_failed` with `retry_sync: true`, so a read one at a time (which
has the repair pass) can try. The provider that ran the batch, and the one each
answer names, must be one of the allowed providers; any other answer is not
used (`openrouter_batch_provider_unverified`).

### Limits

- At most 100 receipts per batch (422 `batch_too_many_receipts`), 1 to 3
  photos each, each photo checked as for `/ocr`; at most 300 MB of photos per
  create request (413 `batch_upload_too_large`).
- The provider batch body at most 190 MB (413 `batch_too_large`, checked
  before anything is sent); OpenRouter's own 200 MB limit and its cap on
  requests per batch (reported only in its 413) also map to 413
  `batch_too_large`. The Rails app splits such a batch in two and sends both.
- Each re-encoded photo must fit the strictest allowed provider's inline limit
  (422 `batch_image_too_large`; lower `OPENROUTER_OCR_IMAGE_MAX_SIDE`).

### Cost

`POST /ocr/batches/estimate` (and the `estimated_cost_usd` of a submission)
estimates the cost before anything is sent, from the model's batch price (the
highest among the allowed endpoints) and predicted tokens: the fixed prompt at
3 characters per token, 1,600 tokens per photo, and 1,200 answer tokens per
receipt (`cost_usd`) or `OPENROUTER_MAX_TOKENS` (`cost_usd_max`). It is rough:
within a factor of two either way, since the image tokens depend on the
provider and each photo's size. The batch's status then carries OpenRouter's
`usage.cost` (what was charged so far, the total once completed) and each
result its own cost where reported, all as exact decimal strings.

### Endpoints

| Method and path | What it does |
| --- | --- |
| `GET /ocr/batches/capability` | `available` and, if not, `code` and `message`; the model, its dated slug, the allowed providers, `max_receipts`, `max_upload_bytes`, `retention_days` (30) and the batch prices. Reads only OpenRouter's public model lists, without the key. Always 200. |
| `POST /ocr/batches/estimate` | JSON `{"receipts": N, "images": M}` (M between N and 3N): the estimate above. |
| `POST /ocr/batches` | multipart: `manifest` (JSON `[{"key": ..., "images": 1..3}]`, one per receipt) and the `images` parts, receipt by receipt. Builds and submits one batch; 202 with its status. |
| `GET /ocr/batches/{id}` | the status: `state` (the service's own: `running`, `completed`, `failed`, `expired`, `cancelled`; `completed` only once results are attached), `provider_status` (OpenRouter's), `provider`, `model_name`, `requests` (`total`, `completed`, `failed`; an estimate while running), `cost_usd`, `created_at`, `expires_at`, `finished_at`, `error` (the service's own words for a failed, expired or cancelled batch). |
| `GET /ocr/batches/{id}/results` | 409 `batch_not_finished` until completed; then `batch` (the status), `results` (per key: `status` `ok` with `ocr`, the `/ocr` answer's shape plus `mode: "batch"`, `batch_id`, `provider`, `cost_usd`, `prompt_tokens`, `completion_tokens`, `finish_reason` (`repaired` false, `elapsed_seconds` null); or `status` `error` with `error: {code, message, retry_sync}`) and `counts` (`ok`, `parse_failed`, `failed`, `ignored`: results whose key is not a valid key or repeats one). |
| `DELETE /ocr/batches/{id}` | deletes a finished batch at OpenRouter: `{"id", "deleted": true, "openrouter", "upstream_provider", "upstream_status"}`. 409 `batch_running` while it runs (there is no cancel). |

A batch id is checked (1 to 128 letters, digits, `-`, `_`) before it goes into
a URL. An unknown batch, or one older than 30 days, is 404 `batch_not_found`.

Submitting has one ambiguous case: the photos were sent and the answer was
lost (a timeout after sending, a cut connection, an OpenRouter 5xx after the
upload, a 2xx whose batch id cannot be read). OpenRouter may have stored the
batch, and sending it again could pay for it twice, so the service answers 504
`openrouter_batch_submit_unknown`; the Rails app then releases the receipts
and tells the owner to look for the batch in OpenRouter's logs. A connection
that never opened is 502 `openrouter_unreachable` (nothing was sent; safe to
retry), a rate limit 503 `openrouter_rate_limited`. The app retries only
those two and 503 `openrouter_catalogue_unavailable`; any other server error
of a create request counts as unknown.

Status and results of a batch sent earlier are read even if its model or
provider has since left OpenRouter's catalogue; its answers are then checked
against `OPENROUTER_BATCH_PROVIDERS` itself. Switching batch mode off makes
every batch endpoint refuse, following and deleting included: the app can then
release a stuck batch's receipts, and deletes it once batch mode is on again.

## Item categorisation

`app/categorise/`. The reasons are in `docs/decisions/0015-item-categoriser.md`.
It is zero-shot: no training on the owner's labels; the model gets the
category list with descriptions and answers with a slug from it.

### The categoriser interface

`app/categorise/base.py`, deliberately narrow, so another kind of categoriser
(a trained one, a decision model, a combination of several) fits in as one more
`CATEGORISE_BACKEND` value:

    Categoriser.categorise(CategoriseInput(categories, texts, merchant)) -> Categorisation

- in: the items of one receipt (`texts`), the taxonomy to choose from
  (`categories`: `CategoryOption`s with `slug`, `name`, `description`,
  `group`) and the context (`merchant`, which a hosted categoriser must not
  send);
- out: per item 1 to 3 `Candidate`s (slug, score), best first, scores adding up
  to at most 1; the `score_kind`; the `prompt_version`; and `diagnostics`, the
  accounting (`model_calls`, tokens, `seconds`, and for a paid call `cost_usd`
  as a decimal string);
- errors: `BackendError` (a 5xx other than 501 is retried by the app) or
  `BackendNotImplementedError` (501).

The service checks every answer against the request's slugs and applies the
calibration itself; `start()` and `stop()` load and release a model.

**The category hand-over** is one shape in two places: the `categories` of a
request, and the file `bin/rails "categories:export_items[FILE]"` writes
(`{"categories": [...]}`). `app/categorise/taxonomy.py` reads both
(`parse_categories(rows)`, `read_categories_file(path)`) with the same checks,
so an offline script gets exactly the list the app sends:

```python
from pathlib import Path
from app.categorise.taxonomy import read_categories_file

categories = read_categories_file(Path("item_categories.json"))  # tuple of CategoryOption
```

### The prompt

`app/categorise/prompt.py`, shared by every categoriser and versioned like the
OCR prompt (`PROMPT_VERSION`, a hash of every fixed text and example, in every
response and run). The system message holds the task, the categories grouped
by group (`slug: Name. Description.`), how receipt items are printed (abbreviated,
run together, a size stuck to the name, brands in Latin letters), a few rules
(shop food is groceries, drinks made on the spot are eating out, toiletries are
household supplies), a few invented example items with their slugs, and the
answer format: one JSON object, item numbers as keys, one slug as each value,
`{"1": "groceries/groceries", "2": "health/health-pharmacy"}`. It holds no
receipt data, so a local model keeps it computed between receipts.

The user message lists the receipt's items, numbered, in printed order: the
items of one receipt are categorised together, since the neighbours help (on a
pharmacy's receipt an unclear item is a medicine). For a local model the shop's
name comes first, as context (`local_messages`). For a hosted model there is a
separate function that takes the category list and the item texts and nothing
else (`hosted_messages`): the shop, amounts, dates and ids cannot reach it.

### How confidence is computed

- **Local (`mlx`, `score_kind: label_probability`).** The answer may only be one
  of the listed slugs, and instead of letting the model pick token by token
  (greedy constrained decoding gives the probability of the path it took and
  nothing about the others), every slug is scored
  (`app/categorise/labels.py`). Each slug is tokenised, followed by the closing
  quote, and the token sequences form a trie. At every node where slugs part
  ways, the model's logits for the allowed next tokens are renormalised among
  those tokens only; where one slug remains, the constrained probability is 1.
  A slug's probability is the product along its path, and the probabilities of
  all slugs add up to 1: the model's own distribution over the listed
  categories, as constrained decoding sees it. Only the parting points cost a
  model call: the tokens up to one are fed in one call, scored, and taken back
  out of the KV cache. The best slug is then written into the answer and the
  next item is scored with all earlier answers in context, as in a normal
  generation. The three best go into the response. mlx-vlm's JSON-schema logits
  processor (used for OCR) was not used here: it masks logits but exposes only
  the chosen token's log-probability, which says nothing about the runner-up.
  Limits: the slug's tokens are the tokeniser's own spelling of it (another
  spelling of the same slug is not counted, which can only lower a score), and
  a model can be sure and wrong, so a probability is not a precision until it
  is calibrated.
- **Hosted (`openrouter`, `score_kind: token_logprobs`).** A hosted endpoint does
  not give logits at chosen points, so the slugs cannot all be scored. Where the
  endpoints return token log-probabilities (`logprobs` with `top_logprobs`; the
  endpoint list says which do, by `supported_parameters`), the chosen slug's
  score is the product of the probabilities of the tokens that spell it, and
  an alternative token that, after the text before it, can lead to only one
  other listed slug gives that slug the probability of the path to it
  (`app/categorise/logprobs.py`). An alternative that leads to several slugs is
  not attributed, so the scores add up to at most 1. Whether an endpoint
  reports probabilities before or after the structured output masked tokens is
  not documented: these are the model's token probabilities of its answer, not
  a distribution over the categories.
- **Hosted without log-probabilities (`score_kind: fixed`).** The chosen slug
  gets 0.5 (`FALLBACK_SCORE`), the only candidate. It is a marker, not a
  confidence, and it is below any sensible acceptance threshold; a calibration
  fitted on such answers turns it into the model's measured precision.
- **Decision model (`decisions`, `score_kind: decision_probability`).** The
  model answers each item's question with a probability for every listed
  category (or, with `two-stage`, for every group and then every category of
  the most likely groups; a category's score is the product). Those are the
  scores, normalised to add up to 1 per question. The provider claims they are
  calibrated in aggregate but publishes no figures, and they vary by a few
  hundredths between identical calls; calibrate them like any other score.
- **Stub (`score_kind: stub`).** Shares of a hash; they mean nothing.

### Calibration

A raw probability is not a precision. A calibration is a monotone mapping
fitted on labelled items: isotonic regression of "the best candidate was right"
on its raw score (`python -m evaluation.item_categories_calibrate`, below). It
is a JSON file outside the repository with the breakpoints and what it was
fitted for (categoriser, model, prompt version, score kind, number of items).
`CATEGORISE_CALIBRATION_FILE` loads it at start-up; a file fitted for another
categoriser or model stops the service, and an answer of another prompt version
or score kind (a hosted answer without log-probabilities, say) keeps its raw
scores. The best candidate's score is mapped; the others are mapped too and
scaled down if they no longer fit under 1. `calibrated: true` means exactly
this; without a file the service still answers, with `calibrated: false`.

### One model or two

The local categoriser can use the vision model already loaded for OCR (one copy
in memory, about 7 GB) or a smaller text model loaded beside it. Measured on
the invented sanity set (43 items in 11 receipts, `tests/fixtures/item_sanity_set.json`)
on an M2 Max, with the 37 candidate categories:

| Model | Right (top 1) | Seconds per item, prompt cached | Peak memory | Best ≥ 0.9 but wrong |
| --- | --- | --- | --- | --- |
| `mlx-community/Qwen3-VL-8B-Instruct-4bit` (the OCR model) | 39 of 43 | 0.6 to 0.7 | 6.7 GB (shared with OCR) | 3 |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 34 of 43 | 0.35 | +3.2 GB beside the OCR model | 9 |
| Qwen3-VL-8B without the shop's name | 32 of 43 | as above | as above | n/a |

So the default is the OCR model: it is right more often, it is wrong with
high confidence less often, and it costs no memory. A receipt of 20 items takes
about 15 seconds after the first (which also computes the 1,600-token
instructions once, about 5 seconds). The shop's name matters (39 against 32),
which the hosted categoriser does not get. `MLX_CATEGORISE_MODEL` names another
model when wanted.

### The hosted categoriser

`app/categorise/openrouter.py`, for comparison with the local one. It calls
through the same `OpenRouterClient` as the hosted OCR backend, so every rule of
"Zero data retention" above applies: the catalogue of strict zero-retention
endpoints (text-only models allowed), the fixed `zdr` and `data_collection`
preferences, the provider check of every answer, and the halt after a wrong
one, which stops OCR and categorisation alike until the service restarts.

- **Routing**: the endpoints that support both structured output and
  log-probabilities when there are any; else structured output; else
  log-probabilities; else any strict zero-retention endpoint.
- **What is sent**: `model`, `messages` (the fixed instructions with the
  category list, and the numbered item names), `temperature` 0, `max_tokens`
  (64 plus 32 per item, at most `OPENROUTER_MAX_TOKENS`), `stream`,
  `provider`, and where supported `response_format` (a JSON schema: keys "1" to
  "n", each an enum of the slugs) and `logprobs` with `top_logprobs` 5. Never
  the shop's name, an amount, a date, an id or anything of the ledger.
- **Answer**: a JSON object naming one listed slug per item, else 422
  `categorise_parse_failed` (no repair pass: the schema already constrains it).
  Cost, latency and provider per call are accounted as for OCR.

### The decision-model categoriser

`app/categorise/decisions.py` (`CATEGORISE_BACKEND=decisions`), over the client
`app/decisions.py`. A decision model does not write text: it takes a `state`
and typed questions, and answers a `choice` question with a probability for
every option, a `noul` (yes/no) question with the probability of yes. A closed
list of categories is exactly that question, so the answer can never name a
category outside the list and needs no parsing, and its probabilities are a
confidence for every category without token log-probabilities. Reasons and the
trial: `docs/decisions/0016-decision-model-categoriser.md`.

- **Zero retention**: the client calls through `OpenRouterClient`
  (`decisions=True`), so every rule of "Zero data retention" holds, in the same
  code: the model must be listed as a decision model (OpenRouter lists those
  only in `/api/v1/models?output_modalities=all`) and have strict
  zero-retention endpoints (no Safety Retention), which every request names in
  `provider.only` with `zdr: true` and `data_collection: "deny"`; nothing is
  sent when the lists cannot be read; the provider of every answer is checked,
  and an answer from elsewhere halts every hosted call (OCR included) until the
  service restarts. On 2026-11-18 `typesafe/jev-1.14` had one such endpoint
  (`typesafe`, provider TypeSafe, `safety_retention: false`).
- **What is sent**: the body is `model`, `state`, `questions` and `provider`,
  nothing else (no `user`, `session_id`, `trace`, no attribution header).
  `state` holds item names only: `line_1`, `line_2`, ... for the items of the
  receipt (the neighbours show what kind of shop it was, which the hosted
  model is never told), or `item` alone with `DECISIONS_RECEIPT_CONTEXT=false`;
  and, in offline runs with `--examples`, `examples`: similar item names a
  person labelled in earlier receipts, each with its category's label. The
  questions hold fixed instructions and the category names and descriptions.
  The shop's name, amounts, quantities, dates and ids are not read by the code
  that builds a request. Never use this client for transactions, payees or
  bank descriptions: those stay on this machine.
- **Strategies**: `flat` asks one `choice` per item over every category, each
  option labelled "Group / Name" and described by its description. `two-stage`
  asks for the group first (each group described by its categories), then the
  category within the two most likely groups of more than one category (the
  second only above 0.05); a category alone in its group needs no second
  question. `verify` (offline only, below) asks "does this item belong to this
  category?" for each candidate another categoriser proposed.
- **Batching**: every item is its own question, and a question carries its
  whole option text (about 3,000 bytes for the 37 categories), because the
  question key is never shown to the model. A receipt's questions go in as few
  requests as fit `DECISIONS_MAX_QUESTIONS` and 24,000 bytes, well below the
  ~32,000 bytes past which the model switches to a slower and less accurate
  long-input mode: about 4 to 7 items per request with `flat`.
- **Answers**: every answer is checked against its question: a missing or
  unasked answer, an option not offered, a missing or extra probability, a
  value outside 0..1 and probabilities that do not add up to 1 (within 0.02)
  are errors (502 `decisions_bad_answer` / `decisions_answer_missing`); never
  dropped or guessed. They are 5xx, so the app retries them: an answer varies
  between calls, and a retry costs about $0.0001. A refusal fails the receipt
  (422 `decisions_refused`; with `two-stage`, a refused second question for the
  most likely group overall does too, while one for a less likely group only
  drops that group): the service promises a candidate for every item. A question too long
  for the normal input mode on its own is refused before sending (422
  `decisions_request_too_large`). Each item is asked once: answers vary
  slightly between calls, and a run keeps the first.
- **Prompt versions**: the prompt version names the strategy, the context and
  whether examples were shown, and `verify` has its own; a calibration
  (matched on the prompt version) fitted on one mode never applies to another.
  `/categorise` answers never carry examples.

On the invented sanity set (98 items in 21 receipts, the first 43 as above;
`typesafe/jev-1.14`, 37 categories, 2026-11-18; no shop name, as for every
hosted path):

| Variant | Right (top 1) | Of the first 43 | Top 3 | Best ≥ 0.9 but wrong | Requests | Input tokens per item | Seconds per item | Dollars per 1,000 items |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `flat`, receipt context, batched | 96 of 98 | 43 | 98 | 0 | 25 | 1,126 | 0.09 | 0.047 |
| `flat`, one item per request | 95 of 98 | 43 | 98 | 0 | 98 | 1,442 | 0.28 | 0.061 |
| `flat`, each item alone (no context) | 88 of 98 | 40 | 91 | 1 | 98 | 1,277 | 0.29 | 0.054 |
| `two-stage`, receipt context | 92 of 98 | 42 | 98 | 0 | 46 | 1,174 | 0.12 | 0.049 |

The reliability of `flat` (top score band: items, accuracy): below 0.5: 1,
1.0; 0.5 to 0.7: 8, 0.75; 0.7 to 0.9: 5, 1.0; 0.9 to 0.95: 6, 1.0; 0.95 and
above: 78, 1.0. Verifying `flat`'s three candidates (one `noul` each) and
ranking by the yes-probability got 90 of 98, worse than the `choice` itself,
for about a third more tokens (294 short questions); as a confidence it was no
better calibrated either. Two runs of the same `flat` request differed only in
the second decimal place of a few scores. So `flat` with the receipt's lines is
the default. The
set is invented and small, the items obvious on purpose: these numbers show the
model works, not how well it will do on real receipts; the evaluation on the
labelled items decides.

## Evaluating the item categoriser

```sh
# The categories the app sends (no personal data).
bin/rails "categories:export_items[$HOME/Documents/money_bin_data/exports/item_categories.json]"
# The labelled items.
bin/rails "receipts:export_ground_truth[$HOME/Documents/money_bin_data/exports]"

cd ml
# A smoke test on the invented sanity set: counts and timings only.
uv run python -m evaluation.item_sanity --categories ~/Documents/money_bin_data/exports/item_categories.json \
  --backend mlx --with-ocr-model

# A run over the labelled items, the label memory first.
uv run python -m evaluation.item_categories_run \
  --ground-truth ~/Documents/money_bin_data/exports/ground_truth.jsonl \
  --ingest ~/Documents/money_bin_data/receipts \
  --categories ~/Documents/money_bin_data/exports/item_categories.json \
  --out ~/Documents/money_bin_data/runs --backend mlx --memory

# A calibration from a run without one.
uv run python -m evaluation.item_categories_calibrate --run ~/Documents/money_bin_data/runs/<run id> \
  --ground-truth ~/Documents/money_bin_data/exports/ground_truth.jsonl
```

`item_categories_run` reads the ground-truth export (one record per receipt: one
with `categories_known` first, then a person's before an imported one; labels
only from a record with `categories_known`) and keeps the receipts of the
receipt set that have a labelled item (`--all-receipts` for all, `--ids`,
`--limit`). Receipts go in time order. Each receipt's items are categorised
together in one call, with the shop's name for a local model. With `--memory`
the label memory answers first, with the app's rule
(`evaluation/label_memory.py`), from the labels of EARLIER receipts only, so no
item is suggested its own label; the memory is the categoriser `label-memory`
for the pre-fill rule. `--calibration FILE` applies a calibration; `--backend`
and `--model` choose the categoriser.

The run folder (outside any git repository, files readable by the owner only;
the console prints counts) gets `predictions.jsonl`, one line per item:
`receipt_id` (the ingest id), `position` (the item's place in the ground-truth
document, from 1), `candidates` (up to three `{"category_slug", "score"}`, best
first), `source` (`memory` or `model`), `seconds` and `cost_usd` (decimal
strings: a call's time and cost split evenly over its items, the cost rounded
to 10⁻¹²; memory costs `"0"`; null when not reported) and `error` (a code when
the call failed, else null). `run.json` has `"task": "item_categories"`, the
backend, model and weights revision, prompt and categories versions, the git
commit, `calibrated`, the score kinds, the memory rule, counts (receipts, items,
labelled items, memory and model items, failures, labels outside the category
list), seconds per call and per model item, and for a hosted backend the cost
(total, per receipt, per 1,000 items). Scoring is the evaluation harness's job.

**Decision models.** `--backend decisions` (with `--model typesafe/jev-1.14`
or `DECISIONS_MODEL`) adds `--strategy flat|two-stage`, `--no-receipt-context`,
`--max-questions N`, `--examples K` (up to K, at most 5, similar items labelled in EARLIER
receipts, from the label memory's store: `LabelMemory.similar`, character
trigram similarity of the name keys) and `--verify RUN_DIR` (instead of
categorising, ask one yes/no question per candidate of that run's items; the
yes-probability becomes the score, so a local model's answer gets a confidence
from an independent model). `run.json` then has a `decisions` block (strategy,
context, examples, the verified run and how many of its items had no
candidates, the zero-retention endpoints used), `combined_from` when another
categoriser shaped the answers (the label memory that supplied the examples;
every categoriser of the verified run), which the harness's pre-fill rule reads,
and the answers'
`prompt_versions` (`prompt_version` is null when they differ, as in a run with
examples, whose first receipt has none to show; such a run is not calibrated). The
key comes from the environment: `uv run --env-file ../.env ...`.
`item_sanity` takes the same options, plus `--verify` to check its own
candidates, and reports the top-score distribution, the reliability table, the
share auto-accepted at 95% precision, and requests, tokens and dollars.

**Combining runs.** `python -m evaluation.item_categories_combine` takes two or
more run folders over the same items and the ground-truth export, and writes a
combined run folder in the same format (`source: combined`):

- `--method cascade --thresholds T1,...` (one per run but the last): the first
  run whose best score reaches its threshold decides each item;
- `--method average [--weights W1,...]`: a weighted average of the runs'
  per-category scores;
- `--method learned [--folds 5] [--c 1.0]`: a multinomial logistic regression
  on the runs' per-category scores side by side (plus a "no candidates" column
  per run), cross-validated by receipt and forward in time: the receipts with
  usable labels, in time order, are cut into `folds + 1` consecutive blocks,
  and each block after the first is scored by a fit on the blocks before it
  only. No item is scored by a model fitted on its own receipt, nor on a later
  one: with the label memory or examples, a later receipt's scores already
  contain earlier labels, so random folds would let a held-out label back in.
  The first block gets the plain average (`warm_up_items`); unscored items a fit
  on every usable label. Because of the warm-up block the run never claims
  `calibrated` scores, although the fitted probabilities are fitted to labels.

Items whose labels were chosen with one of the combined categorisers on screen
(`categories_prefilled_by` names a categoriser behind one of the runs: its
model, the label memory when it answered first, and every `combined_from`
entry, which names the memory that supplied examples and the categorisers of a
verified run; or is `source:unknown`; names compared by the harness's rule,
`evaluation/models.py`, so another spelling of the same model counts) are
neither fitted on nor counted (`item_categories_calibrate` applies the same
rule). The forward split follows the order in which the runner processed the
receipts (the order of their lines), and runs that disagree on it are refused. The combined run's
`run.json` has `combined_from` with every categoriser behind every input, so
the harness applies the same rule,
and reports `agreement` (how often all runs agree on the best category and how
precise that is, the combined accuracy where they disagree, each pair's
agreement) and the combined run's scores on the usable items.

The commands once items are labelled (the exports as above):

```sh
cd ml
GT=~/Documents/money_bin_data/exports/ground_truth.jsonl
CATS=~/Documents/money_bin_data/exports/item_categories.json
RUNS=~/Documents/money_bin_data/runs
SET=~/Documents/money_bin_data/receipts
# 1. The local model with the label memory first (no key needed).
uv run python -m evaluation.item_categories_run --ground-truth $GT --ingest $SET \
  --categories $CATS --out $RUNS --backend mlx --memory
# 2. The decision model alone, and with the memory first and labelled examples.
uv run --env-file ../.env python -m evaluation.item_categories_run --ground-truth $GT \
  --ingest $SET --categories $CATS --out $RUNS --backend decisions --model typesafe/jev-1.14
uv run --env-file ../.env python -m evaluation.item_categories_run --ground-truth $GT \
  --ingest $SET --categories $CATS --out $RUNS --backend decisions --model typesafe/jev-1.14 \
  --memory --examples 3
# 3. The decision model as the local model's confidence: verify run 1's candidates.
uv run --env-file ../.env python -m evaluation.item_categories_run --ground-truth $GT \
  --ingest $SET --categories $CATS --out $RUNS --backend decisions --model typesafe/jev-1.14 \
  --verify $RUNS/<run 1>
# 4. Combinations (same items in every run).
uv run python -m evaluation.item_categories_combine --ground-truth $GT --out $RUNS \
  --run $RUNS/<run 1> --run $RUNS/<run 2, flat> --method learned
uv run python -m evaluation.item_categories_combine --ground-truth $GT --out $RUNS \
  --run $RUNS/<run 1> --run $RUNS/<run 3, verify> --method learned
uv run python -m evaluation.item_categories_combine --ground-truth $GT --out $RUNS \
  --run $RUNS/<run 1> --run $RUNS/<run 2, flat> --method cascade --thresholds 0.95
```

Each run and combination is then scored by the evaluation harness (`make eval`,
"The evaluation harness" below) with the same table: macro-F1, top-3, the share auto-accepted at 95% precision, calibration,
seconds and dollars per 1,000 items.

`item_categories_calibrate` fits on the model items of a run that have a label
(at least 30, `--min-items`; `--ids` for a calibration slice), writes the file
to `--out` (default `~/Documents/money_bin_data/models/`, refused inside git,
mode 600) and prints the accuracy and the share of these items at a calibrated
0.95 or more, which is optimistic on the items it was fitted on: fit on one
part of the labelled receipts, evaluate on another.

## Evaluating OCR on the receipt set

`evaluation/` runs a backend over the receipt set made by
`tools/receipt_ingest` and scores it against the receipts' QR codes. Receipt
photos and model answers are personal data: the run folder must be outside
any git repository (`ocr_run` refuses one inside), its files are readable by
the owner only, and both scripts print aggregates only.

```sh
# Run a backend in-process over receipts (same code and settings as the service).
uv run python -m evaluation.ocr_run \
  --ingest ~/Documents/money_bin_data/receipts \
  --out ~/Documents/money_bin_data/runs \
  --backend mlx --model mlx-community/Qwen3-VL-8B-Instruct-4bit \
  --only-tax-qr --limit 20

# Score the run against the QR codes.
uv run python -m evaluation.ocr_fields --run ~/Documents/money_bin_data/runs/<run id>
```

`ocr_run` options: `--only-tax-qr` (only receipts whose QR code is a tax-service
link, which have ground truth), `--limit N`, `--ids FILE` (receipt ids, one per
line), `--crops` (send the ingest tool's cropped photos where they exist),
`--model ID`, `--image-max-side N`, `--max-tokens N` (they set the
`MLX_OCR_*` settings, or the `OPENROUTER_*` ones with `--backend openrouter`). It writes
`<out>/<run id>/predictions.jsonl` (one line per receipt: status `ok`,
`parse_failed`, `error` or `skipped` for more than 3 photos; seconds; whether it
was repaired; the receipt; token counts, peak memory and post-processing
counts) and `run.json` (backend, model, weights revision, prompt version, git
commit, settings, counts, seconds per receipt).

A hosted run reads `OPENROUTER_API_KEY` and `OPENROUTER_OCR_MODEL` from the
environment and sends the photos to the hosted model (only to zero-retention
endpoints, as above); it stops before the first receipt when a setting is
missing or the endpoint list cannot be read:

```sh
uv run --env-file ../.env python -m evaluation.ocr_run \
  --ingest ~/Documents/money_bin_data/receipts \
  --out ~/Documents/money_bin_data/runs \
  --backend openrouter --model vendor/model-id --only-tax-qr --limit 20
```

Each predictions line then also has, in `diagnostics`: `cost_usd` (the sum of
the calls' costs as a decimal string; null when a call reported none),
`latency_seconds`, `providers`, `structured_output` and `calls` (per call:
seconds, prompt and completion tokens, cost, provider, served model, finish
reason, structured output). A receipt that failed after a call keeps its
accounting: it was paid for. `run.json` adds `cost_usd` (`total_usd`,
`per_receipt_usd`, `per_1000_receipts_usd`, `receipts_with_cost`,
`receipts_without_cost`, `complete`), `upstream_providers` (calls per
provider), `stopped` (why a run ended early, such as
`openrouter_provider_unverified`, or null) with `counts.attempted`, and in
`settings` the endpoints the requests were limited to. The
averages are over the receipts that made a call and reported a cost, rounded
for the report (a millionth of a dollar per receipt, a ten-thousandth per
1,000); the totals are exact.

`ocr_fields` scores the receipts that have QR fields: date, time (to the
minute, Kyiv time), total, fiscal number and receipt number as shares of exact
matches; the share of receipts whose items add up exactly to the QR total
(there is no item ground truth yet, so this stands in for item quality); the
share read as `fiscal`; parse failures; seconds per receipt (mean, median, 90th
percentile); and for a hosted run the cost per receipt and per 1,000 receipts
(`cost_usd`, as in `run.json`; null for a local backend). A failed receipt counts as wrong for every field. The scores are
also written to `scores.json` in the run folder.

## The evaluation harness

`evaluation/harness.py` turns every run into the numbers of the results chapter, offline, from
files. From the repository root:

```sh
make eval-check   # validate the inputs, print what would be scored; writes nothing
make eval         # write eval/results/
make eval RUNS_DIR=~/elsewhere EVAL_ARGS="--compare RUN_A RUN_B --diagnostics ~/private/diag"
```

`make` runs `uv run python -m evaluation.harness` in `ml/` with `--receipts`, `--runs`,
`--ground-truth` and `--out` from the variables `RECEIPTS_DIR` (default
`~/Documents/money_bin_data/receipts`), `RUNS_DIR` (`.../runs`), `GROUND_TRUTH_DIR`
(`.../ground_truth`, where `receipts:export_ground_truth` is told to write) and `RESULTS_DIR`
(`eval/results`); `EVAL_ARGS` adds options: `--compare A B` (repeatable), `--comparisons FILE`
(lines `RUN_A RUN_B`; default `comparisons.txt` in the runs folder when it exists),
`--no-auto-compare`, `--seed` (42), `--resamples` (1000), `--check`, `--diagnostics DIR`. A
relative folder in one of the `*_DIR` variables is taken from the repository root (a relative path
inside `EVAL_ARGS` is taken from `ml/`); `~` is expanded. The results folder must be new, empty or
one the harness wrote (only `README.md`, `index.json`, `runs/`, `comparisons/`, `tables/`): stale
files there are removed, so any other folder is refused.
`--check` scores everything and runs every check of the writer, then writes nothing; without it,
nothing is written either until every file has passed (a refused value leaves the folder as it was).

### Inputs

- **The receipt set**: `receipts.jsonl` of `tools/receipt_ingest` (ids, the number of photos, the
  QR fields).
- **Runs**: every folder under the runs folder, at any depth, with a `run.json` and a
  `predictions.jsonl`. `run.json`'s `task` is `ocr` (also when it is missing: runs written before
  it existed) or `item_categories`. Run ids must be unique.
- **Ground truth** (optional): `ground_truth.jsonl` from `bin/rails "receipts:export_ground_truth[DIR]"`
  (`app/services/ground_truth_export.rb`, `docs/domain.md` "Receipt ground truth"): every line as
  schema version 2, with `prefilled_by`, `prefilled_model_version`, `categories_prefilled_by`,
  `items_known`, `categories_known`, `qr_check`, `check_outcome` and a `document` whose items and
  receipt carry `category_slug`. Unknown keys are ignored. A line without `categories_known` (an
  older export) has categories when its document carries any slug. A line without an `ingest_id` is
  counted and skipped.

**Adding a run** is writing a run folder (`evaluation.ocr_run`, or the item categoriser) and
running `make eval` again. Nothing else changes.

### The item-category run format

`run.json`: `"task": "item_categories"`, `run_id`, `backend`, `model_name`, `model_version`,
`prompt_version` (or null), `git` (`sha`, `dirty`), `started_at`, `finished_at`, `counts` (whole
numbers by name), `seconds_per_item`, `cost_usd`, `scores_calibrated` (true when the scores were
calibrated, for example on a validation set; false when they are raw; absent or null when not
known), `sources` (any `source` values its lines use besides `memory`, `model`, `decision` and
`combined`) and, for a run made by combining other runs, `combined_from`: a list of
`{"run_id", "backend", "model_name", "model_version"}`, one per run it combines (any key may be
missing). `item_categories_combine` lists every categoriser behind every input there, and a
decision-model run lists the label memory that supplied its examples and the categoriser behind
a verified run; the pre-fill rule then applies to all of them, and such a run counts as combined. `predictions.jsonl`, one line per
item:

```json
{"receipt_id": "rcpt_000123", "ground_truth_source": "manual", "position": 2,
 "candidates": [{"category_slug": "groceries/groceries", "score": 0.82},
                {"category_slug": "household-shopping/household-supplies", "score": 0.11}],
 "source": "model", "seconds": 0.004, "cost_usd": null}
```

- `receipt_id`: the ingest id; `position`: the item's 1-based place in the `items` of the
  ground-truth record named by `ground_truth_source` (`dps_xml` or `manual`; optional: without it,
  the record the harness chooses; categories are only ever on `manual` records). A card slip has
  one line with `position: null`, for the receipt's own category.
- `candidates`: at most 3, best first; `score` a number from 0 to 1 (the first one's is the
  confidence) or null; a score outside that range stops the harness (percentages or logits would
  make calibration meaningless).
- `source`: an open set of short lower-case words: `memory` (an earlier booking of the same text),
  `model`, `decision` (a hosted decision model), `combined`, and any word `run.json` declares in
  `sources`. The metrics are split by the values that occur; an undeclared word is counted as
  `other` (so a word written by mistake never reaches the results), and an item without a
  prediction or without a source as `unstated`.
- `seconds`: a number or a decimal string; `cost_usd`: a decimal string, or null for a local
  model. Other keys (such as `error`) are ignored.

`evaluation/item_categories_run.py` writes this format; the harness reads it as written: without
`ground_truth_source` (positions then refer to the record the harness chooses, the person's record
with categories, as the runner's), with `calibrated` instead of `scores_calibrated`, and with
`memory` in `run.json`: when `memory.enabled` is true, the run also counts as the categoriser named
in `memory.categoriser_name` (`label-memory`) for the pre-fill rule, so a receipt whose categories
the label memory suggested is left out of it.

### Which ground truth counts

`evaluation/truth.py`:

- **Left out for every run**: a `dps_xml` record whose `qr_check` is `disagrees` (another receipt's
  file); any record checked against the print as `differs`. A `manual` record whose `qr_check`
  disagrees is kept (a person read this receipt).
- **Unchecked records count.** The item metrics are also given over records checked as `matches`
  only (`items_checked_only`).
- **Precedence**: `dps_xml` first, then `manual`; each purpose (items, merchant, kind, total,
  categories) takes the first record that has it (`items_known`, a non-null value, categories known).
- **The pre-fill rule**: when the record chosen for a purpose has a `prefilled_by` (for categories:
  `categories_prefilled_by`) that names the model the run evaluates, the receipt has no ground
  truth for that purpose in that run (the QR stand-in for the kind is not used either). The counts
  are in the run's `counts` and on the console: `excluded_prefilled_items`, `_merchant`, `_kind`,
  each with an `..._unknown` part (left out because the model could not be known);
  `receipts_excluded_prefilled` and `receipts_excluded_prefilled_unknown` for categories.
  `source:hand` and `source:dps_xml` count for every model; `source:unknown-model` (and any other
  `source:` value) leaves the record out of every OCR run, `source:unknown` out of every
  item-category run. The QR fields are never left out.
- **Same model** (`evaluation/models.py`, the one place; its docstring has the details): a name
  is read as a family, sizes, versions and words, ignoring the publisher or host, case, a backend
  prefix, a routing suffix (`:free`), dates and releases (`-2025-04-14`, `-20260217`, `-2507`),
  quantisation and packaging (`4bit`, `bf16`, `fp8`, `Q4_K_M`, `mlx`, `gguf`, `unsloth`, `qat`),
  `instruct`, a reasoning effort (`high`) and vendor or region words in front (`meta`, `us`,
  `anthropic`). Two names are **different models only with proof**: another family (unless one
  family is a word of the other name), other sizes (`8b` against `235b a22b`), versions that
  differ at a place both have (`qwen2.5` against `qwen3`; `8` against `8 0 1` is not proof), or a
  tier word on one side only (`mini`, `pro`, `flash`, `sonnet`, `opus`, `vl`, ...; mode or host
  labels such as `thinking`, `reasoning`, `turbo` are not tiers). The same words are the same model (`mlx-community/Qwen3-VL-8B-Instruct-4bit` =
  `qwen/qwen3-vl-8b-instruct`; `anthropic/claude-4.6-sonnet-20260217` =
  `anthropic/claude-sonnet-4.6`; `openai/gpt-4.1-mini-2025-04-14` = `openai/gpt-4.1-mini`).
  Anything else is **unknown**, and so is a name that is a path on disk, a run or pre-fill whose
  version is `local` (a model loaded from a folder) or a name that leaves no word: an unknown
  comparison leaves the record out (counted in `..._unknown`). Both the run's `model_name` and
  `model_version` (when it is a name, not a commit hash) and the record's `prefilled_by` and
  `prefilled_model_version` are compared; one `same` pair is enough to leave the record out, and
  it counts only when every pair is proved different.

### OCR metrics

Per receipt, then summed per segment. A prediction line `skipped` is not scored; `parse_failed` and
`error` count as wrong (no fields, no items).

| Key | Definition |
| --- | --- |
| `fields.date`, `.time`, `.total`, `.fiscal_number`, `.receipt_number` | exact match with the QR field (time to the minute, Kyiv time), over receipts whose QR has it |
| `merchant` | `text.normalise_merchant` equal on both sides (below), over receipts whose ground-truth merchant does not normalise to nothing |
| `kind.accuracy`, `kind.confusion` | predicted `kind` (`none` for a missing or failed answer) against the ground truth's, else (no ground-truth kind, none left out by the pre-fill rule) `fiscal` for a receipt with a tax QR code; confusion counts truth by prediction |
| `items.<variant>.precision`, `.recall`, `.f1_micro` | matched / predicted, matched / reference, 2 matched / (predicted + reference), each summed over receipts with item ground truth |
| `items.<variant>.f1_macro` | the mean of per-receipt F1 over the same receipts (with no item on either side: 1 when the backend answered, such as a card slip read right, 0 when it failed) |
| `items.cer_normalised`, `items.cer_plain` | over `main`-matched pairs: the sum of edit distances over the sum of reference name lengths, on normalised names, and on names with only NFC and collapsed spaces |
| `items_sum_to_total` | the predicted amounts add up exactly (decimals) to the QR total, else the ground truth's total; card slips are not counted |
| `parse_failed` | the share of `parse_failed` lines; `errors`, `repaired` are counts |
| `seconds_per_receipt` | mean, median, 90th percentile (nearest rank) over `ok` and `parse_failed` lines |
| `cost_usd` | hosted runs: `evaluation.common.cost_summary` (dollars per receipt and per 1,000) |

Each metric carries `value`, `ci95`, `numerator` and `denominator`.

Segments: `all`; `fiscal`, `card_slip`, `kind_unknown` (the ground truth's kind, pre-fill ignored,
else `fiscal` for a receipt with a tax QR code: the same for every run); `one_photo`, `multi_photo`;
`crop_failed` (a run with crops: a receipt for which a full photo was sent; null without crops).

**Names** (`evaluation/text.py`, the one place): NFKC and case folding; apostrophes removed;
anything but letters and digits becomes a space (so `2,5` and `2.5` agree); a space between digits
and letters (`900г` → `900 г`); units spelled one way (`кг`→`kg`, `г`/`гр`→`g`, `л`→`l`,
`мл`→`ml`, `шт`→`pcs`, `уп`→`pack`); Cyrillic letters that print like Latin ones written as Latin
(`а е о р с у х і к м н т в`); spaces collapsed. A merchant also loses legal-form words (`ТОВ`,
`ФОП`, `ПП`, `ПрАТ`, `ПАТ`, `АТ`, `ДП`, `КП`, `LLC`, `Ltd`). Similarity: `1 - levenshtein / longer
length` (1 for two empty names).

**Matching** (`evaluation/matching.py`): for each predicted and reference item, `name` = the
similarity of the normalised names, `amount` = 1 for equal amounts, else
`max(0, 1 - |p - r| / max(|p|, |r|))` (0 when one is missing), `score = 0.5 name + 0.5 amount`.
A pair qualifies for `lenient` with `name >= 0.6`, for `main` with `score >= 0.8` (which implies
`name >= 0.6`; an exactly right name allows an amount up to 40% off the larger one), for `strict`
with `name >= 0.6` and equal amounts. For each variant the Hungarian method (SciPy's
`linear_sum_assignment`) picks the largest number of qualifying pairs, each item used once, and
among those the highest total score: an extra prediction can never take a match away. Every
`strict` pair qualifies for `main` and every `main` pair for `lenient`, so the counts nest.

### Item-category metrics

Rows are the items of the reference record (`GroundTruth.categories`) of every receipt the run has
a line for; an item with a null `category_slug` is not scored (`unlabelled_items`); an item with no
line counts as wrong (label `_none`, confidence 0); a line for another record or position is not
scored (`unmatched_lines`); a predicted slug not in the `group/category` form, or that no
ground-truth record uses, becomes `_other` (a model's free text never becomes a label). Card slips are scored
apart (`card_slips`: receipts, accuracy, top-3 accuracy of the receipt's category). The metrics are
`categoriser.metrics`': `headline` (macro-F1, the main one, over categories that are a true label
or a top-1 prediction; weighted F1; accuracy; top-3 accuracy), `coverage` (precision of the most
confident rows at 10, 25, 50, 75, 90 and 100% coverage, whole tie groups kept, and at confidence
0.5, 0.7, 0.9), `auto_accept` (the largest coverage whose kept rows are at least 95% precise, and
the confidence that reaches it), `per_class` (support, predictions, F1), `confusion`, `by_source`
(the headline metrics and the calibration for each `source` value that occurs, `unstated` and
`other` included), `seconds_per_item`, `cost_usd` (from the lines' `cost_usd`).

**Calibration** (`calibration`): whether the top candidate's score means what it says, over the
items whose top candidate has a score (`rows_without_score` counts the others). Reliability table:
ten equal-width bins of the score over [0, 1] (`[0, 0.1)`, ..., `[0.9, 1]`, the last one closed),
fixed rather than fitted to the data so two runs are binned alike, each with its number of items,
mean score and share correct. Expected calibration error (`ece`): the sum over bins of
`items in bin / items * |share correct - mean score|`. Brier score of the top candidate (`brier`):
the mean of `(score - correct)^2`, correct being 1 or 0. Both with 95% intervals from resampling
receipts. `scores_calibrated` copies what the run says about its scores (null when it says
nothing), so a reader can tell a raw score from a calibrated one. A bin with few items is noisy:
read the counts. With few items per bin the ECE is biased upwards and its percentile interval is
centred on that biased value, so it rarely covers 0 even for a well-calibrated categoriser; compare
runs of a similar size, and read the reliability table next to it.

**A combined run** is left out on a receipt (the pre-fill rule) when any categoriser it combines
pre-filled that receipt's categories: the identities come from its own `model_name` and every
`model_name` (and `model_version`) in `combined_from`. An entry without a name, an empty or missing
`combined_from` in a run that says it combines (lines with `source: combined`), or a part with the
version `local` counts as unknown, which leaves the record out. `combined_from` is read only for
item-category runs.

The `memory` source answers from earlier bookings of the same text, which may include the booking
whose category became the ground truth; its share correct is an upper bound, so read it apart
(`by_source`) and say so next to it.

### Intervals and comparisons

Every headline metric has a 95% percentile bootstrap interval from resampling receipts (whole
receipts, with their items), 1,000 resamples by default, the seed derived from `--seed` and the run
id (adding a run changes no other run's intervals). They cover the sampling of receipts from this
set only: not how the receipts with ground truth were chosen, not run-to-run variation (greedy
decoding), not other shops.

A comparison is on the receipts both runs scored; every difference is A - B with a paired
bootstrap interval (the same resampled receipts for both). OCR: every headline metric, and
McNemar's test (exact and corrected chi-square, `categoriser.metrics.mcnemar`) on per-receipt
correctness of the QR fields, the merchant, the kind and the items-sum check. Item categories: the
headline metrics on the items both runs scored with the same label, and McNemar's test on per-item
top-1 correctness. Comparisons are declared (`--compare`, a comparisons file) or automatic: same
task, prompt version, image size and token limit, differing in exactly one of the model
(`model`), the crops (`crops`, A = the cropped run) or the backend (`backend`, crops equal, A = the
backend whose name sorts first).

### Outputs

`eval/results/` (`index.json`, `runs/<run id>.json`, `comparisons/<A>__vs__<B>.json`,
`tables/*.md` and `*.csv`: OCR fields by run, by segment, OCR items by run, local against hosted,
full against cropped photos, other OCR comparisons, item categories by run, item categories by
source, calibration (the reliability table), the auto-accept table, item-category comparisons). Files there that a run did not write are removed. Keys are sorted,
floats rounded to 6 places in JSON; tables have fixed rounding (one decimal for percentages and
percentage points, two for seconds, three for p-values) and a fixed row order, so the same inputs
give byte-identical files; the only times in them are `started_at` and `finished_at` copied from
`run.json`.

**What may enter `eval/results/`**: numbers, category slugs, model names and run parameters. Never
an item name, a merchant, a receipt id, a single receipt's amount or date, or a local path. The
writer (`evaluation/results.py`) checks every file against a declared structure before writing it
(exact keys; numbers only where numbers are declared and no per-receipt lists; text only from fixed
labels, narrow patterns or values read from a `run.json`) and every table cell likewise, and
refuses anything else with an error that names the place, never the value. Per-receipt detail is
written only with `--diagnostics DIR`, which must be outside any git repository (files mode 600).
The console prints aggregates only.

`evaluation.ocr_fields` still scores one run quickly against the QR codes; the harness is what the
results chapter uses.

## Code layout

```
app/
  main.py          FastAPI app and routes
  schemas.py       request and response models
  errors.py        the shared error shape and handlers
  config.py        settings from environment variables
  decisions.py     the Decisions API client: typed questions, checked answers
  transactions.py  /categorise/transaction: the served transaction categoriser, loaded lazily
  backends/        OCR
    __init__.py    registry: backend name -> class
    base.py        the Backend interface and the shared errors
    stub.py        the stub backend (default)
    mlx_worker.py  the one MLX worker thread, shared with the categoriser
    mlx.py         the local MLX backend: VisionGenerator protocol
    mlx_vlm_generator.py  the real model call (mlx-vlm), shared loaded models; Apple silicon only
    openrouter.py  the hosted backend and OpenRouterClient: zero-retention routing, Transport protocol
  categorise/      item categorisation
    __init__.py    registry: categoriser name -> class
    base.py        the Categoriser interface
    prompt.py      the prompt, the answer schema, PROMPT_VERSION
    labels.py      scoring every slug over a token trie (TokenModel protocol)
    logprobs.py    scores from hosted token log-probabilities
    calibration.py reading and applying a calibration
    taxonomy.py    the category hand-over: a request's list or an exported file
    stub.py, mlx.py, openrouter.py, off.py  the categorisers (off: switched off)
    decisions.py   the decision-model categoriser: flat, two-stage, verify
    mlx_token_model.py  the real token model (mlx-vlm); Apple silicon only
  batch/           batch mode (off unless OPENROUTER_BATCH_ALLOW_RETENTION=true)
    base.py        the OcrBatches interface and its value types
    openrouter.py  OpenRouter's Batch API: catalogue, submit, status, results, delete
    routes.py      the /ocr/batches endpoints
    schemas.py     their request and response models
  ocr/
    prompt.py      the prompt, the answer schema, PROMPT_VERSION
    parsing.py     the model's text to a raw receipt, with one repair pass
    postprocess.py the raw receipt to the API's Receipt (plain code)
    images.py      decode, turn upright, scale down
evaluation/
  ocr_run.py       run a backend over the receipt set
  ocr_fields.py    score a run against the QR codes
  item_categories_run.py        run a categoriser over labelled items
  item_categories_calibrate.py  fit a calibration from a run
  item_sanity.py   a smoke test on the invented sanity set
  item_categories_combine.py    combine runs: cascade, average, learned (CV by receipt)
  item_scores.py   accuracy, top-3, reliability, auto-accept share
  label_memory.py  the label memory's rule, as the app applies it
  common.py        shared helpers (timings, cost summary)
  harness.py       the evaluation harness (make eval): every run, comparisons, eval/results/
  inputs.py        reading the receipt set, the run folders and the ground-truth export
  truth.py         which ground truth counts: exclusions, precedence, the pre-fill rule
  models.py        model identity: which names are the same model (the pre-fill rule)
  text.py          name normalisation and similarity (the one place)
  matching.py      one-to-one item matching (Hungarian method)
  ocr_scoring.py   OCR metrics per receipt and per segment
  category_scoring.py  item-category metrics
  bootstrap.py     bootstrap intervals over receipts
  comparisons.py   paired comparisons between runs
  results.py       the whitelisted writer of eval/results/
  tables.py        the tables, generated from the results JSON
categoriser/       transaction categoriser training and the fit for serving (serving.py; see below)
tests/
```

## Adding a real backend

1. Create a class in `app/backends/` that extends `Backend` from `base.py`.
   Set `name`, `model_name` and `model_version`.
   The constructor takes the `Settings`.
2. Implement `extract_receipt(images)`.
   `extract_receipt` returns an `Extraction` (the `Receipt`, the prompt
   version, whether a repair was needed, and diagnostics for the evaluation).
   A vision model backend uses `app/ocr/` for the prompt, the parsing and the
   post-processing. Raise `BackendNotImplementedError` for a task the backend
   does not support yet, and `BackendError` (a status, a code, a short message
   of your own) for a failure the client must tell apart: a 5xx other than
   501 is retried by the Rails job, a 4xx or 501 is not.
3. Batch mode (`batches()`) is optional: the base class answers 501. A
   backend that has it returns an `app.batch.base.OcrBatches`.
4. If it needs to load something, do it in `start()` (called once when the
   service starts) and release it in `stop()`.
5. Add the class to `BACKENDS` in `app/backends/__init__.py`. It can now be
   selected with `OCR_BACKEND`. A categoriser is the same in `app/categorise/`:
   a `Categoriser` with `categorise(request)` returning a `Categorisation`,
   registered in `CATEGORISERS`, selected with `CATEGORISE_BACKEND`; it answers
   with the request's slugs only and uses `prompt.py`.
6. Read any new settings (model path, API key) in `app/config.py`. Never
   commit keys or model weights.
7. Add tests. The tests must not need network access or real model weights.

The methods are synchronous. The API runs them in a worker thread, so a slow
model does not block the server.

## Transaction categoriser (training)

`categoriser/` trains and evaluates a model that suggests a ledger category for a
transaction from its text and bank fields; `categoriser.serving` fits the chosen
configuration for the HTTP service (see "The transaction categoriser"). It runs
only on this machine: transaction data is never sent anywhere.
The reasons behind the design, and the evaluation protocol, are in
`docs/decisions/0006-transaction-categoriser.md`.

Two commands, so that the test set is scored once:

```sh
# 1. Choose the configuration on the validation slice (the test set stays sealed).
uv run python -m categoriser.selection ~/path/to/export      # writes <run>.selection.json to ~/Documents/money_bin_data/models/
# 2. Score the test set once, for the chosen configuration.
uv run python -m categoriser.score ~/path/to/export --selection ~/Documents/money_bin_data/models/<run>.selection.json
```

The input is a history export (`docs/import-contract.md`). Both commands check
the manifest's file hashes before they read anything.

`selection` options: `--out DIR`, `--seed N` (42), `--test-fraction` (0.2),
`--validation-fraction` (0.15), `--c-grid` (0.1 0.3 1 3 10), `--resamples`
(1000 bootstrap resamples), `--min-df` (2), `--encoders` (`e5-base e5-large`;
none for TF-IDF only), `--embedding-cache DIR`
(`~/Documents/money_bin_data/cache/embeddings/`), `--taxonomy`
(`../db/seeds/taxonomy.yml`). `score` options: `--selection FILE` (required),
`--out DIR`, `--resamples`, `--embedding-cache DIR`, `--taxonomy`,
`--rescore-reason TEXT`, `--code-change-reason TEXT`. The seed, the
fractions and every tuned value come from the selection file.

**Rows.** One per transaction that is not a transfer leg. A split transaction
is represented by its largest line by absolute amount (the first line on a
tie). The label is that line's category, as the export names it (`"Group /
Category"`). A line without a category, or one the export leaves unmapped,
maps to names outside the app's taxonomy, or maps to Uncategorised, has no
label: the row is dropped and counted (as the importer sends such a line to
Uncategorised). The counts of split and tied transactions cover every
transaction that is not a transfer leg, before these drops.

**Split.** Rows are ordered by date; the last 20% are the test set, and a
calendar day is never split between the sides. The last 15% of the training
rows are the validation slice; the rest are the fitting rows. The test set is
a `SealedTest`: its rows refuse to be read until `categoriser.score` unseals
them, so a selection run cannot use a test label or write a test metric.

**Candidates** (all fitted on the fitting rows, scored on the validation slice):

| Part | What it is | Tuned on validation |
| --- | --- | --- |
| `tfidf` | the first version: TF-IDF over the joined payee, merchant, bank description and comment (word 1-2-grams, character 2-5-grams) plus one-hot MCC, amount sign, amount size bucket (a power of ten, per currency), account kind and payee, into a logistic regression with balanced class weights | `C` |
| `emb:<encoder>` | a local sentence embedding of the same text plus the one-hot fields | `C` |
| `tfidf+emb:<encoder>` | both | `C` |
| `+recency` | sample weights `0.5 ** (age in days / half-life)`, mean 1 | the half-life (`C` kept) |
| `+classweight` | class weights `(n / (K * n_c)) ** power` (1 is "balanced") | the power (`C` kept) |
| `+recency+classweight` | both, with the tuned half-life and power | `C` again |
| `+mix` | the hybrid: `w * q + (1 - w) * p_model`, `q` the payee's category shares in the fitting rows, `w = n / (n + k) * purity ** beta`; for an unknown payee, the MCC's shares with weight `alpha_mcc * ...` | `k`, `beta`, `alpha_mcc` |
| `+switch` | the payee's history decides when it was seen at least `min_count` times with a purity of at least `min_purity`; the model otherwise (its confidence is then close to 1, so its coverage curve says little) | `min_count`, `min_purity` |

The encoders: `e5-base` (`intfloat/multilingual-e5-base`) and `e5-large`
(`intfloat/multilingual-e5-large`), with the "query: " prefix and mean
pooling, each at a pinned revision, loaded with `local_files_only` from the
local Hugging Face cache (no remote code) and run with PyTorch on the Apple
GPU. Download the weights of each once (no transaction data is involved):
`uv run hf download intfloat/multilingual-e5-base --revision <revision>` and the same for
`intfloat/multilingual-e5-large`, with the revisions in `categoriser/embeddings.py`.
torch and transformers are in the `embeddings` dependency group, which a plain
`uv sync` installs on macOS on Apple silicon only; elsewhere, and in the tests
(which use a fake encoder), they are not needed. The vectors are cached in a
SQLite file keyed by the SHA-256 of the encoder (model, revision, prefix,
pooling, maximum length) and the text, so each distinct text is encoded once.

**Selection rule** (fixed before any candidate was scored, recorded in the
JSON): eligible are the candidates whose validation top-3 accuracy is at least
the lower end of the day-resampled 95% interval of the best validation top-3;
among them, the best validation macro-F1; ties (within 0.005) go to the
simpler candidate (no neural encoder first, then the fewest parts beyond the
first version).

**Final score.** `score` reads the selection file, refuses another export,
taxonomy or split, refits the chosen configuration on the whole training
period (fitting rows + validation slice) with every tuned value kept, refits
the first version and the baselines the same way, and scores them all on the
test set. It also refuses another encoder, another selection format, another
test set, a chosen configuration that the recorded rule does not pick from
the recorded table, and code other than the committed code the selection ran
on (another or an unknown commit, modified files, other library versions;
`--code-change-reason` overrides, and the reason is recorded). It refits and
loads the encoders before it opens the seal, and appends each unsealing to a
record of test scores
(`~/Documents/money_bin_data/categoriser-test-scores.jsonl`, always that file,
under a lock) before it reads a test row. It refuses to score an export that the record or
the output folder shows as scored already, unless `--rescore-reason` says why
(the reason is recorded).

**Baselines.** `majority` (always the most frequent category) and `payee_mcc`
(the payee's most frequent category, else the MCC's, else the majority); the
best of the two on validation macro-F1 is the one the model is compared with.

**Selection JSON** (`<run>.selection.json`): the split (for the test set only
its size and first day), the profile of the fitting rows and the validation
slice, the baselines, and per candidate: its configuration and complexity,
macro-F1, weighted F1, accuracy and top-3 accuracy with 95% intervals by rows
and by days, the interval of its difference from the first version (days),
precision by coverage level and confidence threshold, and the headline
metrics per segment; the tuning grids with their validation scores; the rule,
its trace and the chosen configuration. No test metric.

**Final metrics JSON** (`<run>.final.json`; `metrics_version` 3):

| Key | Meaning |
| --- | --- |
| `final_scoring` | which configuration was scored, when, from which selection file (also `selection.sha256`), earlier scores of the export, a rescore reason, and the protocol statement |
| `test.systems.<name>` | `majority`, `payee_mcc`, `first_version`, `final`: macro-F1 (the main metric), weighted F1, accuracy and top-3 accuracy, each with a 95% bootstrap interval over test rows; `coverage`: precision when only the most confident rows are kept |
| `test_ci95_resampling_days` | the same intervals, resampling whole days: rows of one day (and one payee) are not independent, so the row intervals are probably too narrow |
| `final_minus_best_baseline_ci95`, `final_minus_first_version_ci95` (and `..._resampling_days`) | paired intervals of the final model's gain, by rows and by days |
| `mcnemar_final_vs_best_baseline`, `mcnemar_final_vs_first_version`, `mcnemar_first_version_vs_best_baseline` | McNemar's test on top-1 correctness: rows only one side got right, exact and corrected chi-square p-values; it assumes independent rows |
| `segments` | the headline metrics for test rows with and without bank fields, and with a payee seen or not seen in training |
| `profile`, `per_class`, `rows`, `split`, `labels` | how the periods differ, per-category support and F1, row counts, split dates, categories missing from training |
| `export`, `reproducibility` | the manifest and taxonomy SHA-256, the seed, the git commit, Python, library and encoder versions, every parameter |

Macro-F1 is scikit-learn's default: the mean F1 over every category that is a
true label or a top-1 prediction in the evaluated rows. At a coverage level,
rows whose confidence ties with the last kept row are all kept, and the
coverage actually reached is reported next to the target: plot precision
against `coverage`, not `target_coverage`. The test period differs from the
training period (more bank feeds, new payees); read the `segments` and
`profile` keys before quoting a headline number.

**Files.** The model file (`<run>.final.joblib`) holds the training
vocabulary and, for a hybrid, the payee tables, which include payee names; the
embedding cache holds vectors of transaction texts. None of them goes into git:
the commands refuse an output or cache folder inside a git repository and
write files with mode 600. The JSON files and the console hold category names
and numbers only, never a payee, comment, description or amount. The tests
build a small synthetic export with invented data and use a fake encoder.

## The transaction categoriser

The model chosen and scored above, served by `/categorise/transaction`.

**The fit for serving.** After the selection and the one test score:

```sh
uv run python -m categoriser.serving ~/path/to/export \
  --selection ~/Documents/money_bin_data/models/<run>.selection.json
# → <stamp>.serving.joblib and <stamp>.serving.json in ~/Documents/money_bin_data/models/
```

It fits the selection's chosen configuration, every tuned value kept as a
number, on **every labelled row of the export, the test period's included**:
the newest rows are the most like tomorrow's, so the served model keeps them.
That fit has no test score of its own: the evaluated numbers belong to the
same configuration fitted on the training period (`categoriser.score`), and the
metadata says so. Nothing in this step computes a metric, chooses anything from
the test labels or writes to the record of test scores. It reuses the
training code (`fit_system` and its feature builders), and it refuses what it
cannot vouch for: a selection file whose rule does not pick its chosen
configuration; another export (manifest hash), another taxonomy, or rows that
no longer split as the selection's did; a selection the record of test scores
has no score of; a file of `categoriser/` that existed at the selection's commit
and differs now, an unknown commit, or other library versions
(`--code-change-reason` overrides only this, recorded); another encoder; an
output folder inside a git repository. Options: `--out DIR`,
`--embedding-cache DIR`, `--taxonomy FILE`, `--code-change-reason TEXT`.

The artefact (mode 600) holds the fitted pipeline, the hybrid's payee and MCC
tables (payee names: personal data, never in git), the configuration, the
classes with their group and category names, and the metadata, also written as
`<stamp>.serving.json` (category names and numbers only): the configuration,
the export's manifest hash, the selection file and its SHA-256, the split it
was selected on, when the test set was scored, what this fit is fitted on,
the git state, the library versions, the fit time and the class list. The
service names it by its fit date and file hash (`model_version`).

**Loading.** Lazily, once: the first `GET` or `POST` reads the artefact
(scikit-learn is imported then, not at startup), and the first `POST` builds
the sentence encoder and loads its weights. Measured on the owner's machine
(M-series, 32 GB) with the real artefact and the stub OCR backend: the service
starts at about 70 MB; reading the artefact takes 0.1 s and brings it to about
230 MB; the first `POST` takes about 14 s (importing PyTorch, loading the e5-base
weights, starting the Apple GPU) and brings it to about 1.1 GB; after that, 1
transaction takes about 15 ms, 200 about 0.14 s and 500 about 0.26 s. Next to
the 8B vision model (about 7 GB with `OCR_BACKEND=mlx`) that is about 1 GB more
once a transaction is categorised; the vision model is not touched. A request
waits for the one before it (one lock around the model).

**Offline.** The encoder's weights come from the local Hugging Face cache only
(`local_files_only`, `HF_HUB_OFFLINE` set when it loads), at the revision
pinned in `categoriser/embeddings.py`; download them once as described above
(no transaction data is involved). Nothing is downloaded at request time:
without the weights the endpoint answers 501 `transaction_categoriser_unavailable`
with the command to fetch them. Setting `HF_HUB_OFFLINE` is process-wide; a
local OCR model is loaded at startup, before it. A served request computes the
sentence vectors afresh (no on-disk cache) and scales each to unit length in
float32, exactly as the training's cache stores them (`UnitEncoder`; a test
compares the two); they may still differ from the cached ones in the last
digits (another batch, another device).

**What never leaves the machine.** Payees, comments, bank descriptions,
merchants, amounts: the endpoint runs the model in this process. There is no
hosted transaction categoriser and no setting that would add one; the serving
code imports no HTTP client (a test checks it), every test runs with the
network refused, and the Rails client sends transaction data only to a service
on a loopback host (`MlClient::NotLocal` otherwise).
