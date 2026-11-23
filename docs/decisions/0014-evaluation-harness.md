# 0014. Evaluation harness: offline, from files, aggregates only in the repository

Status: accepted.

## Context

The capstone's results chapter reports how well models read receipts (local Qwen2.5-VL and Qwen3-VL, a
hosted model, full and cropped photos) and how well items are categorised. Those numbers must be
reproducible by one command, and comparing one more model or setting must be a new run, not new code.
The inputs exist as files outside the repository: the receipt set of `tools/receipt_ingest`
(`receipts.jsonl`, with the QR fields), the OCR run folders of `ml/evaluation/ocr_run.py`
(`run.json` + `predictions.jsonl`), and the ground-truth export of the Rails app (`ground_truth.jsonl`,
`docs/decisions/0010-receipt-ground-truth.md`). `evaluation.ocr_fields` scored one run against the QR
codes; it had no item metrics, no intervals, no comparisons and no output fit for the repository.

## Decision

### Offline, from files: `make eval`

`ml/evaluation/harness.py`, run by `make eval` from the repository root, reads the three inputs and
nothing else: never the app's database, never a model, never the network. Files make the evaluation
independent of the app's state (a review that changes a receipt cannot change a result), easy to
archive with the chapter, and runnable on any machine with the files. The default folders are under
`~/Documents/money_bin_data/` (`receipts/`, `runs/`, `ground_truth/`, where the export is told to
write); `make eval-check` validates the inputs and prints what would be scored without writing. Runs
are found at any depth of the runs folder and carry a `task` (`ocr`, the default for runs written
before the key existed, or `item_categories`). The item categoriser writes its runs in a format this
harness defines (`ml/README.md`, "The item-category run format"): one line per ground-truth item, by
its position in a named ground-truth record.

Rejected: a Rails task that reads the database (results would move with the ledger and need the app
running); a notebook (not one command, not deterministic, invites per-receipt output).

### Item matching: one-to-one, name and amount

Field accuracy cannot say whether the items are right. Items have no stable key: the model may reorder,
split, merge, duplicate or misspell them. So items are matched one to one by the Hungarian method on a
score that combines the similarity of normalised names (a character-level Levenshtein ratio; the
normalisation folds case, punctuation, Ukrainian and Latin look-alike letters and units, in one module)
with the agreement of the amounts (`0.5 name + 0.5 amount`). A pair counts as a match (`main`) at a
score of 0.8, which an exact amount reaches with a name similarity of 0.6 and an exactly right name
reaches with an amount up to 40% off the larger one; the weights are equal so the two limits mirror
each other. Two variants show what drives the number: `strict` (name similarity 0.6 and an exact
amount) and `lenient` (name similarity 0.6 only). Each variant takes its own assignment: the largest
number of qualifying pairs, then the highest total score. A single assignment by total score was
tried first and rejected in review: adding a junk line could make it swap partners and lose a correct
match. With one assignment per variant an extra prediction never takes a match away, and since every
`strict` pair qualifies for `main` and every `main` pair for `lenient`, the counts nest. Precision, recall and F1 are reported micro (over items)
and macro (the mean of per-receipt F1), with the character error rate of matched names.

The thresholds were chosen by reasoning about the hand-built cases in the tests (a typo, a split line,
two near-identical names with different prices), not tuned on the receipts, so they cannot flatter a
model. They are reported in `index.json` with every result.

Rejected: greedy matching (order-dependent; a duplicate can take another item's partner); matching by
position (any reordering is a total miss); a learned or embedding similarity (a dependency and a model
inside the measuring instrument).

### Which ground truth counts, and the pre-fill rule

A `dps_xml` record that the QR code contradicts is most likely another receipt's file, and a record a
person checked as `differs` is known to be wrong: both are left out. An unchecked record counts, and the
item metrics are also given over checked records only, so a reader can see the difference. When both
sources exist the register's own record (`dps_xml`) wins over a person's (`manual`), per purpose.

A person correcting a form a model filled in leans towards that model's answer, so a record whose
`prefilled_by` (or, for categories, `categories_prefilled_by`) names the model a run evaluates is not
ground truth for that run. The receipt is left out of that run's ground-truth metrics and counted, and
paired comparisons use only the receipts left in both runs. The rule does not look at the record's
source, so a record from any source cannot slip past it. The export's fixed values are honoured:
`source:hand` and `source:dps_xml` count for every model, `source:unknown-model` for none, and
`categories_prefilled_by: source:unknown` for no categoriser.

### Model identity

The app records model names exactly as the ML service reports them, and one model has several: a
local quantised build (`mlx-community/Qwen3-VL-8B-Instruct-4bit`), the hosted id
(`qwen/qwen3-vl-8b-instruct`), a dated slug as the version (`anthropic/claude-4.6-sonnet-20260217`).
Exact comparison would let a person's corrections of the hosted model's answer test the local build
of the same weights. So the harness reads every name, in one module (`ml/evaluation/models.py`), as a
family, sizes, versions and words, ignoring the publisher or host, case, prefixes and routing
suffixes, dates and releases, quantisation and packaging words and "instruct". The same base model is
one model whatever its quantisation, host, publisher or dated slug; another size of the family (8B
against 235B-A22B), another version (Qwen2.5 against Qwen3) or another tier (`gpt-4.1` against
`gpt-4.1-mini`) is another model, since its answers differ enough to be measured apart.

Names are written in too many ways for a list of rules to read every one, so the comparison is built
to fail safe: two names are different models only with proof (another family, size, version or tier
word); the same words are the same model; anything else, a word the rules do not know, is unknown, and
an unknown comparison leaves the record out. A name that is a path on disk, a version `local` (a model
loaded from a folder says nothing reliable about its weights) or a name that leaves no word is unknown
too. Two earlier versions were refuted in review: one compared token lists for equality, and the same
model written another way (`qwen-2.5` against `qwen2.5`, a date before the quantisation suffix, an
unknown build word) got two identities; the next took a vendor word for the family
(`Meta-Llama` against `llama`) and any extra number for another version (`Mixtral-8x7B-v0.1`). Both
bypassed the rule. Now versions prove a difference only where both names have one, a family word
inside the other name proves nothing, and the tests keep every such real name as a case that must
never come out "different". Both the run's name and version and the
record's `prefilled_by` and `prefilled_model_version` are compared. Every run reports how many receipts
the rule left out and how many of those for an unknown model. A combined item-category run is every
categoriser it combines (`combined_from` in its `run.json`): it is left out wherever any of them
pre-filled the categories.

Rejected: exact names (misses the same weights under another name); family-level identity, all Qwen-VL
sizes as one model (would empty the test set of the comparison the chapter needs most, local 8B against
hosted 235B, for little gain: a different size answers differently).

### What `eval/results/` may contain, and why it is enforced

The repository is public, and the results are committed so the chapter's numbers can be traced to a
commit. Receipts are personal data. So `eval/results/` holds numbers, category slugs, model names and
run parameters only: never an item name, a merchant, a receipt id, an amount or a date of a single
receipt, or a path on the owner's machine. This is not left to care: `evaluation/results.py` is the only
writer and accepts only a declared structure (exact keys; numbers only where declared and never as
per-receipt lists; text only as fixed labels, narrow patterns such as category slugs and hex digests,
or values read from a `run.json`); tables are written through the same gate cell by cell. Anything else
stops the run with an error naming the place, never the value. The tests try to smuggle receipt content
in and search the results for the synthetic receipts' names, ids and amounts. Per-receipt diagnostics
exist, but only in a folder outside git. The console prints aggregates only.

Outputs are deterministic (sorted keys, fixed rounding, seeds derived from the run ids, no timestamps of
the harness's own), so a regenerated folder shows a diff only when an input changed.

### What the intervals do and do not account for

Every headline metric has a 95% percentile bootstrap interval over receipts (whole receipts with their
items, since items of one photo fail together), and comparisons use paired resamples and McNemar's test
on per-receipt (or, for categories, per-item) correctness, reusing `categoriser.metrics`. The intervals
describe the sampling of receipts from this receipt set. They do not account for how the receipts with
ground truth were chosen (a person picked about fifty), for run-to-run variation (decoding is greedy,
so a rerun repeats itself), for other shops, printers or phones, or for multiple comparisons; McNemar
on items assumes independent items, which items of one receipt are not, so its p-values are too small.
The chapter says so next to the numbers.

### Calibration of item categories

The categoriser's confidence decides what can be accepted without a look, so every item-category run
reports whether its top score means what it says: a reliability table over ten fixed, equal-width
bins of the score (fixed so that runs are binned alike; adaptive bins would move with each run), the
expected calibration error from those bins, and the Brier score of the top candidate, with intervals
from resampling receipts; the run says whether its scores were calibrated (`scores_calibrated`). The
metrics are also split by the source of each prediction (an open set: `memory`, `model`, `decision`,
`combined`, and any word a run declares in its `run.json`; an undeclared word is counted as `other`,
so free text from a predictions file never reaches the public results), because an answer from memory and one from a model are different mechanisms; the
`memory` answers may come from the very booking whose category became the ground truth, so their
share correct is an upper bound.

## Consequences

- Every number in the chapter is `make eval` on archived inputs; a new model, backend or crop setting is
  one more run folder.
- The ground truth is small and hand-picked; the intervals are wide and the text has to say how the
  receipts were chosen.
- The format of item-category runs is fixed here; the categoriser writes to it.
- A new metric means a change to the writer's schema as well as to the scoring: deliberate friction, so
  nothing new reaches the public folder unreviewed.

## Addendum (2026-11-23): look-alike letters, refined and versioned

A refinement of "Item matching", not a new decision. Before names are compared (item matching,
`cer_normalised`, the merchant), Latin and Cyrillic letters that print alike are folded into one
letter, on both sides, for every model. The rule stays as first built: one class per pair, applied
after NFKC and case folding (so a class alike only as capitals, `В`/`B`, also joins its small
letters and a word's case never decides whether two scripts compare equal), on every token, digits
left alone. It gains the class `Ï ï`/`Ї ї` and the non-Ukrainian twins `ј ѕ һ` of `j s h`. Pairs alike
only in italics (`n`/`п`, `u`/`и`, `r`/`г`, `b`/`ь`, `m`/`т`) and `ё` stay out; so do digit
look-alikes (`0`/`О`, `3`/`З`, `6`/`б`), since a digit read as a letter is a real error. The
classes, and why each borderline pair is in or out, are in `ml/README.md`, "The evaluation harness".

Folding every token was kept over folding only tokens that contain a Cyrillic letter. Folding
Cyrillic into Latin, the two coincide; in the other direction, and for any variant that folds only
some tokens, a word written wholly in the other script on one side is rewritten on that side only.
On the pilot OCR runs, each taken as the reference for each other (aggregate counts in the README),
both scoped variants matched fewer items than no fold at all, and the fold on every token matched
the most, whichever script is the internal form.

`cer_plain` stays raw (NFC and collapsed spaces only): it is the strict figure, and its gap to
`cer_normalised` shows how much error is case, punctuation, units and script swaps. Its pairs come
from the normalised matching, so it too depends on the rule.

The rule is versioned: `NORMALISATION_VERSION` in `ml/evaluation/text.py` (1: the first 13 classes;
2: with `ї ј ѕ һ`), written to `index.json` under `inputs.matching.normalisation_version`, so a
number can always be traced to the rule that made it. The new key changes the writer's declared
structure (it accepts exactly the declared keys), so `RESULTS_VERSION` moves from 1 to 2. On the
pilot runs version 2 changes no number against version 1; nothing committed under `eval/results/`
changes, since no results are committed yet.
