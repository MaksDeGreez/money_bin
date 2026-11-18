# 0005. Local OCR backend: a Qwen vision model through mlx-vlm

Status: accepted.

## Context

The ML service (`ml/`) had a stub backend and two placeholders. The first real OCR backend has to run on
the owner's machine (an Apple silicon Mac with 32 GB of memory), so that receipt photos never leave it.
Open vision-language models in the Qwen VL family read printed text well and come converted to Apple's
MLX format in 4-bit form (about 5.5 GB each); [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) runs them.
A hosted model will follow as a second backend, and the two have to be comparable on the same receipts.

Ukrainian receipts bring their own details: fiscal receipts and card terminal slips, comma decimals, a
tax letter after each amount, quantity lines and discount lines printed apart from the item, long
receipts photographed in up to three overlapping parts, and a QR code that holds the date and time, the
total and two fiscal numbers.

## Decision

### `OCR_BACKEND=mlx` runs a Qwen VL model with mlx-vlm

`MLX_OCR_MODEL` names the model; `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` and
`mlx-community/Qwen3-VL-8B-Instruct-4bit` both work. The default is a starting point; the choice between
them is made from measurements on the receipt set and recorded separately. All the photos of a receipt go
to the model in one call, with greedy decoding (temperature 0), so the same photos give the same answer.
`model_version` is the Hugging Face commit of the weights, so a stored result says exactly which weights
produced it. The weights are read from the Hugging Face cache; the Hub is contacted only when they are
not there.

### One worker thread owns the model

MLX keeps its GPU streams per thread, and mlx-vlm creates its generation stream when it is imported.
FastAPI runs every synchronous endpoint in a thread of its own pool, so a request thread that called the
model directly would use a stream that belongs to another thread. A lock around the call would serialise
the work but not fix the thread.

So the backend has one dedicated worker thread (a single-thread executor). That thread imports mlx-vlm,
loads the model when the service starts, and runs every generation. A request decodes and scales its
photos on its own thread, hands the model call to the worker through the executor's queue, and waits.
mlx-vlm's own server uses the same pattern. Consequences:

- one receipt is read at a time; others wait in the queue, and their `elapsed_seconds` includes the wait;
- the model is loaded at startup, not on the first request: a missing package or model stops the service
  at once instead of failing later, and the first receipt is not slower than the others;
- the model call is behind a small `VisionGenerator` protocol, so the tests use a fake generator and
  assert that loading and every generation run on the same thread, from many requests at once. The real
  generator (`app/backends/mlx_vlm_generator.py`) is the only code that needs MLX; it is left out of the
  coverage measurement and was checked by hand with both models, through uvicorn, with requests one after
  another and at the same time.

### mlx-vlm in a platform-limited dependency group

MLX exists only for macOS on Apple silicon; CI runs on Linux. mlx-vlm is pinned exactly (its API changes
between releases) in the `mlx` dependency group with the markers
`sys_platform == 'darwin' and platform_machine == 'arm64'`, and the group is in `[tool.uv]
default-groups`. A plain `uv sync`, which `bin/setup` and therefore `bin/ci` run, installs it on the Mac,
and the same locked `uv sync --locked` installs nothing of it on Linux. The service imports mlx-vlm only
on the worker thread, so the stub backend and every test work without it. Dependabot keeps MLX, mlx-vlm
and transformers out of its grouped updates: each comes as its own pull request, because CI cannot run
the model and an update has to be tried on the Mac.

### The prompt, the parsing and the post-processing are shared

The instructions, the answer's JSON schema, the parsing with its repair pass and the post-processing live
in `ml/app/ocr/`, not in the backend. A hosted backend will use the same modules, so a comparison between
a local and a hosted model measures the models and nothing else. `PROMPT_VERSION`, a hash of the prompt
texts and the schema, goes into every answer and every evaluation run, so results from different prompts
are never mixed up.

The model copies values as printed, as strings. Everything that needs a rule or arithmetic is plain code
in `postprocess.py`: decimal commas, thousands separators, the tax letter, quantity lines, discount lines,
Kyiv time, the fiscal number's 10 digits, and whether the items add up to the total. Models are poor at
arithmetic and inconsistent with formats; code is testable and the same for every model.

The post-processing never rounds money. A money value with more than 2 decimal places, or a quantity with
more than 3, becomes null and is counted, as the Rails side would refuse it anyway; a value is only
rewritten when the new form is exactly equal (`12.5` to `12.50`). A missing item amount is derived from
quantity times unit price only when that product has at most 2 decimal places. Everything is `Decimal`;
the model's JSON numbers are parsed as `Decimal`, never as floats.

### Constrained decoding, with validation and one repair pass behind it

mlx-vlm 0.8 builds a logits processor from a JSON schema with llguidance
(`structured.build_json_schema_logits_processor`). At each step it masks every token that would make the
answer invalid against the schema. It works with both Qwen models. What it guarantees: an answer that the
model finishes is syntactically valid JSON with exactly the schema's keys and types. What it does not
guarantee: that the answer is finished (the token limit can cut it off, for example when a model keeps
repeating an item), and anything about the values (a misread digit, a number in the wrong field, an
invented item).

So every answer is still parsed and checked. An answer that cannot be read is sent back to the model once,
with the problems found (field names and error types, never values), and the model answers again. When
the second answer fails too, the service answers 422 `ocr_parse_failed`.

### A parse failure is a permanent 422

The model is deterministic for the same photos, so retrying the same request would fail the same way.
The Rails job treats a 4xx as permanent and marks the receipt `failed` at once instead of retrying it five
times; the person then retries by hand (perhaps with better photos) or enters the receipt manually. A 5xx
would make the job retry pointlessly and keep the receipt in `processing` for minutes.

### Photos are scaled to 2048 pixels on the longer side

A 12-megapixel phone photo would be about 15,000 image tokens. At 2048 pixels a photo is about 4,000
tokens (Qwen2.5-VL) or 3,900 (Qwen3-VL), the print of a long receipt stays legible, and the model's peak
memory stayed around 7 GB. `MLX_OCR_IMAGE_MAX_SIDE` changes it.

### Evaluation scripts beside the service

`ml/evaluation/ocr_run.py` runs a backend in-process over the receipt set made by `tools/receipt_ingest`
(the same code and settings as the service) and writes a run folder; `ocr_fields.py` scores a run against
the receipts' QR codes. Model answers hold receipt content, so the run folder must be outside any git
repository, its files are private to the owner, and both scripts print aggregates only.

## Consequences

- Reading one receipt takes from about 10 seconds to over a minute (a long receipt in two photos took
  about 75 seconds). With one receipt at a time, a receipt queued behind another can wait longer than the
  Rails client's default OCR timeout of 120 seconds; the job's timeout and concurrency have to be sized
  from measured timings before receipts are uploaded in bulk.
- The service needs about 7 GB of memory while the model is loaded, on top of the Rails app.
- The fiscal number and the receipt number, printed small at the bottom of the receipt, are the fields
  read least reliably in the first trials; the QR code remains the better source for them when it can be
  read.
- An update to MLX, mlx-vlm or transformers can change the answers without any test noticing; it is
  tried on the receipt set before it is merged.
