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
  refused from its size and never read into memory;
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
