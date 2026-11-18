"""A smoke test of a categoriser on the hand-written sanity set.

    uv run python -m evaluation.item_sanity --categories item_categories.json --backend mlx

The sanity set (`tests/fixtures/item_sanity_set.json`) is a few dozen invented
receipt items whose category is obvious. It is not an evaluation: it only
shows that a model and the prompt work at all, and how fast. The categoriser
runs in this process, exactly as the service runs it. The console shows counts
and timings, and with `--show-misses` the invented items that went wrong.
"""

import argparse
import json
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any, TextIO

from app.backends import create_backend
from app.backends.mlx_worker import MlxWorker
from app.categorise import SUGGESTING, CategoriseInput, create_categoriser
from app.config import Settings
from evaluation.common import UsageError, read_categories

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
    return parser.parse_args(argv)


def read_sanity_set(path: Path = SANITY_SET) -> list[dict[str, Any]]:
    receipts = json.loads(path.read_text(encoding="utf-8"))["receipts"]
    return [
        {"merchant": receipt["merchant"], "items": [tuple(item) for item in receipt["items"]]}
        for receipt in receipts
    ]


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    categories = read_categories(args.categories)
    overrides: dict[str, Any] = {"categorise_backend": args.backend}
    if args.model and args.backend == "mlx":
        overrides["mlx_categorise_model"] = args.model
    if args.model and args.backend == "openrouter":
        overrides["openrouter_categorise_model"] = args.model
    settings = Settings(**overrides)
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
            answer = categoriser.categorise(CategoriseInput(tuple(categories), texts, merchant))
            seconds.append(time.perf_counter() - began)
            for (name, gold), candidates in zip(receipt["items"], answer.candidates, strict=True):
                counts["items"] += 1
                best = candidates[0]
                right = best.slug == gold
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
    summary = {
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
    print(json.dumps(summary), file=out)
    if args.show_misses:
        for miss in misses:
            print(miss, file=out)
    return summary


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
