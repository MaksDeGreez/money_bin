"""The only writer of `eval/results/`: it accepts a declared structure and nothing else.

`eval/results/` is in the public repository, so it may hold numbers, category slugs, model names
and run parameters only: never an item name, a merchant, a receipt id, an amount or a date of a
single receipt, or a path on the owner's machine. The scoring code is not trusted to keep to this;
the writer checks every value against a schema before anything is written:

- every object has exactly the declared keys, or (a map) keys of a declared form: a category slug,
  a segment, a metric name, a kind; never free text;
- a number is a finite int or float; there are no lists of numbers except 95% intervals (two
  numbers), so no per-receipt series can pass;
- a text value is one of a fixed set of labels, a pattern with no room for prose (a category slug,
  a hex digest, an ISO time copied from `run.json`), or a run parameter: a value that must equal one
  read from a `run.json` (`run_id`, `backend`, `model_name`, `model_version`, `prompt_version`).

Anything else raises `ResultsShapeError`, whose message names the place in the structure, never the
value. Tables (`tables.py`) are built only from results that passed this check, and are written
through a second gate: every cell is a number, a known word, a category slug or a run parameter (no
date, no free text).

Output is deterministic: keys sorted, floats rounded to 6 places, UTF-8, a final newline.
"""

import csv
import io
import json
import math
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

RESULTS_VERSION = 1
FLOAT_PLACES = 6

SLUG = r"[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*"
LABEL = re.compile(rf"\A(?:{SLUG}|_none|_other)\Z")
RUN_ID = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._:@+-]{0,159}\Z")
PARAMETER = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}\Z")
HEX = re.compile(r"\A[0-9a-f]{7,64}\Z")
ISO_TIME = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\Z")
COUNT_KEY = re.compile(r"\A[a-z][a-z_]{0,39}\Z")
STOPPED = re.compile(r"\A[a-z][a-z0-9_]{0,59}\Z")
COST = re.compile(r"\A\d{1,12}(?:\.\d{1,30})?\Z")


class ResultsShapeError(Exception):
    """A value that may not enter `eval/results/`. The message names its place, never the value."""


@dataclass
class Context:
    run_values: frozenset[str] = field(default_factory=frozenset)


Check = Callable[[Any, str, Context], None]


def _fail(path: str, what: str) -> None:
    raise ResultsShapeError(f"results: {path or 'the root'} {what}")


def number(nullable: bool = True) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if isinstance(value, bool) or not isinstance(value, int | float):
            _fail(path, "must be a number")
        if isinstance(value, float) and not math.isfinite(value):
            _fail(path, "must be finite")

    return check


def integer(nullable: bool = False) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if isinstance(value, bool) or not isinstance(value, int):
            _fail(path, "must be a whole number")

    return check


def boolean(nullable: bool = True) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, bool):
            _fail(path, "must be true or false")

    return check


def one_of(*values: str, nullable: bool = False) -> Check:
    allowed = frozenset(values)

    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, str) or value not in allowed:
            _fail(path, "must be one of the fixed labels")

    return check


def pattern(regex: re.Pattern[str], nullable: bool = True) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, str) or not regex.match(value):
            _fail(path, "does not have the allowed form")

    return check


def run_value(regex: re.Pattern[str] = PARAMETER, nullable: bool = False) -> Check:
    """Text that must be a run parameter read from a `run.json`, in a safe form."""

    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, str) or not regex.match(value) or value not in ctx.run_values:
            _fail(path, "must be a run parameter from a run.json")

    return check


def interval() -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None:
            return
        if not isinstance(value, list) or len(value) != 2:
            _fail(path, "must be an interval of two numbers")
        for i, item in enumerate(value):
            number(nullable=False)(item, f"{path}[{i}]", ctx)

    return check


def obj(fields: dict[str, Check], nullable: bool = False) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, dict):
            _fail(path, "must be an object")
        if set(value) != set(fields):
            _fail(path, "has keys other than the declared ones")
        for key, spec in fields.items():
            spec(value[key], f"{path}.{key}" if path else key, ctx)

    return check


def mapping(keys: Check, values: Check, nullable: bool = False) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, dict):
            _fail(path, "must be an object")
        for key, item in value.items():
            keys(key, f"{path} (a key)", ctx)
            values(item, f"{path}.{key}", ctx)

    return check


def listing(items: Check, nullable: bool = False) -> Check:
    def check(value: Any, path: str, ctx: Context) -> None:
        if value is None and nullable:
            return
        if not isinstance(value, list):
            _fail(path, "must be a list")
        for i, item in enumerate(value):
            items(item, f"{path}[{i}]", ctx)

    return check


# --- the schemas ---------------------------------------------------------------------------

SEGMENTS = ("all", "fiscal", "card_slip", "kind_unknown", "one_photo", "multi_photo", "crop_failed")
FIELDS = ("date", "time", "total", "fiscal_number", "receipt_number")
KINDS = ("fiscal", "card_slip")
PREDICTED_KINDS = ("fiscal", "card_slip", "none")
VARIANTS = ("main", "strict", "lenient")
ITEM_STATS = ("precision", "recall", "f1_micro", "f1_macro")
HEADLINE = ("macro_f1", "weighted_f1", "accuracy", "top3_accuracy")
DIMENSIONS = ("model", "crops", "backend", "declared")
TASKS = ("ocr", "item_categories")

METRIC = obj(
    {
        "value": number(),
        "ci95": interval(),
        "numerator": number(False),
        "denominator": number(False),
    }
)
ESTIMATE = obj({"value": number(), "ci95": interval()})
TIMING = obj(
    {"count": integer(), "mean": number(), "median": number(), "p90": number()}, nullable=True
)
OCR_COST = obj(
    {
        "total_usd": pattern(COST, nullable=False),
        "receipts_with_cost": integer(),
        "receipts_without_cost": integer(),
        "complete": boolean(False),
        "per_receipt_usd": pattern(COST),
        "per_1000_receipts_usd": pattern(COST),
    },
    nullable=True,
)
ITEMS = obj(
    {
        "receipts": integer(),
        "reference_items": integer(),
        "predicted_items": integer(),
        **{variant: obj({stat: METRIC for stat in ITEM_STATS}) for variant in VARIANTS},
        "cer_normalised": METRIC,
        "cer_plain": METRIC,
    }
)
SEGMENT = obj(
    {
        "receipts": integer(),
        "fields": obj({name: METRIC for name in FIELDS}),
        "merchant": METRIC,
        "kind": obj(
            {
                "accuracy": METRIC,
                "confusion": obj(
                    {kind: obj({p: integer() for p in PREDICTED_KINDS}) for kind in KINDS}
                ),
            }
        ),
        "items": ITEMS,
        "items_checked_only": ITEMS,
        "items_sum_to_total": METRIC,
        "parse_failed": METRIC,
        "errors": integer(),
        "repaired": integer(),
        "seconds_per_receipt": TIMING,
    },
    nullable=True,
)
RUN = obj(
    {
        "run_id": run_value(RUN_ID),
        "task": one_of(*TASKS),
        "backend": run_value(),
        "model_name": run_value(),
        "model_version": run_value(nullable=True),
        "prompt_version": run_value(nullable=True),
        "git_sha": pattern(HEX),
        "git_dirty": boolean(),
        "crops": boolean(False),
        "image_max_side": integer(nullable=True),
        "max_tokens": integer(nullable=True),
        "constrained_decoding": boolean(),
        "structured_output": boolean(),
        "started_at": pattern(ISO_TIME),
        "finished_at": pattern(ISO_TIME),
        "load_seconds": number(),
        "peak_memory_gb": number(),
        "stopped": pattern(STOPPED),
        "counts": mapping(pattern(COUNT_KEY, nullable=False), integer()),
        "filters": obj(
            {"only_tax_qr": boolean(), "ids_file": boolean(), "limit": integer(nullable=True)}
        ),
    }
)
GROUND_TRUTH = obj(
    {
        "lines": integer(),
        "without_ingest_id": integer(),
        "source_dps_xml": integer(),
        "source_manual": integer(),
        "excluded_qr_disagrees": integer(),
        "excluded_checked_differs": integer(),
        "unchecked": integer(),
        "not_in_receipt_set": integer(),
    }
)
MATCHING = obj(
    {
        "name_weight": number(False),
        "amount_weight": number(False),
        "name_threshold": number(False),
        "match_threshold": number(False),
    }
)
INPUTS = obj(
    {
        "receipt_set_receipts": integer(),
        "receipt_set_with_qr": integer(),
        "receipt_set_sha256": pattern(HEX),
        "ground_truth_sha256": pattern(HEX),
        "ground_truth": GROUND_TRUTH,
        "seed": integer(),
        "resamples": integer(),
        "matching": MATCHING,
    }
)
OCR_RUN_RESULT = obj(
    {
        "results_version": integer(),
        "run": RUN,
        "counts": mapping(pattern(COUNT_KEY, nullable=False), integer()),
        "segments": obj({segment: SEGMENT for segment in SEGMENTS}),
        "cost_usd": OCR_COST,
    }
)
LABEL_KEY = pattern(LABEL, nullable=False)
CATEGORY_COST = obj(
    {
        "total_usd": pattern(COST, nullable=False),
        "items_with_cost": integer(),
        "items_without_cost": integer(),
        "complete": boolean(False),
        "per_item_usd": pattern(COST),
        "per_1000_items_usd": pattern(COST),
    },
    nullable=True,
)
HEADLINE_BLOCK = obj({"items": integer(), **{metric: ESTIMATE for metric in HEADLINE}})
COVERAGE = obj(
    {
        "at_coverage": listing(
            obj(
                {
                    "target_coverage": number(False),
                    "coverage": number(False),
                    "rows": integer(),
                    "precision": number(),
                    "min_confidence": number(),
                }
            )
        ),
        "at_threshold": listing(
            obj(
                {
                    "threshold": number(False),
                    "rows": integer(),
                    "coverage": number(False),
                    "precision": number(),
                }
            )
        ),
    },
    nullable=True,
)
CATEGORY_RUN_RESULT = obj(
    {
        "results_version": integer(),
        "run": RUN,
        "counts": mapping(pattern(COUNT_KEY, nullable=False), integer()),
        "headline": HEADLINE_BLOCK,
        "coverage": COVERAGE,
        "auto_accept": obj(
            {
                "target_precision": number(False),
                "coverage": number(False),
                "rows": integer(),
                "precision": number(),
                "min_confidence": number(),
            }
        ),
        "per_class": listing(
            obj(
                {
                    "category_slug": LABEL_KEY,
                    "support": integer(),
                    "predicted": integer(),
                    "f1": number(False),
                }
            )
        ),
        "confusion": mapping(LABEL_KEY, mapping(LABEL_KEY, integer())),
        "by_source": obj({source: HEADLINE_BLOCK for source in ("memory", "model")}),
        "card_slips": obj({"receipts": integer(), "accuracy": number(), "top3_accuracy": number()}),
        "seconds_per_item": TIMING,
        "cost_usd": CATEGORY_COST,
    }
)
DIFFERENCE = obj(
    {
        "receipts": integer(),
        "a": number(),
        "b": number(),
        "difference": number(),
        "ci95": interval(),
    }
)
MCNEMAR = {
    "a_only_correct": integer(),
    "b_only_correct": integer(),
    "exact_p_value": number(False),
    "chi2_corrected": number(False),
    "chi2_p_value": number(False),
}
COMPARISON_HEAD = {
    "results_version": integer(),
    "a": run_value(RUN_ID),
    "b": run_value(RUN_ID),
    "task": one_of(*TASKS),
    "dimension": one_of(*DIMENSIONS),
    "declared": boolean(False),
}
OCR_COMPARISON = obj(
    {
        **COMPARISON_HEAD,
        "receipts": integer(),
        "differences": mapping(
            pattern(re.compile(r"\A[a-z_]+(?:\.[a-z0-9_]+){0,2}\Z"), False), DIFFERENCE
        ),
        "mcnemar": mapping(
            pattern(re.compile(r"\A[a-z_]+(?:\.[a-z_]+)?\Z"), False),
            obj({"receipts": integer(), **MCNEMAR}),
        ),
        "seconds_mean": obj({"a": number(), "b": number()}),
    }
)
CATEGORY_COMPARISON = obj(
    {
        **COMPARISON_HEAD,
        "items": integer(),
        "receipts": integer(),
        "differences": obj(
            {
                metric: obj(
                    {"a": number(), "b": number(), "difference": number(), "ci95": interval()}
                )
                for metric in HEADLINE
            }
        ),
        "mcnemar": obj({"top1": obj({"items": integer(), **MCNEMAR})}),
    }
)
FILE_NAME = re.compile(r"\A(?:runs|comparisons)/[A-Za-z0-9][A-Za-z0-9._-]{0,340}\.json\Z")
INDEX = obj(
    {
        "results_version": integer(),
        "inputs": INPUTS,
        "runs": listing(
            obj(
                {
                    "run_id": run_value(RUN_ID),
                    "task": one_of(*TASKS),
                    "backend": run_value(),
                    "model_name": run_value(),
                    "model_version": run_value(nullable=True),
                    "prompt_version": run_value(nullable=True),
                    "crops": boolean(False),
                    "file": pattern(FILE_NAME, nullable=False),
                }
            )
        ),
        "comparisons": listing(
            obj(
                {
                    "a": run_value(RUN_ID),
                    "b": run_value(RUN_ID),
                    "task": one_of(*TASKS),
                    "dimension": one_of(*DIMENSIONS),
                    "declared": boolean(False),
                    "file": pattern(FILE_NAME, nullable=False),
                }
            )
        ),
    }
)

# Table cells: a number (an int, a float, an `Est` estimate, or a plain decimal string such as
# seconds, dollars or a p-value), a fixed word, a category slug, or a run parameter. No dates, no
# free text. A cell cannot tell an aggregate from one receipt's amount; that is why tables are only
# ever built from results JSON that passed the schema above.
CELL = re.compile(r"\A(?:-?\d{1,12}(?:\.\d{1,6})?|<0\.001)\Z")
CELL_WORDS = frozenset(
    {"", "n/a", "yes", "no", "full", "crops", "model", "backend", "declared", *SEGMENTS, *TASKS}
)
HEADER = re.compile(r"\A[A-Za-z0-9 _%$/().,:<=>≥-]{1,60}\Z")
# A table's note is a constant of `tables.py`: plain ASCII prose, never data.
NOTE = re.compile(r"\A[A-Za-z0-9 _%$/().,:;'`<>≥=+*-]{0,1200}\Z")


@dataclass(frozen=True)
class Est:
    """A table cell holding an estimate with its 95% interval, already scaled and rounded.

    Markdown shows `value [low, high]`; CSV has three columns."""

    value: float | None
    low: float | None
    high: float | None
    places: int = 1

    def _format(self, number: float) -> str:
        rounded = round(number, self.places)
        return f"{rounded + 0.0 if rounded else 0.0:.{self.places}f}"  # never "-0.0"

    def text(self) -> str:
        if self.value is None:
            return "n/a"
        value = self._format(self.value)
        if self.low is None or self.high is None:
            return value
        return f"{value} [{self._format(self.low)}, {self._format(self.high)}]"

    def parts(self) -> list[str]:
        return [
            "" if part is None else self._format(part) for part in (self.value, self.low, self.high)
        ]


def check(value: Any, spec: Check, ctx: Context) -> None:
    spec(value, "", ctx)


def _rounded(value: Any) -> Any:
    if isinstance(value, float):
        rounded = round(value, FLOAT_PLACES)
        return 0.0 if rounded == 0 else rounded
    if isinstance(value, dict):
        return {key: _rounded(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_rounded(item) for item in value]
    return value


def dumps(value: Any) -> str:
    return json.dumps(_rounded(value), sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def check_cell(value: Any, ctx: Context) -> None:
    if value is None or (isinstance(value, int | float) and not isinstance(value, bool)):
        return
    if isinstance(value, Est):
        for part in (value.value, value.low, value.high):
            if part is not None and (
                isinstance(part, bool)
                or not isinstance(part, int | float)
                or not math.isfinite(part)
            ):
                raise ResultsShapeError("results: a table estimate is not a number")
        return
    if isinstance(value, str) and (
        CELL.match(value)
        or value in CELL_WORDS
        or LABEL.match(value)
        or (value in ctx.run_values and PARAMETER.match(value))
    ):
        return
    raise ResultsShapeError("results: a table cell is not a number, a label or a run parameter")


class ResultsWriter:
    """Checks files for one results folder, then writes them all at once.

    `write_json` and `write_table` check their content and keep it in memory; `commit` writes every
    kept file and removes the stale ones. So a refused value leaves the folder as it was, and a
    dry run (`--check`) runs every check without writing."""

    def __init__(self, root: Path, run_values: Iterable[str]) -> None:
        self.root = root
        self.ctx = Context(frozenset(value for value in run_values if isinstance(value, str)))
        self.staged: dict[str, str] = {}

    def _stage(self, relative: str, text: str) -> None:
        path = (self.root / relative).resolve()
        if self.root.resolve() not in path.parents:
            raise ResultsShapeError("results: a file name leaves the results folder")
        self.staged[relative] = text

    def write_json(self, relative: str, value: Any, spec: Check) -> str:
        """Check `value` and keep it; returns the JSON text that will be written."""
        if not FILE_NAME.match(relative) and relative != "index.json":
            raise ResultsShapeError("results: a file name has not the allowed form")
        check(value, spec, self.ctx)
        text = dumps(value)
        self._stage(relative, text)
        return text

    def write_table(
        self, name: str, title: str, headers: list[str], rows: list[list[Any]], note: str
    ) -> None:
        """A table as Markdown (with a title and a fixed note) and as CSV, through the cell gate."""
        if not re.match(r"\A[a-z_]{1,40}\Z", name):
            raise ResultsShapeError("results: a table name has not the allowed form")
        for text in (title, *headers):
            if not HEADER.match(text):
                raise ResultsShapeError("results: a table header has not the allowed form")
        if not NOTE.match(note):
            raise ResultsShapeError("results: a table note has not the allowed form")
        for row in rows:
            if len(row) != len(headers):
                raise ResultsShapeError("results: a table row has the wrong number of cells")
            for cell in row:
                check_cell(cell, self.ctx)
        self._stage(f"tables/{name}.md", _markdown(title, headers, rows, note))
        self._stage(f"tables/{name}.csv", _csv(headers, rows))

    def commit(self) -> int:
        """Write every kept file (through a temporary file each) and delete the files in the
        harness's own subfolders that are not among them; returns how many were deleted."""
        written: set[Path] = set()
        for relative, text in sorted(self.staged.items()):
            path = (self.root / relative).resolve()
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + ".tmp")
            try:
                temporary.write_text(text, encoding="utf-8")
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
            written.add(path)
        removed = 0
        for folder, suffixes in (
            ("runs", (".json",)),
            ("comparisons", (".json",)),
            ("tables", (".md", ".csv")),
        ):
            directory = self.root / folder
            if not directory.is_dir():
                continue
            for path in sorted(directory.iterdir()):
                if path.suffix in suffixes and path.resolve() not in written:
                    path.unlink()
                    removed += 1
        return removed


def _text(cell: Any) -> str:
    if cell is None:
        return ""
    if isinstance(cell, Est):
        return cell.text()
    return str(cell)


def _markdown(title: str, headers: list[str], rows: list[list[Any]], note: str) -> str:
    lines = [f"# {title}", ""]
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join("---" for _ in headers) + " |")
    for row in rows:
        lines.append("| " + " | ".join(_text(cell) for cell in row) + " |")
    if not rows:
        lines.append("| " + " | ".join("" for _ in headers) + " |")
    if note:
        lines.extend(["", note])
    return "\n".join(lines) + "\n"


def _csv(headers: list[str], rows: list[list[Any]]) -> str:
    """CSV with an estimate column split into the value and its interval's two ends."""
    estimates = [any(isinstance(row[i], Est) for row in rows) for i in range(len(headers))]
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    head: list[str] = []
    for header, estimate in zip(headers, estimates, strict=True):
        head.extend([header, f"{header} low", f"{header} high"] if estimate else [header])
    writer.writerow(head)
    for row in rows:
        cells: list[str] = []
        for cell, estimate in zip(row, estimates, strict=True):
            if estimate:
                cells.extend(cell.parts() if isinstance(cell, Est) else ["", "", ""])
            else:
                cells.append(_text(cell))
        writer.writerow(cells)
    return buffer.getvalue()
