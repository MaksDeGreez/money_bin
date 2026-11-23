# 0006. Transaction categoriser: a local text model, rule baselines and a time split

Status: accepted, extended by "Improving the model" and "Serving" below.

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
(`ml/categoriser/`), with scikit-learn, SciPy, joblib and PyYAML in their own dependency group that a
plain `uv sync` installs, so `bin/setup` and CI need nothing new.

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
used once, for the final numbers (see "Improving the model" for how that is enforced). Every fitted
part (vocabularies, IDF weights, the payee and MCC tables, the model) sees training rows only.

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
  baseline is chosen by validation macro-F1. Of its two forms, the exact binomial p-value is the one to
  quote, with the caveat below: the test assumes independent rows.
- At a coverage level, rows that tie in confidence with the last kept row are all kept (a baseline's
  confidences tie a lot), and the coverage actually reached is reported, so the curve does not depend
  on the order of the rows.
- Rows are not independent: the same payee recurs over nearby days. The row bootstrap is therefore
  probably too narrow, and McNemar's p-value probably too small. A second set of intervals resamples
  whole days, for every system and for the model's gain over the best baseline, as a sensitivity
  check; quote the wider of the two.

### Files and privacy

- The model file holds the vocabulary of the training texts, which includes payee names. It and the
  metrics JSON are written to a folder **outside the repository** (by default
  `~/Documents/money_bin_data/models/`, file mode 600); the command refuses an output folder inside a
  git repository. No model file and no metric derived from the real data is committed.
- The metrics JSON holds category names and numbers only: no payee, comment, description or amount.
- The console prints counts and metrics only; errors name a file, a line number and a key, never a value.
- The tests generate a small synthetic export with invented names and amounts.

## Improving the model

The first version beat the best rule baseline clearly on macro-F1, but its top-3 accuracy stayed below
the aim of 0.95; on test rows whose payee was seen in training the payee rule was more accurate than the
model, while the model won on rows with a new or missing payee; and the history changes character over
time (few training rows carry bank fields, most test rows do, and many test payees are new). **That test
result had been seen before the improvements below were designed.** Everything after it follows one
protocol, so that the final number is still an honest estimate.

### The protocol

- Every choice (which candidate, every hyper-parameter, every threshold and weight) is made on the
  validation slice only, with every part fitted on the rows before it (the fitting rows).
- The selection rule was written down before any candidate was scored, and is recorded in the selection
  JSON: eligible are the candidates whose validation top-3 accuracy is at least the lower end of the
  day-resampled 95% interval of the best validation top-3; among them the best validation macro-F1
  wins; candidates within 0.005 macro-F1 of it count as tied, and a tie goes to the simpler candidate
  (first: needs no neural encoder; then: the fewest parts beyond the first version). Inside a
  candidate, each setting is chosen by validation macro-F1, ties to the simpler setting.
- The test set is then scored **once**, for the single chosen configuration, together with the first
  version and the baselines refitted the same way, and the write-up says that the first version's test
  result had been seen.
- Nothing else looks at the test set. The code enforces it: the split keeps the test rows in a
  `SealedTest`, whose rows refuse to be read until the final step unseals them; the selection command
  (`categoriser.selection`) never unseals, writes no test metric (only the test set's size and first
  day, which the split defines) and is tested to be unchanged when every test label is shuffled. The
  scoring command (`categoriser.score`) is a separate, explicit step. It reads the selection file and
  checks that the export, the taxonomy, the split (test set included), the encoders, the selection
  format, the chosen configuration (the recorded rule must pick it from the recorded table) and the code
  (the same known git commit, no modified files, the same library versions) are the ones the selection
  used; it refits and loads the encoders before it opens the seal; it appends each unsealing to one
  record of test scores in the data folder, whatever the output folder, under a lock and before it reads
  a test row; and it refuses to score the same
  export a second time unless a reason is given, which it records. The metrics JSON records which
  configuration was scored, from which selection file (with its SHA-256) and when. What it cannot stop is
  a scoring of a different export (a re-export gets a new manifest); the record of test scores keeps
  that visible, since each entry names the test set's first day and size and the git commit.

### Refit on training + validation

The first version already did this: `C` and the best baseline were chosen with models fitted on the
fitting rows, and the final model was fitted on the whole training period, validation included. It stays
the rule for every candidate, because the validation period is the end of the history, the part most
like what comes next; leaving it out of the final fit would throw away the most relevant rows.

Values tuned on validation are kept **as numbers** in the refit, and each is defined so that it means
the same with more rows: `C` (the usual practice; with more rows the same `C` regularises slightly
less), the recency half-life in days counted back from the last training day, the class-weight power,
and the hybrid's parameters, which are in counts and shares of the payee's history. The hybrid's payee
and MCC tables are refitted on the whole training period together with the model, so at test time they
know the validation period's payees, exactly as the model's vocabulary does. What cannot be checked on
validation is the effect of the refit itself; it is a protocol choice, not a tuned one.

### The candidates, and why

- **Hybrid with the payee rule.** The first version's two regimes (rule better on known payees, model
  better on new ones) suggest combining them. `mix` blends the model's class probabilities with the
  payee's category shares, with a weight that grows with the number of times the payee was seen and with
  the purity of its history, and falls back to the MCC's shares for an unknown payee; `switch` lets the
  payee's history decide when it was seen often enough and consistently enough. Top-3 comes from the
  combined distribution. The rule tables come from the rows the model is fitted on, never from the rows
  it is scored on.
- **Recency.** The training history is mostly hand-entered and the recent history mostly bank feeds;
  weighting recent rows up (an exponential decay with a tuned half-life) lets the model follow the
  current kind of data without throwing the old rows away. A hard training window is the limit case of a
  short half-life and was not tried separately.
- **Sentence embeddings.** The texts mix Ukrainian, Russian and English, with transliterations and
  truncated bank strings; a multilingual sentence encoder may relate texts that share no n-gram (a new
  payee whose name says what it sells). Two local encoders were tried, `intfloat/multilingual-e5-base`
  and `intfloat/multilingual-e5-large` (mean pooling, the "query: " prefix), each alone with the one-hot
  fields and next to the TF-IDF features, under a logistic regression. They run on the Apple GPU with
  PyTorch from the local Hugging Face cache (`local_files_only`, pinned revisions, no remote code):
  transaction text is never sent to a hosted model. The vectors are cached outside the repository, keyed
  by the encoder and the text's hash. torch and transformers are an optional dependency group installed
  only on Apple silicon, so CI and the tests (which use a fake encoder) never need them.
  `jinaai/jina-embeddings-v3` was the first choice, but its remote code does not load with transformers
  5, which the local OCR backend's `mlx-vlm` requires; both groups must install together with a plain
  `uv sync`, so it was replaced before any candidate was scored.
- **Class-weight strength.** An error analysis of the first version on the validation slice (aggregates
  only) showed its balanced class weights pulling frequent payees with a mixed history, and rows with no
  text at all, towards rare categories. The weights are therefore also tried at a lower strength
  (`(n / (K * n_c)) ** power`, power 1 being "balanced"), and together with recency. The same analysis
  found that a finer amount bucket barely separated the categories of a payee, so the amount encoding
  was left as it is.

Each candidate is reported on validation with macro-F1, weighted F1, accuracy, top-3 accuracy and
precision by coverage, each with intervals by rows and by days, and its difference from the first
version; the selection JSON holds the whole table and every tuning grid.

### Limits of the improvement

- The test set is not virgin: its first-version result shaped which candidates were built. The
  candidates and the rule were fixed without any further look at it, and only the final configuration
  is scored, but the final number is one step removed from a fully blind estimate; the write-up says so.
- Many candidates and tuning grids are compared on one validation slice (15% of the training rows). The
  chosen candidate's validation score is therefore optimistic; the test score is the estimate to quote,
  and the gap between the two is itself informative.
- The hybrids get more tuning than the other candidates (a grid of 27 or 12 settings against 4 or 5),
  so their validation scores are the more optimistic ones; the tie margin and the preference for the
  simpler candidate lean against that, but do not remove it.
- The `switch` hybrid reports a confidence close to 1 on every row its payee rule decides, so its
  precision-by-coverage curve says little about how well it ranks its own confidence.
- The sentence vectors are computed once and cached; computing them again with an empty cache, on
  another device or with another torch version gives vectors that differ in the last digits, so a
  rerun of the selection from scratch is reproducible only approximately.
- The validation slice is the end of the training period, not the test period: a candidate that suits
  the shift up to the cut may suit the test period less well.
- The comparison with the first version on the test set is paired (the same rows, the same resamples,
  McNemar's test on the same rows), but both share the data's dependence between rows; the day-resampled
  intervals remain the ones to quote.

## Serving

The configuration chosen and scored above is what the app uses. It is not tuned further or swapped for
another here, and the test period stays as it was scored: nothing in serving reads its labels to make a
choice.

### The refit for serving

`python -m categoriser.serving` fits the chosen configuration, every tuned value kept as a number, on
**every labelled row of the export**, the test period's included. That is the usual practice once the
evaluation is done: the test period is the end of the history, the part most like the transactions to
come, and a served model that left it out would ignore the newest payees and the current kind of data (bank
feeds rather than hand-entered rows). The same argument made the scoring step refit on the validation slice.

The consequence is stated wherever the numbers appear: the served fit has **no test score of its own**. The
evaluated numbers belong to the configuration fitted on the training period; the artefact's metadata says
what the served fit was fitted on, names the selection and the scoring it follows, and carries no metric.
More rows of the same kind are expected to help, not hurt, but that is not measured. The recency weights
are counted back from the newest row of the fit, so the half-life means the same as in the evaluation.

The command reuses the training code (`fit_system` and the feature builders), and refuses an export, a
taxonomy, a split or a code version it cannot vouch for, as the scoring step does: another manifest hash,
another taxonomy, rows that no longer cut into the selection's periods, a selection that was never scored
(the record of test scores holds no entry of it), a file of `ml/categoriser/` that existed at the
selection's commit and differs now (a new file, such as the serving code itself, cannot change what the old
ones fit), other library versions, another encoder. A test proves that the served path (the app's raw
fields, through the serving code's row builder, into the training code's system) gives the same
probabilities as the training path for the same rows.

### The service and the app

- `POST /categorise/transaction` in the ML service (`ml/README.md`) answers the three best categories of
  each transaction with their probabilities, and whether the payee's (or the MCC's) history weighed in. The
  artefact and the sentence encoder load lazily, once; a missing artefact is a 501 for this endpoint only.
  It always runs on this machine; there is no hosted backend and no setting for one, and the app's client
  refuses to send transaction data to an `ML_SERVICE_URL` that is not on this machine (`MlClient::NotLocal`).
  The served path scales each sentence vector to unit length as the training's embedding cache does
  (`UnitEncoder`); without it the served features would differ from the fitted ones.
- **Category mapping.** The model's classes are the export's English group and category names. The app owns
  the slugs, so it sends its category list with every request (as the item categoriser does), and the
  service matches each class to the listed category of the same group and name. A class the list does not
  name is refused (422 `categories_mismatch`) rather than dropped or guessed: a category the app does not
  know can never come back silently, and a renamed category asks for a refit. The client refuses any slug it
  did not send. The alternative, mapping names to slugs in Rails, would put a second copy of the matching
  in the app and still need the same refusal.
- **Where suggestions live.** On the transaction line (`transaction_lines.suggested_category_id`,
  probability, runner-up, source, `suggestion_model_version`, time), filled by a job that scores the whole
  uncategorised queue in batches of 200 (a few thousand lines are a few dozen requests, never one per row)
  and refreshes every line whose suggestion came from another artefact. Computing them per page on demand
  would have been simpler, but a bulk action over thousands of rows needs them all at hand, and a stored
  suggestion can say which artefact made it.
- **Card slips** get their category from their merchant: the payee it matches and that payee's booked
  history first (`PayeeHistory`, the label memory's rule), the model otherwise (`docs/domain.md`, "Card slip
  suggestions").

### Self-training

The model learns from the ledger, and from now on the ledger holds categories that came from its own
suggestions. Fitted on them unmarked, a later model would be graded, and trained, on its own output: its
errors would come back as labels, and its confidence would grow on rows nobody looked at. So every category
set from the transactions list records its provenance on the line: `category_origin` `person` (chosen by
hand), `suggestion` (a suggestion taken one line at a time) or `bulk` (taken by a bulk acceptance), with the
taken suggestion's probability and artefact (`category_origin_probability`, `category_origin_model_version`;
a database check makes them required for a taken suggestion). A retraining should leave `suggestion` and
`bulk` lines out, or at least count and evaluate them apart; the training reads the previous app's history
export, which has no such rows; an export of this app's ledger for a retraining must carry the column. Limits: a person who chooses the suggested category in
the picker under an uncategorised line is recorded as taking the suggestion (it was on screen, so the label
is not independent of it); a correction made with "Change" (any line, categorised or not, where no suggestion
is shown) is always `person` with no probability or artefact, so a `person` label is one a person chose, and
a person overriding a taken suggestion turns it into one; a category set elsewhere (a receipt, manual entry,
the import) has no origin.

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

- `ml/` gains scikit-learn, SciPy, joblib, PyYAML and their dependencies (NumPy among them); the HTTP
  service imports them lazily, for `/categorise/transaction` only. The `embeddings` group (torch and transformers 5, which the `mlx` group
  needs too) installs on macOS on Apple silicon only, through platform markers, so Linux CI resolves and
  installs without it.
- A trained model is a file on the owner's machine, named by the export's manifest hash and the time of
  the run. The first version's one-step command (`categoriser.train`, which fitted and scored in one go)
  is replaced by the two steps above; its configuration is the `tfidf` candidate, and the final step
  reproduces its test numbers exactly for the same seed. Serving it is a separate artefact
  (`<stamp>.serving.joblib`, see "Serving"), in the same private folder; the HTTP service imports
  scikit-learn only when a transaction is first categorised, and the sentence encoder only for its first
  `POST`.
