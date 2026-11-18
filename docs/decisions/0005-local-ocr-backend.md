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
`mlx-community/Qwen3-VL-8B-Instruct-4bit` both work. The default is Qwen3-VL, chosen from measurements
on the receipt set ("The default model is Qwen3-VL", below). All the photos of a receipt go
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
on the worker thread, so the stub backend and every test work without it. Dependabot keeps MLX, mlx-vlm,
transformers and llguidance out of its grouped updates: each comes as its own pull request, because CI
cannot run the model and an update has to be tried on the Mac.

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

### The default model is Qwen3-VL (measured on 20 receipts)

Both models read the same 20 receipts with `ocr_run`, once from the full photos and once from the
cropped ones, and `ocr_fields` scored the answers against the receipts' QR codes. The receipts all have
a readable tax-service QR code with every field, come from five photo batches (18 in one photo, 2 in
two), and none of them was looked at while the prompt was written. Photos were scaled to 2048 pixels,
with constrained decoding on. Shares are of the 20 receipts; a receipt that was not read counts as wrong.

| Model | Photos | Read | Date | Time | Total | Register no. | Receipt no. | Items sum to the total | Kind | Median | Mean | 90th pct. |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen2.5-VL-7B | full | 16 | 65% | 70% | 70% | 20% | 10% | 20% | 75% | 32.5 s | 68.5 s | 183.5 s |
| Qwen2.5-VL-7B | cropped | 18 | 75% | 75% | 80% | 10% | 10% | 10% | 80% | 20.2 s | 39.3 s | 88.3 s |
| Qwen3-VL-8B | full | 20 | 85% | 85% | 100% | 70% | 25% | 45% | 95% | 30.6 s | 34.6 s | 49.0 s |
| Qwen3-VL-8B | cropped | 19 | 80% | 80% | 95% | 35% | 25% | 35% | 80% | 19.8 s | 30.1 s | 42.1 s |

"Read" is the number of receipts with a valid answer; the others ended as a parse failure after the
repair pass, and each of those took three to four minutes. Peak memory was 7.0 to 7.9 GB. The machine
was doing other work during the runs, so the times are upper bounds.

- **Qwen3-VL-8B is the default.** It read every receipt from the full photos, got every total right,
  and was better on every field; its slowest receipts are several times faster than Qwen2.5-VL's,
  because it did not run into the repair pass.
- **Full photos stay the default input.** Cropping makes reading about a third faster and costs
  accuracy: the fiscal numbers and the receipt kind are read worse, and one receipt was not read at all.
  The crop is made by a detector that can cut into the print, and the numbers sit at the edges of the
  receipt. The comparison stays available as an evaluation run (`--crops`).
- **Items are the weak part.** There is no item ground truth yet, so item quality was measured by a
  stricter stand-in: the share of receipts whose item amounts sum exactly to the QR code's total. A
  local model was to be the main reader at a median of at most 60 seconds per receipt and at least 60%
  on this measure. The time is met with room to spare; the item measure is not (45%). For Qwen3-VL on
  full photos, of the 20 receipts 9 summed exactly, 3 were within 5% of the total, 4 came out lower by
  more than that (items missing), 3 higher (items repeated or extra lines read as items) and 1 had no
  items; the printed total itself was read correctly on all 20. One wrong item fails a whole receipt on
  this measure, so it is harsher than an item-level score; that score is measured once item ground
  truth exists (docs/decisions/0010-receipt-ground-truth.md).
- The register number is read right on 70% of receipts and the receipt number on 25%, so the QR code
  remains the source for both whenever it can be read.

Which backend reads receipts by default in the app, local or hosted, is decided separately; this record
only settles the local model.

### Evaluation scripts beside the service

`ml/evaluation/ocr_run.py` runs a backend in-process over the receipt set made by `tools/receipt_ingest`
(the same code and settings as the service) and writes a run folder; `ocr_fields.py` scores a run against
the receipts' QR codes. Model answers hold receipt content, so the run folder must be outside any git
repository, its files are private to the owner, and both scripts print aggregates only.

## Consequences

- Reading one receipt takes from about 10 seconds to over a minute (a long receipt in two photos took
  about 75 seconds), and a receipt whose first answer needs the repair pass takes about twice as long. A
  single receipt can therefore exceed the Rails client's default OCR timeout of 120 seconds, and with one
  receipt at a time a queued receipt waits for the ones ahead of it. A request whose client has timed
  out is not cancelled: its generation keeps the worker busy, so the job's retry queues behind it. The
  job's timeout and concurrency have to be sized from measured timings before receipts are uploaded in
  bulk; until then `.env.example` suggests a larger `ML_SERVICE_OCR_TIMEOUT` for the mlx backend.
- At shutdown the model is dropped and the worker thread's MLX streams are released on that thread
  (as mlx-vlm's own server does) before the thread stops.
- The service needs about 7 GB of memory while the model is loaded, on top of the Rails app.
- The fiscal number and the receipt number, printed small at the bottom of the receipt, are the fields
  read least reliably (see the measurements above); the QR code remains the better source for them when
  it can be read.
- An update to MLX, mlx-vlm, transformers or llguidance can change the answers without any test
  noticing; it is tried on the receipt set before it is merged.
- `PROMPT_VERSION` covers the prompt and the schema, not the post-processing code. An evaluation run
  records the git commit as well, so runs stay comparable; an answer stored by the app names the model
  and the prompt only.
