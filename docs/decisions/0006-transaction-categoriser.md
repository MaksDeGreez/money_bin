# 0006. Transaction categoriser: a local text model, rule baselines and a time split

Status: accepted. Training and evaluation only; serving the model and using it in the app come later.

## Context

Most transactions arrive from bank feeds with a payee, a bank description, a merchant name and an MCC,
but without a category. The ledger needs a suggestion for each, with a confidence, so that a person (or
the agent) confirms the easy ones quickly and looks harder at the rest.

The training data is the history the previous app kept: about ten years of transactions that a person
categorised, brought in through the export described in [`import-contract.md`](../import-contract.md).
The history is not uniform. The early years are mostly typed by hand (a payee, sometimes a comment, no
bank fields); the recent years are mostly bank feeds with an MCC and a bank description. The numbers
from this work go into a thesis, so the evaluation has to say exactly what it measures.

## Decision

### Where it runs

The categoriser always runs on the owner's machine. Transaction data is never sent to a hosted model,
for training or for a suggestion. The code is a package of the existing ML project
(`ml/categoriser/`), with scikit-learn and joblib in their own dependency group that a plain `uv sync`
installs, so `bin/setup` and CI need nothing new.

### The rows

- One row per transaction. Transfer legs are left out: moving money between own accounts has no
  category.
- A split transaction (several lines) is represented by its **largest line by absolute amount**, and on
  a tie by the first of the tied lines in the export's order. A suggestion is one category per
  transaction, and the largest line is the one that best says what the money was for. The metrics JSON
  counts how many rows were split and how many of those had a tie, so the effect of the rule is visible.
- The label is the chosen line's category as the export names it: its English group and category
  names. A line without a category, with an unmapped category, with names that are not in the app's
  taxonomy (`db/seeds/taxonomy.yml`), or mapped to Uncategorised has no label; the row is dropped and
  counted. The importer sends all of these lines to Uncategorised, and a model must never suggest a
  category the app cannot store.
- The features come from the transaction alone (payee, comment, bank description, merchant, MCC, the
  amount's sign and size bucket, the account kind), never from its lines, because a new bank transaction
  has no lines yet.

### The model and the baselines

The model is TF-IDF over the joined text (word 1- and 2-grams, character 2- to 5-grams inside word
boundaries) plus one-hot fields (MCC, sign, amount bucket per currency, account kind, the payee as a
whole), into a multinomial logistic regression with balanced class weights.

- It trains in seconds on a laptop, needs no GPU and no download, and gives probabilities, so a
  confidence threshold can trade coverage for precision.
- Character n-grams cope with what the texts are: Ukrainian, Russian and English mixed, transliterated
  names, truncated bank descriptions, typos.
- Balanced class weights stop the frequent categories (groceries) from drowning the rare ones; macro-F1
  is the main metric for the same reason.
- It is a strong, well understood baseline for short-text classification. A heavier model (gradient
  boosting, a fine-tuned transformer, an LLM) has to beat it on the same split to be worth its cost.

The model must beat two rule baselines, fitted on the same training rows:

- **majority**: always the most frequent category. It shows what a metric gives for free.
- **payee → MCC → majority**: the most frequent category of the payee in training; for an unknown
  payee, that of the MCC; otherwise the majority. This is what a hand-written rule set does, and it is
  the bar that matters.

### The split

The rows are ordered by date after the drops above. The last 20% are the **test set**, and every calendar
day lies entirely on one side, so no day is split between training and test. The end of the training
period (15% of its rows, whole days again) is a **validation slice**: the regularisation strength of the
model is chosen on it, and so is the "best baseline" that the model is compared with. The test set is
used once, for the final numbers. Every fitted part (vocabularies, IDF weights, the payee and MCC tables,
the model) sees training rows only.

A random split would put transactions of the same payee from the same week on both sides and measure
memory, not prediction. The time split measures the real question: given the past, how well are new
transactions categorised.

What it does **not** measure: the test period differs from the training period. Training rows are mostly
hand-entered, test rows mostly bank feeds, and many test payees were never seen in training. The test
numbers are therefore those of a model meeting a new kind of data, not of a model in a steady state.
The metrics JSON shows this instead of hiding it: the share of rows with bank fields, with an MCC, and
with a payee seen in training, for each side; and the headline metrics per segment (rows with bank
fields versus without, rows whose payee was seen in training versus not).

### The evaluation

The metrics JSON holds, for each baseline and the model: macro-F1 (the main metric), weighted F1,
accuracy, top-3 accuracy, each with a 95% bootstrap interval (1,000 resamples of the test rows, fixed
seed, the same resamples for every system so differences are paired), the interval of the model's gain
over the best baseline, precision when only the most confident rows are kept (by coverage level and by
confidence threshold), McNemar's test between the model and the best baseline, per-category support
and F1, and the same headline metrics per segment. It also records the export's manifest SHA-256, the
taxonomy's SHA-256, the split dates, the row counts, the library versions, the git commit and the seed,
so every number names the data and the code it came from.

- Macro-F1 is scikit-learn's default definition: the mean over every category that is a true label or
  a top-1 prediction, so a prediction of a category absent from the test rows costs its F1 of 0.
- McNemar's test compares top-1 correctness, so it tests a difference in accuracy, while the best
  baseline is chosen by validation macro-F1. The exact binomial p-value is the one to quote.
- At a coverage level, rows that tie in confidence with the last kept row are all kept (a baseline's
  confidences tie a lot), and the coverage actually reached is reported, so the curve does not depend
  on the order of the rows.
- Rows are not independent: the same payee recurs over nearby days. The row bootstrap is therefore
  probably too narrow, and a second set of intervals resamples whole days as a sensitivity check.

### Files and privacy

- The model file holds the vocabulary of the training texts, which includes payee names. It and the
  metrics JSON are written to a folder **outside the repository** (by default
  `~/Documents/money_bin_data/models/`, file mode 600); the command refuses an output folder inside a
  git repository. No model file and no metric derived from the real data is committed.
- The metrics JSON holds category names and numbers only: no payee, comment, description or amount.
- The console prints counts and metrics only; errors name a file, a line number and a key, never a value.
- The tests generate a small synthetic export with invented names and amounts.

## Limitations

- **Some recent labels were assigned by rules, not by hand.** Part of the recent history was categorised
  in bulk by rules on the MCC or the payee, and the export does not say which rows. A model (or a
  baseline) that learns such a rule is then graded against the rule's own output, so both the MCC
  baseline and the model may look better on those rows than they would on labels a person chose. The
  numbers are reported as they are; no attempt is made to guess which rows were labelled by rule.
- The largest-line rule loses the smaller lines of a split, and a tie is broken by line order, not by
  meaning.
- The label set is the one the export gives today; a category that occurs only in the test period
  cannot be learnt, and the metrics JSON lists any such category.
- One run gives one split. The intervals describe the uncertainty of the test sample, not that of the
  choice of cut date.
- The validation slice is small for the number of categories, so the choice of `C` is noisy; the
  validation score of every tried value is in the metrics JSON.

## Consequences

- `ml/` gains scikit-learn, joblib and their dependencies (NumPy, SciPy); the HTTP service does not
  import them yet.
- A trained model is a file on the owner's machine, named by the export's manifest hash and the time of
  the run. Serving it over HTTP and showing suggestions in the app are separate changes; they read the
  model file from the same private folder.
