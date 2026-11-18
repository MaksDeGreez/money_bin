"""A smoke test of a categoriser on the hand-written sanity set.

    uv run python -m evaluation.item_sanity --categories item_categories.json --backend mlx

The sanity set (`tests/fixtures/item_sanity_set.json`) is a few dozen invented
receipt items whose category is obvious. It is not an evaluation: it only
shows that a model and the prompt work at all, and how fast. The categoriser
runs in this process, exactly as the service runs it. The console shows counts
and timings, and with `--show-misses` the invented items that went wrong.

The summary also gives the top-score distribution, a reliability table (accuracy
per band of the best candidate's score), the share of items that could be
accepted automatically at 95% precision, and for a hosted model the requests,
seconds and dollars per item. Receipts marked `"set": "extension"` were added
later; `by_set` keeps the original 43 items comparable with earlier figures.

With `--backend decisions` (`DECISIONS_MODEL` or `--model`): `--strategy`,
`--no-receipt-context` and `--max-questions` as in `item_categories_run`, and
`--verify`, which then checks the candidates of the run it just made with one
yes/no question each and reports the verified scores too.
"""

import argparse
import json
import sys
import time
from collections.abc import Sequence
from decimal import Decimal
from pathlib import Path
from typing import Any, TextIO

from app.backends import create_backend
from app.backends.mlx_worker import MlxWorker
from app.categorise import SUGGESTING, CategoriseInput, create_categoriser
from app.categorise.base import Categorisation
from app.categorise.decisions import DecisionsCategoriser
from app.config import Settings
from app.decimals import exact_sum
from evaluation.common import UsageError, read_categories
from evaluation.item_scores import Scored
from evaluation.item_scores import summary as summary_of

SANITY_SET = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "item_sanity_set.json"


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.item_sanity",
        description="Run a categoriser over the invented sanity set and print counts.",
    )
    parser.add_argument("--categories", required=True, type=Path, help="the exported categories")
    parser.add_argument("--backend", default="mlx", choices=SUGGESTING)
    parser.add_argument("--model", help="the model id (MLX_CATEGORISE_MODEL, or the hosted one)")
    parser.add_argument(
        "--no-merchant", action="store_true", help="leave the shop's name out, as a hosted model"
    )
    parser.add_argument(
        "--with-ocr-model",
        action="store_true",
        help="load the mlx OCR backend too (the shared model and worker), as the service does",
    )
    parser.add_argument("--show-misses", action="store_true", help="print the invented misses")
    decisions = parser.add_argument_group("--backend decisions")
    decisions.add_argument("--strategy", choices=("flat", "two-stage"), default="flat")
    decisions.add_argument("--no-receipt-context", action="store_true")
    decisions.add_argument("--max-questions", type=int)
    decisions.add_argument("--verify", action="store_true", help="also verify the candidates")
    args = parser.parse_args(argv)
    if args.backend != DecisionsCategoriser.name and (
        args.verify or args.no_receipt_context or args.max_questions or args.strategy != "flat"
    ):
        parser.error(
            "--strategy, --no-receipt-context, --max-questions and --verify need "
            "--backend decisions"
        )
    return args


def read_sanity_set(path: Path = SANITY_SET) -> list[dict[str, Any]]:
    receipts = json.loads(path.read_text(encoding="utf-8"))["receipts"]
    return [
        {
            "merchant": receipt["merchant"],
            "set": receipt.get("set", "base"),
            "items": [tuple(item) for item in receipt["items"]],
        }
        for receipt in receipts
    ]


class Accounts:
    """The hosted calls of a sanity run: requests, questions, tokens, dollars."""

    def __init__(self) -> None:
        self.calls = 0
        self.questions = 0
        self.tokens: list[int] = []
        self.costs: list[Decimal | None] = []

    def add(self, answer: Categorisation) -> None:
        diagnostics = answer.diagnostics
        if "model_calls" not in diagnostics:
            return
        self.calls += diagnostics["model_calls"]
        self.questions += diagnostics.get("questions", 0)
        if diagnostics.get("prompt_tokens") is not None:
            self.tokens.append(diagnostics["prompt_tokens"])
        cost = diagnostics.get("cost_usd")
        self.costs.append(None if cost is None else Decimal(cost))

    def as_dict(self, items: int) -> dict[str, Any] | None:
        if not self.calls:
            return None
        known = [cost for cost in self.costs if cost is not None]
        total = exact_sum(known)
        return {
            "requests": self.calls,
            "questions": self.questions,
            "input_tokens": sum(self.tokens) if self.tokens else None,
            "input_tokens_per_item": round(sum(self.tokens) / items, 1) if self.tokens else None,
            "cost_usd": format(total, "f"),
            "cost_complete": len(known) == len(self.costs),
            "cost_per_item_usd": format(total / items, ".8f") if items else None,
        }


def _settings(args: argparse.Namespace) -> Settings:
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
        if args.max_questions:
            overrides["decisions_max_questions"] = args.max_questions
    return Settings(**overrides)


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    categories = read_categories(args.categories)
    settings = _settings(args)
    worker = MlxWorker()
    ocr = create_backend("mlx", settings, worker=worker) if args.with_ocr_model else None
    categoriser = create_categoriser(args.backend, settings, worker=worker)
    slugs = {category.slug for category in categories}
    receipts = read_sanity_set()
    for receipt in receipts:
        for _, slug in receipt["items"]:
            if slug not in slugs:
                raise UsageError(f"the sanity set names {slug}, which the categories file lacks")
    counts = {"items": 0, "top1": 0, "top3": 0, "best_at_least_0_9": 0, "wrong_at_least_0_9": 0}
    seconds: list[float] = []
    misses: list[str] = []
    scored: list[Scored] = []
    by_set: dict[str, list[Scored]] = {}
    verified: list[Scored] = []
    accounts = Accounts()
    try:
        started = time.perf_counter()
        if ocr is not None:
            ocr.start()
        categoriser.start()
        print(f"loaded in {time.perf_counter() - started:.1f} s", file=out)
        for receipt in receipts:
            texts = tuple(name for name, _ in receipt["items"])
            merchant = None if args.no_merchant else receipt["merchant"]
            began = time.perf_counter()
            request = CategoriseInput(tuple(categories), texts, merchant)
            answer = categoriser.categorise(request)
            seconds.append(time.perf_counter() - began)
            accounts.add(answer)
            if args.verify:
                assert isinstance(categoriser, DecisionsCategoriser)
                checked = categoriser.verify(
                    request, [[c.slug for c in item] for item in answer.candidates]
                )
                accounts.add(checked)
                for (_, gold), candidates in zip(receipt["items"], checked.candidates, strict=True):
                    verified.append(
                        Scored(
                            tuple(c.slug for c in candidates),
                            candidates[0].score if candidates else 0.0,
                            gold,
                        )
                    )
            for (name, gold), candidates in zip(receipt["items"], answer.candidates, strict=True):
                counts["items"] += 1
                best = candidates[0]
                right = best.slug == gold
                entry = Scored(tuple(c.slug for c in candidates), best.score, gold)
                scored.append(entry)
                by_set.setdefault(receipt["set"], []).append(entry)
                counts["top1"] += right
                counts["top3"] += gold in [candidate.slug for candidate in candidates]
                if best.score >= 0.9:
                    counts["best_at_least_0_9"] += 1
                    counts["wrong_at_least_0_9"] += not right
                if not right:
                    misses.append(f"{name}: {gold} -> {best.slug} ({best.score:.3f})")
    finally:
        categoriser.stop()
        if ocr is not None:
            ocr.stop()
    report: dict[str, Any] = {
        **counts,
        "receipts": len(receipts),
        "seconds_total": round(sum(seconds), 2),
        "seconds_first_receipt": round(seconds[0], 2) if seconds else None,
        "seconds_per_item_after_first": (
            round(sum(seconds[1:]) / max(1, counts["items"] - len(receipts[0]["items"])), 3)
            if len(seconds) > 1
            else None
        ),
    }
    details = summary_of(scored)
    report["by_set"] = {
        name: {"items": len(entries), "top1": sum(e.correct for e in entries)}
        for name, entries in by_set.items()
    }
    report["scores"] = {key: value for key, value in details.items() if key not in counts}
    report["hosted"] = accounts.as_dict(counts["items"])
    if args.verify:
        report["verified"] = summary_of(verified)
    print(json.dumps(report, ensure_ascii=False), file=out)
    if args.show_misses:
        for miss in misses:
            print(miss, file=out)
    return report


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
