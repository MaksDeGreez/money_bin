"""Score an OCR run against the QR codes of the receipt set.

    uv run python -m evaluation.ocr_fields --run ~/Documents/money_bin_data/runs/<run id>

A Ukrainian fiscal receipt's QR code holds the date and time, the total, the
cash register's fiscal number and the receipt's fiscal number
(`qr_fields` in `receipts.jsonl`), so those fields can be scored without
anyone typing answers. Only receipts with QR fields are scored, each field
over the receipts where the QR has it. A receipt the backend failed on
(`parse_failed`, `error`) counts as wrong for every field.

Scores:
- `date`, `time` (to the minute, Kyiv time), `total`, `fiscal_number`,
  `receipt_number`: the share of exact matches;
- `items_sum_to_qr_total`: the share of receipts whose item amounts add up
  exactly to the QR total (there is no item ground truth yet, so this stands
  in for item quality);
- `kind_fiscal`: the share the model called `fiscal` (a tax QR means it is);
- parse failures, and seconds per receipt (mean, median, 90th percentile) over
  every receipt the backend answered or failed to parse;
- for a hosted backend, the cost per receipt and per 1,000 receipts in US
  dollars (`evaluation.common.cost_summary`: what OpenRouter reported, over
  every receipt that made a model call); null for a local backend.

The scores are printed and written to `scores.json` in the run folder. Only
aggregates are printed.
"""

import argparse
import json
import sys
from collections.abc import Sequence
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, TextIO
from zoneinfo import ZoneInfo

from evaluation.common import (
    UsageError,
    cost_summary,
    read_jsonl,
    read_receipt_set,
    timing_summary,
    write_private_json,
)

KYIV = ZoneInfo("Europe/Kyiv")
FIELDS = ("date", "time", "total", "fiscal_number", "receipt_number")


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.ocr_fields",
        description="Score an OCR run against the QR codes of the receipt set.",
    )
    parser.add_argument("--run", required=True, type=Path, help="the run folder")
    parser.add_argument(
        "--ingest", type=Path, help="the receipt set folder (default: the one in run.json)"
    )
    return parser.parse_args(argv)


def _kyiv(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        return None
    if moment.tzinfo is None:
        return None
    return moment.astimezone(KYIV)


def _decimal(value: Any) -> Decimal | None:
    if not isinstance(value, str):
        return None
    try:
        return Decimal(value)
    except InvalidOperation:
        return None


def truth_of(qr_fields: dict[str, Any]) -> dict[str, Any]:
    """The QR values in the form they are compared in; None where the QR has none."""
    issued_at = _kyiv(qr_fields.get("issued_at"))
    return {
        "date": issued_at.date() if issued_at else None,
        "time": issued_at.strftime("%H:%M") if issued_at else None,
        "total": _decimal(qr_fields.get("total")),
        "fiscal_number": qr_fields.get("fiscal_number") or None,
        "receipt_number": qr_fields.get("receipt_number") or None,
    }


def predicted_of(receipt: dict[str, Any] | None) -> dict[str, Any]:
    """The predicted values in the same form as `truth_of`."""
    if receipt is None:
        return dict.fromkeys(FIELDS)
    issued_at = _kyiv(receipt.get("issued_at"))
    return {
        "date": issued_at.date() if issued_at else None,
        "time": issued_at.strftime("%H:%M") if issued_at else None,
        "total": _decimal(receipt.get("total")),
        "fiscal_number": receipt.get("fiscal_number"),
        "receipt_number": receipt.get("receipt_number"),
    }


def items_sum_to(receipt: dict[str, Any] | None, total: Decimal | None) -> bool:
    if receipt is None or total is None or not receipt.get("items"):
        return False
    amounts = [_decimal(item.get("amount")) for item in receipt["items"]]
    if any(amount is None for amount in amounts):
        return False
    return sum(amounts, Decimal("0")) == total  # type: ignore[arg-type]


def _share(hits: int, total: int) -> dict[str, Any]:
    return {"hits": hits, "of": total, "share": round(hits / total, 4) if total else None}


def score(predictions: list[dict[str, Any]], receipt_set: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = {line["receipt_id"]: line for line in receipt_set}
    hits = dict.fromkeys(FIELDS, 0)
    present = dict.fromkeys(FIELDS, 0)
    item_hits = item_total = 0
    kind_hits = 0
    scored = 0
    for record in predictions:
        line = by_id.get(record["receipt_id"])
        if line is None or not line.get("qr_fields") or record["status"] == "skipped":
            continue
        scored += 1
        truth = truth_of(line["qr_fields"])
        receipt = record.get("receipt") if record["status"] == "ok" else None
        predicted = predicted_of(receipt)
        for field in FIELDS:
            if truth[field] is None:
                continue
            present[field] += 1
            hits[field] += int(predicted[field] == truth[field])
        if truth["total"] is not None:
            item_total += 1
            item_hits += int(items_sum_to(receipt, truth["total"]))
        kind_hits += int(receipt is not None and receipt.get("kind") == "fiscal")

    attempted = [r for r in predictions if r["status"] != "skipped"]
    answered = [r for r in attempted if r["status"] in ("ok", "parse_failed")]
    return {
        "receipts": len(predictions),
        "scored_with_qr": scored,
        "fields": {field: _share(hits[field], present[field]) for field in FIELDS},
        "items_sum_to_qr_total": _share(item_hits, item_total),
        "kind_fiscal": _share(kind_hits, scored),
        "parse_failed": _share(
            sum(r["status"] == "parse_failed" for r in attempted), len(attempted)
        ),
        "errors": sum(r["status"] == "error" for r in attempted),
        "repaired": sum(bool(r.get("repaired")) for r in attempted),
        "seconds_per_receipt": timing_summary(r["seconds"] for r in answered),
        "cost_usd": cost_summary(predictions),
    }


def print_scores(scores: dict[str, Any], out: TextIO) -> None:
    def line(label: str, share: dict[str, Any]) -> str:
        value = "n/a" if share["share"] is None else f"{share['share'] * 100:.1f}%"
        return f"  {label:<22} {value:>7}  ({share['hits']}/{share['of']})"

    print(
        f"receipts {scores['receipts']}, scored against a QR {scores['scored_with_qr']}",
        file=out,
    )
    for field, share in scores["fields"].items():
        print(line(field, share), file=out)
    print(line("items_sum_to_qr_total", scores["items_sum_to_qr_total"]), file=out)
    print(line("kind_fiscal", scores["kind_fiscal"]), file=out)
    print(line("parse_failed", scores["parse_failed"]), file=out)
    print(f"  errors {scores['errors']}, repaired {scores['repaired']}", file=out)
    timing = scores["seconds_per_receipt"]
    print(
        f"  seconds per receipt: mean {timing['mean']}, median {timing['median']}, "
        f"p90 {timing['p90']} (n={timing['count']})",
        file=out,
    )
    cost = scores.get("cost_usd")
    if cost is not None:
        line_text = (
            f"  cost per receipt: ${cost['per_receipt_usd']}, "
            f"per 1,000 receipts: ${cost['per_1000_receipts_usd']} "
            f"(n={cost['receipts_with_cost']})"
        )
        if not cost["complete"]:
            line_text += f", {cost['receipts_without_cost']} without a reported cost"
        print(line_text, file=out)


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    run_dir = args.run.expanduser().resolve()
    predictions_path = run_dir / "predictions.jsonl"
    if not predictions_path.is_file():
        raise UsageError(f"no predictions.jsonl in {run_dir}")
    ingest = args.ingest
    if ingest is None:
        run_json = run_dir / "run.json"
        if not run_json.is_file():
            raise UsageError("no run.json in the run folder; pass --ingest")
        ingest = Path(json.loads(run_json.read_text(encoding="utf-8"))["ingest"])
    scores = score(list(read_jsonl(predictions_path)), read_receipt_set(ingest.expanduser()))
    write_private_json(run_dir / "scores.json", scores)
    print_scores(scores, out)
    return scores


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        run(args)
    except UsageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
