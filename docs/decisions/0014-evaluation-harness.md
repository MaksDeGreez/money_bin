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
with the agreement of the amounts (`0.6 name + 0.4 amount`). Only pairs with a name similarity of at
least 0.6 may match. A pair counts as a match at a score of 0.76, which an exact amount reaches with a
name similarity of 0.6 and an exactly right name reaches with an amount up to 40% off. Two variants
show what drives the number: `strict` (name match and exact amount) and `lenient` (name match only);
`strict` ⊆ `main` ⊆ `lenient` by construction. Precision, recall and F1 are reported micro (over items)
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
paired comparisons use only the receipts left in both runs. "The same model" ignores the prompt
version, case, a backend prefix and a variant suffix, and also matches on the last path segment, so the
rule errs towards leaving a receipt out. The rule does not look at the record's source, so a record from
any source cannot slip past it.

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

## Consequences

- Every number in the chapter is `make eval` on archived inputs; a new model, backend or crop setting is
  one more run folder.
- The ground truth is small and hand-picked; the intervals are wide and the text has to say how the
  receipts were chosen.
- The format of item-category runs is fixed here; the categoriser writes to it.
- A new metric means a change to the writer's schema as well as to the scoring: deliberate friction, so
  nothing new reaches the public folder unreviewed.
