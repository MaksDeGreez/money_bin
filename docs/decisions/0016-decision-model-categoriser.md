# 0016. A decision model as an item categoriser, as a checker of other models, and combined with them

Status: accepted.

## Context

Receipt items get category suggestions from the label memory and a zero-shot language model
(`0015-item-categoriser.md`). The aim stays: at least 70% of items auto-accepted at 95% precision or better.
A language model answers with text: its confidence has to be dug out of logits (locally) or token
log-probabilities (hosted, where an endpoint returns them at all), and it is not a precision until calibrated.

OpenRouter also offers **decision models**: models that do not write text. One takes a `state` and named,
typed questions and returns, per question, a typed answer: for a `choice` question the chosen option and a
probability for every option, for a `noul` question the probability that a proposition holds. The owner asked
to try TypeSafe's Jev (`typesafe/jev-1.14`), the first of about forty such models behind the same Decisions API
(`POST /api/alpha/decisions`). Its documentation (read on 2026-11-18): all questions of a request are answered
in one pass; input costs $0.042 per million tokens and output is free; requests over about 32,000 bytes of text
switch to a slower, less accurate long-input mode; probabilities vary by a few hundredths between identical
calls; they are claimed to be calibrated in aggregate, with no published figures; the weights and the method
are not published. `~typesafe/jev-latest` is a moving alias.

There are no labelled items yet, so nothing can be scored on real labels in this change.

## Decision

### A decision model is a categoriser like the others: `CATEGORISE_BACKEND=decisions`

A closed list of categories is exactly a `choice` question: the answer cannot name a category outside the list,
needs no parsing or repair, and comes with a probability for every category, which is the confidence the
review form needs. So it is one more categoriser behind the narrow interface of `0015`
(`ml/app/categorise/decisions.py`, `score_kind: decision_probability`), selected by `CATEGORISE_BACKEND`, with
its model in `DECISIONS_MODEL` (no default; the model id is a setting because the other decision models share
the API). The service's contract, the Rails client and the review form are unchanged.

### Flat by default; two-stage measured

- **flat**: one `choice` question per item over the 37 candidate categories, each option labelled "Group /
  Name" and described by its description.
- **two-stage**: a `choice` over the 19 groups (each described by its categories), then a `choice` within the
  two most likely groups of more than one category (the second only above 0.05), multiplying the
  probabilities; a category alone in its group needs no second question.

Two-stage sends shorter option lists but asks about twice as many questions. On the invented sanity set
(98 items, below) flat was right more often (96 against 92 of 98) for the same cost: the second stage loses
items whose group is right but whose shop context is needed inside it (pet shampoo in a pet shop went to
household supplies). Flat is the default; two-stage stays a setting for the real evaluation.

### Each item its own question, a receipt's items in one request

The question key is never shown to the model, so every question must carry its whole option text (about 3,000
bytes for 37 categories), and the cost grows with the number of questions, not with batching. What batching
saves is the state: with every item's question in one request, the receipt's item names are sent once. The
request is cut at `DECISIONS_MAX_QUESTIONS` (16) or 24,000 bytes, whichever comes first, well below the
long-input threshold; with flat that is about 4 to 7 items per request. Measured: 1,126 input tokens per item
batched against 1,442 one item per request, 0.09 against 0.28 seconds per item, the same accuracy.

### The receipt is the context; the shop's name is not

The `state` holds the item names of the receipt (`line_1`, `line_2`, ...), and each question names its line:
the neighbours show what kind of shop it was (a pouch among pet food is cat food). The shop's name is never
sent to a hosted model (`0015`); the receipt's own lines recover much of what it gave the local model. Items
sent alone: 88 of 98 right; with their receipt's lines: 96.

In offline runs a label memory can add **examples**: similar item names a person labelled on earlier receipts,
each with its category's label (`--examples K`, `LabelMemory.similar`: character-trigram similarity of the
name keys). Earlier receipts only, as for the memory itself, so no item is shown its own label. The service
does not fill them yet (the app would have to send them).

### Verification as a source of confidence

A local model's answer has a confidence of its own making. A decision model can check it: one `noul` question
per proposed category ("does the product in `line_3` belong to the spending category 'Household & shopping /
Pets'? That category is: ...") gives a probability from an independent model, which can serve as that
proposal's confidence or as a feature of a combination, and sends doubtful items to review. It is `verify`
(`DecisionsCategoriser.verify`, `item_categories_run --verify RUN_DIR`), offline for now. On the sanity set,
re-ranking Jev's own flat candidates by verification made them worse (90 of 98) and no better calibrated:
verification is for another model's answers, and the labelled items will show whether it helps there.

### Combinations are runs too, fitted without leakage

`evaluation/item_categories_combine.py` turns two or more run folders over the same items into one run folder
of the same format, so a combination is scored exactly like a single method: a fixed **cascade** (the first
method whose best score reaches its threshold decides, for example the label memory when confident, else the
model); a **weighted average** of the per-category scores; and a **learned** combination, a multinomial
logistic regression on the methods' per-category scores side by side.

The learned combination is cross-validated **by receipt and forward in time**: the receipts with usable
labels, in time order, are cut into consecutive blocks, and each block is scored by a model fitted on the
blocks before it only. Two leaks are closed. Items of one receipt share a shop and often a category; folds that
split a receipt would let the fit learn "this receipt is groceries" and report a precision the app will never
see. And with the label memory or labelled examples, a later receipt's scores already contain earlier
receipts' labels, so even folds grouped by receipt would let a held-out label back in through a later
receipt fitted on. Training only on the past is also what the app does. The
first block, with no past, gets the plain average; items not scored get a fit on every usable label.

The pre-fill rule applies: an item whose labels were chosen with one of the combined categorisers' suggestions
on screen (`categories_prefilled_by`) is neither fitted on nor counted. Every run's `run.json` lists the
categorisers that shaped it: its model; the label memory when it answered first or supplied examples; and for a
verification run the categorisers of the run it checked, since its candidates are that run's suggestions,
re-scored. The combined run lists them all, so a scorer applies the same rule, and the calibration fit reads
the same list. `run.json` also reports how
often the methods agree and the precision of "all agree", the simplest auto-accept rule.

### What is sent, and what never is

Owner's rule, enforced in code and tests: only item names go to a hosted model for categorisation, with the
public category names and descriptions and fixed instructions; labelled examples are item names too. No shop
name, amount, quantity, price, date, receipt or item id, user identifier, attribution header or cookie. The
request body is `model`, `state`, `questions` and `provider` and nothing else; a test builds a request from a
ground-truth record and asserts the exact body. The key comes only from `OPENROUTER_API_KEY` and appears in no
log, error or run file. Transactions, payees and bank descriptions never go to any hosted model: this client is
not for the transaction categoriser.

**Zero retention** is the hosted OCR backend's rule (`0012`), in the same code (`OpenRouterClient` with
`decisions=True`): the model must be listed as a decision model and have endpoints on OpenRouter's
zero-data-retention list without Safety Retention; every request names them in `provider.only` with
`zdr: true` and `data_collection: "deny"`, none of it configurable; nothing is sent when the lists cannot be
read; an answer from a provider outside the list halts every hosted call until the service restarts. On
2026-11-18 `typesafe/jev-1.14` had one such endpoint (provider TypeSafe, `safety_retention: false`), and the
moving alias had none of its own, so it is refused: a run always names a dated, concrete model, and records
the dated id each answer reports.

### Answers are checked, asked once, and kept

Every answer is checked against its question: a missing answer, an answer to a question not asked, an option
not offered, a missing or extra probability, a value outside 0..1 or probabilities not adding up to 1 (within
0.02) are errors, never dropped or guessed. A refusal is an answer; since the service promises a candidate for
every item, a refused item fails its receipt (422), and the app shows no suggestion. Shape errors are 5xx,
so the app retries them: an answer varies between calls and a retry costs about $0.0001. The prompt version
names the mode (strategy, context, whether examples were shown, verification), so a calibration fitted on one
mode never applies to another. Because answers vary
slightly between identical calls, each item is asked once and the answer kept: no retrying until two calls
agree, which would bias the scores towards the stable ones.

## Trial on invented items

The sanity set (`ml/tests/fixtures/item_sanity_set.json`) grew from 43 to 98 invented items in 21 invented
receipts, with some items that need their receipt (a mouse in an electronics shop, a pouch in a pet shop).
With `typesafe/jev-1.14` and the 37 categories, no shop name:

| Variant | Right (top 1) | Of the first 43 | Top 3 | Best ≥ 0.9 but wrong | Seconds per item | Dollars per 1,000 items |
| --- | --- | --- | --- | --- | --- | --- |
| flat, receipt context | 96 of 98 | 43 | 98 | 0 | 0.09 | 0.047 |
| flat, one item per request | 95 of 98 | 43 | 98 | 0 | 0.28 | 0.061 |
| flat, each item alone | 88 of 98 | 40 | 91 | 1 | 0.29 | 0.054 |
| two-stage, receipt context | 92 of 98 | 42 | 98 | 0 | 0.12 | 0.049 |

For comparison (`0015`): the local Qwen3-VL-8B got 39 of the first 43 with the shop's name and 32 without it.
Of flat's 98 answers, 80 had a top score of 0.95 or more and 84 of 0.9 or more, all right; its two misses (a sports bottle, a pot of
tea in a cafe) scored 0.62 to 0.66. The whole trial, every variant above plus verification, cost about four US
cents. These items are invented and obvious on purpose: the numbers show the model works and how the variants
compare, not how well it will do on real receipts.

## How it will be judged

On the labelled items, with the same table as every other categoriser (the evaluation harness, in its own
pull request): macro-F1,
top-3 accuracy, the share auto-accepted at 95% precision, calibration (reliability and its error), seconds and
dollars per 1,000 items; alone, with the label memory first and with examples, as the verifier of the local
model's answers, and in the cascade, average and learned combinations with the local model. The commands are
in `ml/README.md`, "Evaluating the item categoriser".

## Limits

- A hosted, proprietary model: no published weights, method or calibration figures; the provider can change it.
  A run records the dated id each answer reports, and the moving alias is refused.
- Answers vary by a few hundredths between identical calls: thresholds near a score boundary are not exact,
  and the run file keeps scores to six decimal places of a number that is only good to about two.
- The Decisions API is marked alpha; its shape may change. The client checks every answer, so a change fails
  loudly instead of passing wrong scores.
- Item names leave the machine, under the rule above. A refusal fails the whole receipt.
- Routing rests on OpenRouter honouring `provider.only` and `zdr` on the alpha Decisions API. A request with
  them was accepted, and every answer of the trial named the listed provider (TypeSafe), which the client
  checks; an answer from anywhere else stops every hosted call, but only after that request was sent.
- The learned combination has a weight per run, category and class (about 2,800 for two runs and 37
  categories): it needs a few hundred labelled items before it beats the simpler methods, and its settings
  (`--c`, `--folds`) must not be tuned on the figures it then reports.

## Consequences

- `CATEGORISE_BACKEND=decisions` works in the service now; the app needs no change to use it.
- Follow-up, not in this change: verification inside the app (the app would send the local model's answer for
  checking, or the service would chain two categorisers), and examples from the app's label memory in a
  request; both need a change to the Rails client and the `/categorise` contract.
