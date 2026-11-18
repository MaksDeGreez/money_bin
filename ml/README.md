# money_bin ML service

A small HTTP service for the money_bin app. It does two jobs:

- **Receipt OCR.** It reads a receipt from 1 to 3 photos and returns the
  merchant, date, total and items.
- **Item categorisation.** It suggests categories for receipt item texts.

The Rails app calls this service and stores the results.

Today the service runs a **stub** backend. It returns fixed, invented data in
the final response shapes. Real models (a local MLX vision model or a hosted
model through OpenRouter) come in a later phase.

## Requirements

- [uv](https://docs.astral.sh/uv/)
- Python 3.12 (uv installs it if it is missing)

## Install

```sh
cd ml
uv sync
```

## Run

```sh
uv run uvicorn app.main:app --host 127.0.0.1 --port 8100
```

The interactive API docs are at <http://127.0.0.1:8100/docs>.

## Test and lint

```sh
uv run pytest                 # tests with coverage; fails below 70%
uv run ruff check .           # lint
uv run ruff format --check .  # format check (use `ruff format .` to fix)
```

## Settings

| Variable             | Default    | Values                      | Meaning                                |
| -------------------- | ---------- | --------------------------- | -------------------------------------- |
| `OCR_BACKEND`        | `stub`     | `stub`, `mlx`, `openrouter` | The model backend to use.              |
| `ML_MAX_IMAGE_BYTES` | `15728640` | a whole number above 0      | The largest image file, in bytes (15 MB). |

An unknown `OCR_BACKEND` value stops the service at startup. The error
message lists the valid names. `mlx` and `openrouter` are placeholders: `/health`
works, but `/ocr` and `/categorise` answer with HTTP 501.

## Endpoints

### `GET /health`

```sh
curl http://127.0.0.1:8100/health
```

```json
{"status": "ok", "backend": "stub", "model_name": "stub-ocr", "model_version": "0.1.0"}
```

### `POST /ocr`

Send `multipart/form-data` with the field `images`, 1 to 3 times. Allowed
types: `image/jpeg`, `image/png`, `image/webp`, `image/heic`.

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
    "merchant": "Example Market",
    "fiscal_number": "0000000000",
    "receipt_number": "000123",
    "issued_at": "2026-01-15T12:34:00+02:00",
    "total": "123.45",
    "currency": "UAH",
    "items": [
      {"name": "Milk 2.5% 900 g", "quantity": "1.000", "unit_price": "42.50", "amount": "42.50", "discount": "0.00"},
      {"name": "White bread", "quantity": "1.000", "unit_price": "28.90", "amount": "28.90", "discount": "0.00"},
      {"name": "Bananas", "quantity": "0.850", "unit_price": "64.00", "amount": "52.05", "discount": "2.35"}
    ]
  },
  "backend": "stub",
  "model_name": "stub-ocr",
  "model_version": "0.1.0"
}
```

Notes:

- Money and quantities are decimal **strings**, never floats.
- `amount` is the price of the line after the discount.
- `currency` is an ISO 4217 code.
- `merchant`, `fiscal_number`, `receipt_number` and `issued_at` may be `null`.
  `items` may be empty.

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
| 501    | `backend_not_implemented` | The selected backend is only a placeholder.    |
| 500    | `internal_error`          | An unexpected error. Details go to the log.    |

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
    mlx.py         placeholder for a local MLX model
    openrouter.py  placeholder for a hosted model
tests/
```

## Adding a real backend

1. Create a class in `app/backends/` that extends `Backend` from `base.py`.
   Set `name`, `model_name`, `categoriser_model_name` and `model_version`.
2. Implement `extract_receipt(images)` and `categorise(texts)`. Return the
   models from `app/schemas.py`. Raise `BackendNotImplementedError` for a task
   the backend does not support yet.
3. Add the class to `BACKENDS` in `app/backends/__init__.py`. It can now be
   selected with `OCR_BACKEND`.
4. Read any new settings (model path, API key) in `app/config.py`. Never
   commit keys or model weights.
5. Add tests. The tests must not need network access or real model weights.

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
`--min-df` (2).

**Rows.** One per transaction that is not a transfer leg. A split transaction
is represented by its largest line by absolute amount (the first line on a
tie). The label is that line's category, as the export names it (`"Group /
Category"`). A line without a category, or one the export leaves unmapped or
maps to Uncategorised, has no label: the row is dropped and counted.

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

**Metrics** (one JSON per run, next to the model file):

| Key | Meaning |
| --- | --- |
| `test.systems.<name>` | macro-F1 (the main metric), weighted F1, accuracy and top-3 accuracy, each with a 95% bootstrap interval (`ci95`); `coverage`: precision when only the most confident rows are kept, by coverage level and by confidence threshold |
| `model_minus_best_baseline_ci95` | the interval of the model's gain over the best baseline (paired resamples) |
| `mcnemar_model_vs_best_baseline` | McNemar's test: rows only the model got right, rows only the baseline got right, exact and chi-square p-values |
| `segments` | the same headline metrics for test rows with and without bank fields, and with a payee seen or not seen in training |
| `profile` | the share of rows with bank fields, an MCC, a payee, a comment, for training and test: how the two periods differ |
| `per_class` | per category: training and test support, F1 of each system |
| `rows`, `split`, `labels`, `tuning` | row counts (transfers, splits, ties, drops), the split dates, categories missing from training, the validation scores |
| `export`, `reproducibility` | the manifest SHA-256, the seed, the git commit, Python and library versions, every parameter |

Macro-F1 averages over the categories present in the evaluated rows. The test
period differs from the training period (more bank feeds, new payees); read
the `segments` and `profile` keys before quoting a headline number.

**Files.** The model file (`transaction-categoriser-<time>-<manifest>.joblib`)
holds the training vocabulary, which includes payee names, so it never goes
into git: the command refuses an output folder inside a git repository and
writes both files with mode 600. The metrics JSON and the console hold
category names and numbers only, never a payee, comment, description or
amount. The tests build a small synthetic export with invented data.
