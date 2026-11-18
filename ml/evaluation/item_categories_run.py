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

With `--backend decisions` (a decision model on OpenRouter, `DECISIONS_MODEL`
or `--model`): `--strategy flat|two-stage`, `--no-receipt-context` (each item
alone), `--max-questions N` (questions per request), `--examples K` (up to K
similar items already labelled in EARLIER receipts, from the label memory's
store, shown to the model as examples) and `--verify RUN_DIR` (instead of
categorising, check the candidates another run gave each item: one yes/no
question per candidate, its probability the new score). Only item names and
the category text are sent (`app.categorise.decisions`).

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
from app.categorise import SUGGESTING, CategoriseInput, Categoriser, create_categoriser
from app.categorise.calibration import Calibration, CalibrationError, calibrate, load_calibration
from app.categorise.decisions import DecisionsCategoriser
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
# The most labelled examples per item shown to a decision model.
MAX_EXAMPLES = 5


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
    # The categoriser whose suggestions were on the form when the labels were chosen (the record's
    # `categories_prefilled_by`), for the pre-fill rule; None when none was.
    categories_prefilled_by: str | None = None


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.item_categories_run",
        description="Run the item categoriser over labelled items and write a run folder.",
    )
    parser.add_argument("--ground-truth", required=True, type=Path, help="ground_truth.jsonl")
    parser.add_argument("--ingest", required=True, type=Path, help="the receipt set folder")
    parser.add_argument("--categories", required=True, type=Path, help="the exported categories")
    parser.add_argument("--out", required=True, type=Path, help="the folder for run folders")
    parser.add_argument("--backend", default="mlx", choices=SUGGESTING)
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
    decisions = parser.add_argument_group("--backend decisions")
    decisions.add_argument("--strategy", choices=("flat", "two-stage"), default="flat")
    decisions.add_argument("--no-receipt-context", action="store_true", help="send each item alone")
    decisions.add_argument("--max-questions", type=int, help="questions per request")
    decisions.add_argument(
        "--examples",
        type=int,
        default=0,
        help=f"similar items of earlier receipts as examples (at most {MAX_EXAMPLES})",
    )
    decisions.add_argument("--verify", type=Path, help="check the candidates of this run folder")
    args = parser.parse_args(argv)
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be 1 or more")
    decision_options = (
        args.strategy != "flat",
        args.no_receipt_context,
        args.max_questions is not None,
        args.examples != 0,
        args.verify is not None,
    )
    if args.backend != DecisionsCategoriser.name and any(decision_options):
        parser.error(
            "--strategy, --no-receipt-context, --max-questions, --examples and "
            "--verify need --backend decisions"
        )
    if not 0 <= args.examples <= MAX_EXAMPLES or (
        args.max_questions is not None and args.max_questions < 1
    ):
        parser.error(f"--examples must be 0 to {MAX_EXAMPLES} and --max-questions 1 or more")
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
    chosen: dict[str, tuple[tuple[int, int], dict[str, Any], str | None]] = {}
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
            prefilled = line.get("categories_prefilled_by")
            chosen[ingest_id] = (rank, document, prefilled if isinstance(prefilled, str) else None)
    receipts = []
    for ingest_id, ((unknown, _), document, prefilled) in chosen.items():
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
                    None if unknown else prefilled,
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


def read_proposals(run_dir: Path) -> dict[tuple[str, int], list[str]]:
    """The candidates' slugs per item of an item-category run folder (for `--verify`)."""
    path = run_dir.expanduser() / "predictions.jsonl"
    if not path.is_file():
        raise UsageError(f"--verify: no predictions.jsonl in {run_dir.name}")
    proposals = {}
    for line in read_jsonl(path):
        try:
            key = (str(line["receipt_id"]), int(line["position"]))
            proposals[key] = [str(c["category_slug"]) for c in line["candidates"]]
        except (KeyError, TypeError, ValueError):
            raise UsageError(f"--verify: {run_dir.name} is not an item-category run") from None
    return proposals


def read_summary(run_dir: Path) -> dict[str, Any]:
    """A run folder's `run.json` (for `--verify`)."""
    path = run_dir.expanduser() / "run.json"
    try:
        summary = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise UsageError(f"--verify: no readable run.json in {run_dir.name}") from None
    if not isinstance(summary, dict):
        raise UsageError(f"--verify: no readable run.json in {run_dir.name}")
    return summary


MEMORY_ENTRY = {"backend": MEMORY_CATEGORISER, "model_name": MEMORY_CATEGORISER}


def categoriser_entries(summary: dict[str, Any]) -> list[dict[str, Any]]:
    """Every categoriser behind a run, as `combined_from` entries (`run_id`, `backend`,
    `model_name`, `model_version`): the run's own model, the label memory when it answered first,
    and whatever the run itself combined. The evaluation harness applies the pre-fill rule to
    every `model_name` in a run's `combined_from` (`evaluation/inputs.py`)."""
    own = {
        key: summary.get(key)
        for key in ("run_id", "backend", "model_name", "model_version")
        if isinstance(summary.get(key), str) and summary.get(key)
    }
    entries = [own] if own.get("model_name") else []
    if (summary.get("memory") or {}).get("enabled"):
        entries.append(dict(MEMORY_ENTRY))
    entries += [entry for entry in summary.get("combined_from") or [] if isinstance(entry, dict)]
    return entries


def run_categorisers(summary: dict[str, Any]) -> list[str]:
    """Every categoriser name a run's `run.json` names, for the pre-fill rule."""
    names = {
        entry["model_name"]
        for entry in categoriser_entries(summary)
        if isinstance(entry.get("model_name"), str)
    }
    return sorted(names - {""})


@dataclass(frozen=True)
class DecisionOptions:
    """What `--backend decisions` adds: labelled examples and the run to verify."""

    examples: int = 0
    proposals: dict[tuple[str, int], list[str]] | None = None


def run_receipt(
    categoriser: Categoriser,
    categories: tuple[CategoryOption, ...],
    calibration: Calibration | None,
    receipt: Receipt,
    memory: LabelMemory | None,
    store: LabelMemory | None = None,
    options: DecisionOptions | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """The predictions lines of one receipt, and what its call reported.

    `store` holds the labels of earlier receipts for the decision model's examples (the same
    object as `memory` when both are used).
    """
    options = options or DecisionOptions()
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
        examples: tuple[tuple[tuple[str, str], ...], ...] = ()
        if store is not None and options.examples:
            examples = tuple(
                tuple(store.similar(item.name, options.examples)) for item in remaining
            )
        error = None
        try:
            request = CategoriseInput(categories, texts, receipt.merchant, examples)
            if options.proposals is not None:
                assert isinstance(categoriser, DecisionsCategoriser)
                answer = categoriser.verify(
                    request,
                    [
                        options.proposals.get((receipt.ingest_id, item.position), [])
                        for item in remaining
                    ],
                )
            else:
                answer = categoriser.categorise(request)
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
            call["prompt_version"] = answer.prompt_version
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
    for known in {id(m): m for m in (memory, store) if m is not None}.values():
        # This receipt's labels are known to the memory only from the next receipt on.
        for item in receipt.items:
            if item.label:
                known.add(item.name, item.label)
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
    if args.backend == DecisionsCategoriser.name:
        if args.model:
            overrides["decisions_model"] = args.model
        overrides["decisions_strategy"] = args.strategy
        overrides["decisions_receipt_context"] = not args.no_receipt_context
        if args.max_questions is not None:
            overrides["decisions_max_questions"] = args.max_questions
    proposals = read_proposals(args.verify) if args.verify else None
    verified = read_summary(args.verify) if args.verify else None
    try:
        settings = Settings(**overrides)
    except ValidationError as error:
        fields = ", ".join(str(detail["loc"][0]) for detail in error.errors())
        raise UsageError(f"invalid setting: {fields}") from None
    categoriser = create_categoriser(args.backend, settings)
    slugs = {category.slug for category in categories}
    labels = [item.label for receipt in receipts for item in receipt.items if item.label]
    memory = LabelMemory(allowed=slugs) if args.memory else None
    store = (memory or LabelMemory(allowed=slugs)) if args.examples else None
    decision_options = DecisionOptions(examples=args.examples, proposals=proposals)

    started_at = datetime.now(UTC)
    counts: Counter[str] = Counter()
    kinds: Counter[str] = Counter()
    prompt_versions: Counter[str] = Counter()
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
                lines, call = run_receipt(
                    categoriser, categories, calibration, receipt, memory, store, decision_options
                )
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
                        prompt_versions[str(call["prompt_version"])] += 1
                        calibrated_calls.append(call["calibrated"])
                status = call.get("error") or "ok"
                print(f"{number}/{len(receipts)} {status}", file=out)
                if call.get("error") == "openrouter_provider_unverified":
                    print("stopped: an answer came from an unverified provider", file=out)
                    counts["stopped"] = 1
                    break
    finally:
        # The endpoints the decision model's requests were limited to (`stop` forgets them).
        catalogue = (
            categoriser.client.catalogue if isinstance(categoriser, DecisionsCategoriser) else None
        )
        zdr_endpoints = list(catalogue.endpoints) if catalogue else []
        categoriser.stop()

    summary: dict[str, Any] = {
        "task": TASK,
        "run_id": run_dir.name,
        "backend": categoriser.name,
        "model_name": categoriser.model_name,
        "model_version": categoriser.model_version,
        # A decision model's prompt version names its mode (verify, examples): the answers' own.
        "prompt_version": (
            (next(iter(prompt_versions)) if len(prompt_versions) == 1 else None)
            if isinstance(categoriser, DecisionsCategoriser)
            else PROMPT_VERSION
            if categoriser.name != "stub"
            else None
        ),
        "prompt_versions": dict(sorted(prompt_versions.items())),
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
        # The other categoriser behind this run's answers, for the pre-fill rule (the harness
        # reads `combined_from`): the label memory when it supplied examples, and every
        # categoriser of a verified run (its candidates are that run's suggestions, re-scored).
        **(
            {"combined_from": extra}
            if (
                extra := ([dict(MEMORY_ENTRY)] if store is not None and memory is None else [])
                + (categoriser_entries(verified) if verified is not None else [])
            )
            else {}
        ),
        "decisions": None
        if not isinstance(categoriser, DecisionsCategoriser)
        else {
            "strategy": "verify" if proposals is not None else categoriser.strategy,
            "categorise_strategy": categoriser.strategy,
            "receipt_context": categoriser.receipt_context,
            "max_questions": categoriser.max_questions,
            "examples_per_item": args.examples,
            "verified_run": args.verify.name if args.verify else None,
            "items_without_proposal": None
            if proposals is None
            else sum(
                (receipt.ingest_id, item.position) not in proposals
                for receipt in receipts
                for item in receipt.items
            ),
            "zdr_endpoints": zdr_endpoints,
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
