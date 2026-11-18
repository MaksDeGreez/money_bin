# 0015. Item categoriser: label memory first, then a zero-shot model with its own confidence

Status: accepted.

## Context

Every receipt item needs a category before the receipt is booked. The review form already shows an item's
suggestion with a confidence and can take every suggestion above a threshold in one click; nothing filled
them. The aim: the owner accepts confident suggestions in bulk and looks only at the doubtful ones. For the
evaluation that means at least 70% of items auto-acceptable at 95% precision or better.

A receipt item is a short, abbreviated Ukrainian product name as printed ("Мол2,5%900г", "Хл400Батон"), often
run together, with a size stuck to it and brands in Latin letters. There are no labelled items yet: the owner
starts labelling once this lands. The category list (the app's taxonomy, 39 categories in 21 groups) is owned
by the Rails app and may change.

The owner decided: the categoriser is zero-shot over the categories (names and one-line descriptions) and
answers with the category slug only; it runs locally and, for comparison, hosted. A hosted model gets only
item names (and, for OCR, receipt images), through zero-data-retention endpoints. The confidence must mean
something: token probabilities where the backend gives them, otherwise a calibrated score. A label memory is
both a baseline and a product feature. A model trained on the collected labels comes later.

## Decision

### Three sources, in order of trust

1. **The label memory** (`LabelMemory`): what the owner already called items with the same normalised name
   on other receipts. Exact repeats are common (the same shop prints the same name), and the owner's own
   earlier choice is the best evidence there is.
2. **A local zero-shot model** for everything else, with the shop's name as context.
3. **The same prompt on a hosted model**, for comparison in the evaluation (and usable in the app with
   `CATEGORISE_BACKEND=openrouter`).

The memory's rule (strict majority of the labels under a key; confidence (k + 1) / (n + 1.25), a Beta
posterior mean from a weak prior that a name keeps its category) and the name key (NFKC, lower case,
Latin look-alike letters folded to Cyrillic, everything but letters and digits dropped, sizes kept) are in
`docs/domain.md`, "Label memory". The key is computed in one place in the app (`ItemName.key`, stored as an
indexed column) and mirrored for the offline runs in Python; both test against one shared file of cases.

### The category list travels with every request

The request to `/categorise` carries the candidate categories (slug, name, description, group). The other
option, a taxonomy file the app writes and the service reads, needs a sync step that can be forgotten and a
version check on both sides. With the list in the request the service never builds or stores a slug, a
taxonomy change reaches it with the next request, and a mismatch cannot be ignored: the answer may only name
slugs from the request (the service refuses to return anything else, and the Rails client refuses an answer
that does). The cost is a few kilobytes per request. The candidates are every category except Uncategorised
("not categorised yet") and Adjustments (neither spending nor income): 37.

### Items of one receipt in one call

The neighbours disambiguate: on a pharmacy's receipt an unclear abbreviation is a medicine, next to cat food
it is for the pet. So one call per receipt, items numbered, the answer a JSON object of item number to slug.
The shop's name helps a lot: on the sanity set the local model got 39 of 43 with it and 32 without.

### Local confidence: every slug scored, not one path decoded

Greedy constrained decoding (mlx-vlm's JSON-schema logits processor, used for OCR) gives the probability of
the path the model took and nothing about the runner-up, and a slug spans several tokens, so the first
token's probability is not the category's. Instead every listed slug is scored: the slugs' token sequences
form a trie, the model's logits at each point where slugs part ways are renormalised over the allowed tokens,
and a slug's probability is the product along its path. The result is the model's own distribution over the
listed categories (it adds up to 1), the same distribution constrained decoding samples from. Only the parting
points cost a model call; the KV cache is rewound after each branch, and the fixed instructions stay in the
cache between receipts. The best slug is written into the answer before the next item is scored, as a normal
generation would.

Its limits: the score counts the tokeniser's own spelling of each slug only; a model can be confidently wrong
(two of the four sanity-set errors had probability above 0.99); and the probability is not a precision. Hence
calibration.

### Hosted confidence: token log-probabilities where they exist

A hosted endpoint gives at best the log-probabilities of the tokens it wrote and a few alternatives. The
chosen slug's score is the product over its tokens; an alternative token that can only lead to one other
listed slug credits that slug. Where an endpoint returns none, the answer gets a fixed 0.5, marked
`score_kind: fixed`: a marker below any sensible threshold, which a calibration fitted on such answers turns
into the model's measured precision. Which endpoints return log-probabilities is read from OpenRouter's
public endpoint list (`supported_parameters`), and routing prefers those that give both structured output and
log-probabilities.

### Calibration is a separate, optional step

An isotonic regression of "the best candidate was right" on its raw score, fitted from a run over labelled
items and stored outside the repository with the categoriser, model, prompt version and score kind it is
valid for. The service applies it only to answers of exactly that kind and says so (`calibrated`). Isotonic
rather than temperature scaling: it is monotone without assuming a shape, and the label memory's and a
hosted model's scores are not softmax outputs a temperature would fit. It needs a few hundred labels to be
worth much; until then the service answers with raw scores and `calibrated: false`, and the form's
threshold is a threshold on raw probability.

### One model for OCR and categorisation

Measured on the sanity set (43 invented items), M2 Max, 37 categories:

| Model | Right | Seconds per item | Memory | Wrong at ≥ 0.9 |
| --- | --- | --- | --- | --- |
| Qwen3-VL-8B (the OCR model) | 39 | 0.6 to 0.7 | shared (6.7 GB peak) | 3 |
| Qwen3-4B-Instruct-2507 (text) | 34 | 0.35 | +3.2 GB | 9 |

The OCR model wins on accuracy and on confident errors and costs no memory, so `MLX_CATEGORISE_MODEL`
defaults to it and the one loaded model does both jobs. Everything MLX runs on one worker thread
(`app/backends/mlx_worker.py`), shared by the OCR backend and the categoriser, so they never use MLX at once;
loaded models are shared by id. The text model stays possible through the setting.

### Where the work runs

In `ReceiptOcrJob`, right after `ApplyOcr`: the suggestions arrive behind the items, not behind hundreds of
queued reads (a second job on the OCR queue would wait for all of them). "Suggest categories again" is its
own job on a queue the OCR capsule works first (unweighted Sidekiq queues are strictly ordered). A
categoriser failure never fails the receipt; it is recorded and shown.

### Provenance

Each item records `suggested_by` (`memory` or `model`). The receipt records `categoriser_model_name` for the
ground truth's pre-fill rule: the model's name when any item carries its suggestion, `label-memory` when the
memory filled them all. A mix names the model, so the model's test set loses the receipt and the memory keeps
it (its score there is slightly optimistic; an accepted limit). Never empty while suggestions are on the
form, so no receipt becomes `source:unknown` and lost to every categoriser.

### What goes to a hosted model, and what never does

To a hosted categoriser: the fixed instructions, the category list (the app's taxonomy, not personal) and the
receipt's item names, numbered. Never the shop's name, an amount, a date, an id, a payee, a note or anything
of the ledger. The hosted request is built by a function that takes the categories and the item texts and
nothing else, and the tests send a shop name and check that it appears nowhere in what is sent. The privacy
machinery is the hosted OCR backend's (`docs/decisions/0012-hosted-ocr-backend.md`), not a copy of it: the
same client reads the zero-retention catalogue, sets the fixed provider preferences, checks the provider of
every answer, and halts all hosted calls (OCR and categorisation) after a wrong one until the service
restarts.

### Suggestions can be switched off, for fair test labels

A categoriser is not evaluated on labels it pre-filled, the label memory included. `CATEGORISE_BACKEND=off`
switches every suggestion off, in the app (which reads the same setting) and in the service, so the owner
can label receipts that nothing pre-filled; "Suggest categories again" fills them later. One setting rather
than two, so the app and the service cannot disagree about whether suggestions are on.

### A narrow interface and a reusable hand-over

The categoriser interface is one call (`categorise(items, taxonomy, context) -> candidates with scores`,
plus accounting), and the category list is read by one parser for both a request and the exported file
(`ml/app/categorise/taxonomy.py`), so offline scripts and other kinds of categoriser (a decision model
returning a probability per category, a combiner of several runs) use exactly what the app sends and plug
in as one more `CATEGORISE_BACKEND` value.

### What still reaches a hosted categoriser, within the rule

The category names and descriptions are the app's taxonomy, so a description the owner edits leaves the
machine with every hosted request; and a line OCR misread as an item (a cashier's name, a loyalty number)
is an "item name" and goes too. Both are inside the owner's rule (item names only, zero retention), and
worth knowing before switching categorisation to a hosted model.

## Consequences

- The owner can take confident suggestions in bulk from the first receipt; with labels, the memory takes
  over the repeats.
- The evaluation can compare the memory, the local and the hosted model on the same labelled items, with
  cost and seconds per item (`ml/evaluation/item_categories_run.py`); scoring is the harness's.
- A card slip has no items; its own suggestion comes from its payee's history or the transaction categoriser
  (`docs/domain.md`, "Card slip suggestions").
- A model trained on the collected labels (nearest neighbours or logistic regression on embeddings) fits as
  one more categoriser behind the same request, or between the memory and the zero-shot model; nothing here
  stands in its way.
- The memory's confidence rule and the zero-shot probabilities are both raw until measured; the calibration
  command exists so the measurement changes a number, not code.
