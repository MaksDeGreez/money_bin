"""Run the item categoriser over labelled receipt items and write a run folder.

    uv run python -m evaluation.item_categories_run \\
        --ground-truth ~/Documents/money_bin_data/exports/ground_truth.jsonl \\
        --ingest ~/Documents/money_bin_data/receipts \\
        --categories ~/Documents/money_bin_data/exports/item_categories.json \\
        --out ~/Documents/money_bin_data/runs --backend mlx --memory

Inputs: the ground-truth export (`bin/rails "receipts:export_ground_truth[DIR]"`;
items carry `category_slug` in its newer schema, null when unknown), the
receipt set (only its receipts are run), and the candidate categories as the
app sends them (`bin/rails "categories:export_items[FILE]"`). Per receipt the
record of a person (`manual`) is preferred to an imported one.

Each receipt's items are categorised together, in one call, as in the app.
With `--memory` the label memory goes first, as in the app: receipts are taken
in time order (`issued_at`, then the id), and an item is looked up among the
labels of the receipts BEFORE it only, so no item is ever suggested its own
label. The others go to the backend, in one call per receipt.

The run folder `OUT/<run id>/` gets:

- `predictions.jsonl`, one line per item: `receipt_id` (the ingest id),
  `position` (the item's place in the ground-truth document, from 1),
  `candidates` (up to three `{"category_slug", "score"}`, best first),
  `source` (`memory` or `model`), `seconds` and `cost_usd` (decimal strings or
  null: a call's time and cost split evenly over its items; memory costs
  nothing), and `error` (a code when the call failed, else null);
- `run.json`: `"task": "item_categories"`, the backend, model, weights
  revision, prompt version, categories version, git commit, whether the scores
  are calibrated, counts, timings and, for a hosted backend, the cost.

The folder must be outside any git repository (item names are receipt
content); its files are readable by the owner only. The console prints counts.
"""

import argparse
import json
import sys
import time
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, TextIO

from pydantic import ValidationError

from app.backends import BackendError
from app.categorise import CATEGORISERS, CategoriseInput, Categoriser, create_categoriser
from app.categorise.calibration import Calibration, CalibrationError, calibrate, load_calibration
from app.categorise.prompt import PROMPT_VERSION, CategoryOption, categories_version
from app.config import Settings
from app.decimals import exact_sum, wide_context
from evaluation.common import (
    UsageError,
    cost_summary,
    inside_git_repository,
    read_categories,
    read_jsonl,
    read_receipt_set,
    timing_summary,
    write_private_json,
)
from evaluation.label_memory import PRIOR_AGREEING, PRIOR_DISAGREEING, LabelMemory
from evaluation.ocr_run import _open_private, git_commit, make_run_dir, read_ids, run_id_for

TASK = "item_categories"
# Per-item shares of a call's cost are rounded to this; run.json keeps the exact total.
ITEM_COST_PLACES = Decimal("0.000000000001")
SOURCE_PREFERENCE = {"manual": 0, "dps_xml": 1}
# What a receipt records as its categoriser when the label memory filled its suggestions
# (`categories_prefilled_by` in the ground truth; LabelMemory::CATEGORISER_NAME in the app).
MEMORY_CATEGORISER = "label-memory"


@dataclass(frozen=True)
class Item:
    position: int
    name: str
    label: str | None


@dataclass(frozen=True)
class Receipt:
    ingest_id: str
    merchant: str | None
    issued_at: str | None
    items: tuple[Item, ...]


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.item_categories_run",
        description="Run the item categoriser over labelled items and write a run folder.",
    )
    parser.add_argument("--ground-truth", required=True, type=Path, help="ground_truth.jsonl")
    parser.add_argument("--ingest", required=True, type=Path, help="the receipt set folder")
    parser.add_argument("--categories", required=True, type=Path, help="the exported categories")
    parser.add_argument("--out", required=True, type=Path, help="the folder for run folders")
    parser.add_argument("--backend", default="mlx", choices=sorted(CATEGORISERS))
    parser.add_argument("--model", help="the model id (MLX_CATEGORISE_MODEL or the hosted one)")
    parser.add_argument("--memory", action="store_true", help="the label memory goes first")
    parser.add_argument("--calibration", type=Path, help="a calibration file to apply")
    parser.add_argument(
        "--all-receipts",
        action="store_true",
        help="also receipts without any labelled item (default: only labelled ones)",
    )
    parser.add_argument("--ids", type=Path, help="a file with one receipt id per line")
    parser.add_argument("--limit", type=int, help="at most this many receipts")
    args = parser.parse_args(argv)
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be 1 or more")
    return args


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def read_ground_truth(path: Path) -> list[Receipt]:
    """One receipt per ingest id, from the preferred record that gives items.

    A record that gives categories (`categories_known`) is preferred, then a person's
    (`manual`) to an imported one. Item labels are read only from a record with `categories_known`.
    """
    if not path.is_file():
        raise UsageError(f"ground-truth file not found: {path}")
    chosen: dict[str, tuple[int, dict[str, Any]]] = {}
    for line in read_jsonl(path):
        ingest_id = line.get("ingest_id")
        document = line.get("document")
        if not isinstance(ingest_id, str) or not isinstance(document, dict):
            continue
        if line.get("items_known") is not True:
            continue
        known = line.get("categories_known") is True
        rank = (0 if known else 1, SOURCE_PREFERENCE.get(str(line.get("source")), 9))
        if ingest_id not in chosen or rank < chosen[ingest_id][0]:
            chosen[ingest_id] = (rank, document)
    receipts = []
    for ingest_id, ((unknown, _), document) in chosen.items():
        items = []
        for index, item in enumerate(document.get("items") or [], start=1):
            if not isinstance(item, dict) or _text(item.get("name")) is None:
                continue
            position = item.get("position")
            if isinstance(position, bool) or not isinstance(position, int):
                position = index
            label = None if unknown else _text(item.get("category_slug"))
            items.append(Item(position, item["name"], label))
        if items:
            receipts.append(
                Receipt(
                    ingest_id,
                    _text(document.get("merchant")),
                    _text(document.get("issued_at")),
                    tuple(items),
                )
            )
    return receipts


def _time_order(receipt: Receipt) -> tuple[int, str, str]:
    """Receipts with a time first, in time order (ISO strings with their offset)."""
    if receipt.issued_at is None:
        return (1, "", receipt.ingest_id)
    try:
        moment = datetime.fromisoformat(receipt.issued_at).astimezone(UTC).isoformat()
    except ValueError:
        return (1, "", receipt.ingest_id)
    return (0, moment, receipt.ingest_id)


def select(
    receipts: list[Receipt],
    in_set: set[str],
    *,
    ids: list[str] | None,
    all_receipts: bool,
    limit: int | None,
) -> list[Receipt]:
    selected = [receipt for receipt in receipts if receipt.ingest_id in in_set]
    if ids is not None:
        wanted = set(ids)
        selected = [receipt for receipt in selected if receipt.ingest_id in wanted]
    if not all_receipts:
        selected = [r for r in selected if any(item.label for item in r.items)]
    selected.sort(key=_time_order)
    return selected[:limit] if limit is not None else selected


def _share(total: Decimal | None, count: int) -> str | None:
    if total is None or count == 0:
        return None
    with wide_context():
        return format((total / count).quantize(ITEM_COST_PLACES), "f")


def _candidates(candidates: Sequence[Any]) -> list[dict[str, Any]]:
    return [{"category_slug": c.slug, "score": round(c.score, 6)} for c in candidates]


def run_receipt(
    categoriser: Categoriser,
    categories: tuple[CategoryOption, ...],
    calibration: Calibration | None,
    receipt: Receipt,
    memory: LabelMemory | None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """The predictions lines of one receipt, and what its call reported."""
    lines: dict[int, dict[str, Any]] = {}
    remaining: list[Item] = []
    for item in receipt.items:
        suggestion = memory.suggest(item.name) if memory is not None else None
        if suggestion is None:
            remaining.append(item)
            continue
        lines[item.position] = {
            "receipt_id": receipt.ingest_id,
            "position": item.position,
            "candidates": [
                {"category_slug": suggestion.slug, "score": round(suggestion.confidence, 6)}
            ],
            "source": "memory",
            "seconds": "0.000",
            "cost_usd": "0",
            "error": None,
        }
    call: dict[str, Any] = {"called": False}
    if remaining:
        call["called"] = True
        started = time.perf_counter()
        texts = tuple(item.name for item in remaining)
        error = None
        try:
            answer = categoriser.categorise(CategoriseInput(categories, texts, receipt.merchant))
        except BackendError as failure:
            error, diagnostics = failure.code, dict(failure.diagnostics)
            per_item: list[list[Any]] = [[] for _ in remaining]
        except Exception as failure:  # one broken receipt must not end the run
            error, diagnostics = type(failure).__name__, {}
            per_item = [[] for _ in remaining]
        else:
            diagnostics = dict(answer.diagnostics)
            per_item, calibrated = calibrate(
                answer, calibration, categoriser.name, categoriser.model_name
            )
            call["score_kind"] = answer.score_kind
            call["calibrated"] = calibrated
        seconds = time.perf_counter() - started
        call.update(seconds=seconds, error=error, diagnostics=diagnostics)
        cost_text = diagnostics.get("cost_usd")
        cost = Decimal(cost_text) if isinstance(cost_text, str) else None
        for item, candidates in zip(remaining, per_item, strict=True):
            lines[item.position] = {
                "receipt_id": receipt.ingest_id,
                "position": item.position,
                "candidates": _candidates(candidates),
                "source": "model",
                "seconds": f"{seconds / len(remaining):.3f}",
                "cost_usd": _share(cost, len(remaining)),
                "error": error,
            }
    if memory is not None:
        # This receipt's labels are known to the memory only from the next receipt on.
        for item in receipt.items:
            if item.label:
                memory.add(item.name, item.label)
    return [lines[position] for position in sorted(lines)], call


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    runs = args.out.expanduser().resolve()
    if inside_git_repository(runs):
        raise UsageError("--out is inside a git repository; run folders hold receipt content")
    categories = tuple(read_categories(args.categories))
    in_set = {line["receipt_id"] for line in read_receipt_set(args.ingest.expanduser())}
    ids = read_ids(args.ids) if args.ids else None
    receipts = select(
        read_ground_truth(args.ground_truth.expanduser()),
        in_set,
        ids=ids,
        all_receipts=args.all_receipts,
        limit=args.limit,
    )
    if not receipts:
        raise UsageError("no receipt with labelled items matches the filters")
    calibration = None
    if args.calibration:
        try:
            calibration = load_calibration(args.calibration)
        except CalibrationError as error:
            raise UsageError(str(error)) from None

    overrides: dict[str, Any] = {"categorise_backend": args.backend}
    if args.model and args.backend == "mlx":
        overrides["mlx_categorise_model"] = args.model
    if args.model and args.backend == "openrouter":
        overrides["openrouter_categorise_model"] = args.model
    try:
        settings = Settings(**overrides)
    except ValidationError as error:
        fields = ", ".join(str(detail["loc"][0]) for detail in error.errors())
        raise UsageError(f"invalid setting: {fields}") from None
    categoriser = create_categoriser(args.backend, settings)
    slugs = {category.slug for category in categories}
    labels = [item.label for receipt in receipts for item in receipt.items if item.label]
    memory = LabelMemory() if args.memory else None

    started_at = datetime.now(UTC)
    counts: Counter[str] = Counter()
    kinds: Counter[str] = Counter()
    calibrated_calls: list[bool] = []
    receipt_seconds: list[float] = []
    calls: list[dict[str, Any]] = []
    try:
        load_started = time.perf_counter()
        try:
            categoriser.start()
        except BackendError as error:
            raise UsageError(error.message) from None
        load_seconds = round(time.perf_counter() - load_started, 3)
        print(f"model loaded in {load_seconds:.1f} s; {len(receipts)} receipt(s)", file=out)
        run_id = run_id_for(categoriser.name, categoriser.model_name, started_at)
        run_dir = make_run_dir(runs, f"{run_id}-items")
        with _open_private(run_dir / "predictions.jsonl") as predictions:
            for number, receipt in enumerate(receipts, start=1):
                lines, call = run_receipt(categoriser, categories, calibration, receipt, memory)
                for line in lines:
                    predictions.write(json.dumps(line, ensure_ascii=False) + "\n")
                    counts[f"{line['source']}_items"] += 1
                    counts["failed_items"] += line["error"] is not None
                predictions.flush()
                counts["receipts"] += 1
                if call["called"]:
                    calls.append({"diagnostics": call["diagnostics"]})
                    receipt_seconds.append(call["seconds"])
                    counts["receipts_failed"] += call["error"] is not None
                    if call["error"] is None:
                        kinds[call["score_kind"]] += 1
                        calibrated_calls.append(call["calibrated"])
                status = call.get("error") or "ok"
                print(f"{number}/{len(receipts)} {status}", file=out)
                if call.get("error") == "openrouter_provider_unverified":
                    print("stopped: an answer came from an unverified provider", file=out)
                    counts["stopped"] = 1
                    break
    finally:
        categoriser.stop()

    summary: dict[str, Any] = {
        "task": TASK,
        "run_id": run_dir.name,
        "backend": categoriser.name,
        "model_name": categoriser.model_name,
        "model_version": categoriser.model_version,
        "prompt_version": PROMPT_VERSION if categoriser.name != "stub" else None,
        "categories_version": categories_version(categories),
        "score_kinds": dict(sorted(kinds.items())),
        "calibrated": bool(calibrated_calls) and all(calibrated_calls),
        "calibration": None
        if calibration is None
        else {"labelled_items": calibration.labelled_items, "score_kind": calibration.score_kind},
        "memory": {
            "enabled": memory is not None,
            "rule": "strict majority of earlier labels with the same name key; "
            "confidence (k + 1) / (n + 1.25)",
            "categoriser_name": MEMORY_CATEGORISER,
            "prior_agreeing": PRIOR_AGREEING,
            "prior_disagreeing": PRIOR_DISAGREEING,
        },
        "git": git_commit(),
        "started_at": started_at.isoformat(),
        "finished_at": datetime.now(UTC).isoformat(),
        "load_seconds": load_seconds,
        "counts": {
            "receipts": counts["receipts"],
            "receipts_selected": len(receipts),
            "items": counts["memory_items"] + counts["model_items"],
            "labelled_items": len(labels),
            "labels_outside_categories": sum(1 for label in labels if label not in slugs),
            "memory_items": counts["memory_items"],
            "model_items": counts["model_items"],
            "failed_items": counts["failed_items"],
            "receipts_failed": counts["receipts_failed"],
        },
        "stopped": "openrouter_provider_unverified" if counts["stopped"] else None,
        "seconds_per_call": timing_summary(receipt_seconds),
        "seconds_per_model_item": (
            round(sum(receipt_seconds) / counts["model_items"], 3)
            if counts["model_items"]
            else None
        ),
        "cost_usd": cost_summary(calls),
    }
    total = [
        Decimal(c["diagnostics"]["cost_usd"]) for c in calls if c["diagnostics"].get("cost_usd")
    ]
    if summary["cost_usd"] is not None:
        summary["cost_usd"]["per_1000_items_usd"] = (
            _share(exact_sum(total) * 1000, counts["model_items"]) if total else None
        )
    write_private_json(run_dir / "run.json", summary)
    print_summary(summary, out)
    return summary


def print_summary(summary: dict[str, Any], out: TextIO) -> None:
    counts = summary["counts"]
    print(f"run {summary['run_id']}", file=out)
    print(
        "receipts {receipts}, items {items} (labelled {labelled_items}): memory "
        "{memory_items}, model {model_items}, failed {failed_items}".format(**counts),
        file=out,
    )
    timing = summary["seconds_per_call"]
    if timing["count"]:
        print(
            f"seconds per call: median {timing['median']}, p90 {timing['p90']}; "
            f"per model item {summary['seconds_per_model_item']}",
            file=out,
        )
    cost = summary.get("cost_usd")
    if cost is not None:
        print(f"cost: total ${cost['total_usd']}", file=out)


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
