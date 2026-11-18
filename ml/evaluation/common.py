"""Shared helpers of the evaluation scripts: reading the receipt set, files, statistics."""

import json
import math
import os
import statistics
from collections.abc import Iterable, Iterator, Sequence
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

from app.decimals import exact_sum, wide_context

FILE_MODE = 0o600
DIR_MODE = 0o700


class UsageError(Exception):
    """A bad argument or input file. The scripts print it and exit with 2."""


def read_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    """The JSON objects of a JSON-lines file, skipping blank lines."""
    with path.open(encoding="utf-8") as lines:
        for number, line in enumerate(lines, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                raise UsageError(f"{path.name}: line {number} is not JSON") from None
            if not isinstance(value, dict):
                raise UsageError(f"{path.name}: line {number} is not a JSON object")
            yield value


def read_receipt_set(ingest: Path) -> list[dict[str, Any]]:
    """The lines of `receipts.jsonl` in a receipt set folder."""
    path = ingest / "receipts.jsonl"
    if not path.is_file():
        raise UsageError(f"no receipts.jsonl in {ingest}")
    return list(read_jsonl(path))


def inside_git_repository(path: Path) -> bool:
    """Whether `path` (which may not exist yet) is inside a git working tree."""
    current = path.resolve()
    return any((folder / ".git").exists() for folder in (current, *current.parents))


def ensure_private_folder(path: Path) -> None:
    """Create a folder (and its parents) readable by the owner only."""
    path.mkdir(mode=DIR_MODE, parents=True, exist_ok=True)


def write_private_json(path: Path, value: Any) -> None:
    """Write JSON to a file only the owner can read, through a temporary file."""
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write("\n")
    temporary.replace(path)


def percentile(values: Sequence[float], share: float) -> float | None:
    """The nearest-rank percentile (`share` between 0 and 1), or None without values."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(share * len(ordered)))
    return ordered[rank - 1]


def timing_summary(seconds: Iterable[float]) -> dict[str, float | int | None]:
    """Count, mean, median and 90th percentile of durations, rounded to milliseconds."""
    values = list(seconds)

    def rounded(value: float | None) -> float | None:
        return None if value is None else round(value, 3)

    return {
        "count": len(values),
        "mean": rounded(statistics.fmean(values)) if values else None,
        "median": rounded(statistics.median(values)) if values else None,
        "p90": rounded(percentile(values, 0.9)),
    }


# Cost statistics are reported to a millionth of a dollar per receipt and to a
# ten-thousandth per 1,000 receipts. The sums themselves are exact.
COST_PER_RECEIPT_PLACES = Decimal("0.000001")
COST_PER_1000_PLACES = Decimal("0.0001")


def _cost(value: Any) -> Decimal | None:
    if not isinstance(value, str):
        return None
    try:
        cost = Decimal(value)
    except InvalidOperation:
        return None
    # A receipt's cost is a sum of bounded call costs, so it may be longer than
    # one call's: only a finite value is required here.
    return cost if cost.is_finite() and cost >= 0 else None


def cost_summary(records: Iterable[dict[str, Any]]) -> dict[str, Any] | None:
    """The hosted model's cost over the receipts of a run, in US dollars.

    Counts every receipt that made at least one model call, whatever its
    status: a failed receipt was paid for too. `cost_usd` in a record's
    diagnostics is the sum OpenRouter reported for its calls (a decimal
    string), or null when a call reported none; such receipts are counted in
    `receipts_without_cost` and left out of the averages, so `complete` says
    whether the averages cover every paid receipt. None when no record carries
    a cost field at all (a local backend).
    """
    hosted = [
        record.get("diagnostics") or {}
        for record in records
        if "cost_usd" in (record.get("diagnostics") or {})
    ]
    if not hosted:
        return None
    paid = [diagnostics for diagnostics in hosted if diagnostics.get("model_calls", 0) > 0]
    costs = [_cost(diagnostics.get("cost_usd")) for diagnostics in paid]
    known = [cost for cost in costs if cost is not None]
    total = exact_sum(known)
    per_receipt = per_1000 = None
    if known:
        with wide_context():
            per_receipt = format((total / len(known)).quantize(COST_PER_RECEIPT_PLACES), "f")
            per_1000 = format((total * 1000 / len(known)).quantize(COST_PER_1000_PLACES), "f")
    return {
        "total_usd": format(total, "f"),
        "receipts_with_cost": len(known),
        "receipts_without_cost": len(costs) - len(known),
        "complete": len(known) == len(costs),
        "per_receipt_usd": per_receipt,
        "per_1000_receipts_usd": per_1000,
    }


def read_categories(path: Path) -> list[Any]:
    """The candidate categories exported by the Rails app (`bin/rails categories:export_items`).

    The hand-over shape is `app.categorise.taxonomy`; this only turns its errors into usage errors.
    """
    from app.categorise.taxonomy import TaxonomyError, read_categories_file

    if not path.is_file():
        raise UsageError(f"categories file not found: {path}")
    try:
        return list(read_categories_file(path))
    except TaxonomyError as error:
        raise UsageError(str(error)) from None
