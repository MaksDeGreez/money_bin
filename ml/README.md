# money_bin ML service

A small HTTP service for the money_bin app. It does two jobs:

- **Receipt OCR.** It reads a receipt from 1 to 3 photos and returns the
  merchant, date, total and items.
- **Item categorisation.** It suggests categories for receipt item texts.

The Rails app calls this service and stores the results.

Two backends work today:

- **`stub`** (the default) returns fixed, invented data in the final response
  shapes. The tests and CI use it.
- **`mlx`** reads receipts with a local vision-language model (a Qwen VL model
  run by [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)) on a Mac with Apple
  silicon. Nothing leaves the machine. It does not categorise yet (501).

`openrouter` (a hosted model) is a placeholder that answers 501.

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
OCR_BACKEND=mlx uv run uvicorn app.main:app --host 127.0.0.1 --port 8100
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

The tests never load a model: the `mlx` backend is tested with a fake
generator. `app/backends/mlx_vlm_generator.py`, the only code that calls
mlx-vlm, is left out of the coverage measurement.

## Settings

| Variable                       | Default                                     | Values                      | Meaning |
| ------------------------------ | ------------------------------------------- | --------------------------- | ------- |
| `OCR_BACKEND`                  | `stub`                                      | `stub`, `mlx`, `openrouter` | The model backend to use. |
| `ML_MAX_IMAGE_BYTES`           | `15728640`                                  | a whole number above 0      | The largest image file, in bytes (15 MB). |
| `MLX_OCR_MODEL`                | `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` | a Hugging Face id or a folder | The `mlx` backend's model. `mlx-community/Qwen3-VL-8B-Instruct-4bit` works too. |
| `MLX_OCR_MAX_TOKENS`           | `3072`                                      | a whole number above 0      | The most tokens the model may write for one answer. A receipt with 40 items needs about 2,000. |
| `MLX_OCR_IMAGE_MAX_SIDE`       | `2048`                                      | 256 to 4096                 | Each photo is scaled down so that its longer side is at most this many pixels. |
| `MLX_OCR_CONSTRAINED_DECODING` | `true`                                      | `true`, `false`             | Constrain the model's answer to the JSON schema (see "The mlx backend"). |

An unknown `OCR_BACKEND` value stops the service at startup. The error
message lists the valid names.

## Endpoints

### `GET /health`

```sh
curl http://127.0.0.1:8100/health
```

```json
{"status": "ok", "backend": "stub", "model_name": "stub-ocr", "model_version": "0.1.0"}
```

With `mlx`, `model_name` is the model id (`MLX_OCR_MODEL`) and
`model_version` the revision of the weights: the Hugging Face commit, or
`local` for a model in a plain folder.

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
  time).

### `POST /categorise`

Send JSON with 1 to 200 non-empty texts.

```sh
curl -H "Content-Type: application/json" \
  -d '{"texts": ["milk 2.5% 900g"]}' \
  http://127.0.0.1:8100/categorise
```

```json
{
  "results": [
    {
      "text": "milk 2.5% 900g",
      "candidates": [
        {"category_slug": "groceries/groceries", "score": 0.71},
        {"category_slug": "household-shopping/household-supplies", "score": 0.18},
        {"category_slug": "eating-out/takeaway-fast-food", "score": 0.11}
      ]
    }
  ],
  "backend": "stub",
  "model_name": "stub-categoriser",
  "model_version": "0.1.0"
}
```

Each text gets exactly 3 candidates, sorted by score (highest first). Scores
are between 0 and 1. Results keep the order of `texts`. A `category_slug` has
the form `group-slug/category-slug`; the Rails app owns these slugs. The stub
picks slugs from a hash of the text, so the same text always gets the same
answer (the numbers above are only an example).

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
| 501    | `backend_not_implemented` | The selected backend is only a placeholder.    |
| 500    | `internal_error`          | An unexpected error. Details go to the log.    |

`ocr_parse_failed` is a 4xx on purpose: the model is deterministic
(temperature 0), so sending the same photos again gives the same answer. The
message names the fields and the kind of problem, never what the model read.

## The mlx backend

`app/backends/mlx.py`. In short (the reasons are in
`docs/decisions/0005-local-ocr-backend.md`):

- **One worker thread.** MLX keeps its GPU streams per thread, and FastAPI runs
  each request in a thread of its own pool. So one dedicated thread (a
  single-thread executor) loads the model at startup and runs every
  generation; a request hands its work to that thread and waits. One receipt
  is read at a time; others wait in the queue.
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
`--model ID`, `--image-max-side N`, `--max-tokens N`. It writes
`<out>/<run id>/predictions.jsonl` (one line per receipt: status `ok`,
`parse_failed`, `error` or `skipped` for more than 3 photos; seconds; whether it
was repaired; the receipt; token counts, peak memory and post-processing
counts) and `run.json` (backend, model, weights revision, prompt version, git
commit, settings, counts, seconds per receipt).

`ocr_fields` scores the receipts that have QR fields: date, time (to the
minute, Kyiv time), total, fiscal number and receipt number as shares of exact
matches; the share of receipts whose items add up exactly to the QR total
(there is no item ground truth yet, so this stands in for item quality); the
share read as `fiscal`; parse failures; seconds per receipt (mean, median, 90th
percentile). A failed receipt counts as wrong for every field. The scores are
also written to `scores.json` in the run folder.

## Code layout

```
app/
  main.py          FastAPI app and routes
  schemas.py       request and response models
  errors.py        the shared error shape and handlers
  config.py        settings from environment variables
  backends/
    __init__.py    registry: backend name -> class
    base.py        the Backend interface
    stub.py        the stub backend (default)
    mlx.py         the local MLX backend: worker thread, VisionGenerator protocol
    mlx_vlm_generator.py  the real model call (mlx-vlm); macOS on Apple silicon only
    openrouter.py  placeholder for a hosted model
  ocr/
    prompt.py      the prompt, the answer schema, PROMPT_VERSION
    parsing.py     the model's text to a raw receipt, with one repair pass
    postprocess.py the raw receipt to the API's Receipt (plain code)
    images.py      decode, turn upright, scale down
evaluation/
  ocr_run.py       run a backend over the receipt set
  ocr_fields.py    score a run against the QR codes
  common.py        shared helpers
categoriser/       transaction categoriser training (see below)
tests/
```

## Adding a real backend

1. Create a class in `app/backends/` that extends `Backend` from `base.py`.
   Set `name`, `model_name`, `categoriser_model_name` and `model_version`.
   The constructor takes the `Settings`.
2. Implement `extract_receipt(images)` and `categorise(texts)`.
   `extract_receipt` returns an `Extraction` (the `Receipt`, the prompt
   version, whether a repair was needed, and diagnostics for the evaluation).
   A vision model backend uses `app/ocr/` for the prompt, the parsing and the
   post-processing. Raise `BackendNotImplementedError` for a task the backend
   does not support yet.
3. If it needs to load something, do it in `start()` (called once when the
   service starts) and release it in `stop()`.
4. Add the class to `BACKENDS` in `app/backends/__init__.py`. It can now be
   selected with `OCR_BACKEND`.
5. Read any new settings (model path, API key) in `app/config.py`. Never
   commit keys or model weights.
6. Add tests. The tests must not need network access or real model weights.

The methods are synchronous. The API runs them in a worker thread, so a slow
model does not block the server.

## Transaction categoriser (training)

`categoriser/` trains and evaluates a model that suggests a ledger category for a
transaction from its text and bank fields. It is not part of the HTTP service
yet. It runs only on this machine: transaction data is never sent anywhere.
The reasons behind the design are in
`docs/decisions/0006-transaction-categoriser.md`.

```sh
uv run python -m categoriser.train ~/path/to/export          # writes to ~/Documents/money_bin_data/models/
uv run python -m categoriser.train ~/path/to/export --out ~/elsewhere --seed 42
```

The input is a history export (`docs/import-contract.md`). The command checks
the manifest's file hashes before it reads anything. Options: `--out DIR`,
`--seed N` (42), `--test-fraction` (0.2), `--validation-fraction` (0.15),
`--c-grid` (0.1 0.3 1 3 10), `--resamples` (1000 bootstrap resamples),
`--min-df` (2), `--taxonomy` (`../db/seeds/taxonomy.yml`).

**Rows.** One per transaction that is not a transfer leg. A split transaction
is represented by its largest line by absolute amount (the first line on a
tie). The label is that line's category, as the export names it (`"Group /
Category"`). A line without a category, or one the export leaves unmapped,
maps to names outside the app's taxonomy, or maps to Uncategorised, has no
label: the row is dropped and counted (as the importer sends such a line to
Uncategorised). The counts of split and tied transactions cover every
transaction that is not a transfer leg, before these drops.

**Features.** Payee, merchant, bank description and comment (TF-IDF over word
1-2-grams and character 2-5-grams), plus one-hot MCC, amount sign, amount size
bucket (a power of ten, per currency), account kind and payee. The model is a
logistic regression with balanced class weights.

**Split.** Rows are ordered by date; the last 20% are the test set, and a
calendar day is never split between the sides. The last 15% of the training
rows are a validation slice: the regularisation strength `C` and the best
baseline are chosen there. Then everything is fitted again on the whole
training period and evaluated once on the test set. Nothing is fitted on test
rows.

**Baselines.** `majority` (always the most frequent category) and `payee_mcc`
(the payee's most frequent category, else the MCC's, else the majority).

**Metrics** (one JSON per run, next to the model file; `metrics_version` 2):

| Key | Meaning |
| --- | --- |
| `test.systems.<name>` | macro-F1 (the main metric), weighted F1, accuracy and top-3 accuracy, each with a 95% bootstrap interval over test rows (`ci95`); `coverage`: precision when only the most confident rows are kept, by coverage level and by confidence threshold |
| `test_ci95_resampling_days` | the same intervals, resampling whole days instead of rows: rows of one day (and one payee) are not independent, so the row intervals are probably too narrow |
| `model_minus_best_baseline_ci95`, `..._resampling_days` | the interval of the model's gain over the best baseline (paired resamples), by rows and by days |
| `mcnemar_model_vs_best_baseline` | McNemar's test on top-1 correctness (so it compares accuracy): rows only the model got right, rows only the baseline got right, exact and corrected chi-square p-values; it assumes independent rows, so its p-value is probably too small |
| `segments` | the same headline metrics for test rows with and without bank fields, and with a payee seen or not seen in training |
| `profile` | the share of rows with bank fields, an MCC, a payee, a comment, for training and test: how the two periods differ |
| `per_class` | per category: training and test support, F1 of each system (null where the category is neither true nor that system's prediction) |
| `rows`, `split`, `labels`, `tuning` | row counts (transfers, splits, ties, drops), the split dates, categories missing from training, the validation scores |
| `export`, `reproducibility` | the manifest SHA-256, the taxonomy's SHA-256, the seed, the git commit, Python and library versions, every parameter |

Macro-F1 is scikit-learn's default: the mean F1 over every category that is a
true label or a top-1 prediction in the evaluated rows. At a coverage level,
rows whose confidence ties with the last kept row are all kept, and the
coverage actually reached is reported next to the target: plot precision
against `coverage`, not `target_coverage`. The test
period differs from the training period (more bank feeds, new payees); read
the `segments` and `profile` keys before quoting a headline number.

**Files.** The model file (`transaction-categoriser-<time>-<manifest>.joblib`)
holds the training vocabulary, which includes payee names, so it never goes
into git: the command refuses an output folder inside a git repository and
writes both files with mode 600. The metrics JSON and the console hold
category names and numbers only, never a payee, comment, description or
amount. The tests build a small synthetic export with invented data.
