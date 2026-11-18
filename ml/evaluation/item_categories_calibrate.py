"""Fit a calibration of the item categoriser's scores from a run and the labels.

    uv run python -m evaluation.item_categories_calibrate \\
        --run ~/Documents/money_bin_data/runs/<run id> \\
        --ground-truth ~/Documents/money_bin_data/exports/ground_truth.jsonl

The run (`evaluation.item_categories_run`, without `--calibration`) holds the
model's raw scores; the ground truth holds the person's labels. For every
labelled item the model answered, the pair (best candidate's score, whether
it was right) goes into an isotonic regression: a monotone step function from
score to the share of right answers. Its breakpoints are written to a JSON
file that the service reads (`CATEGORISE_CALIBRATION_FILE`), with the backend,
model, prompt version and score kind it is valid for. Items the label memory
answered are left out: they have their own rule. So are the receipts whose
labels were chosen with this model's suggestions on screen (the ground truth's
`categories_prefilled_by` names it, or is `source:unknown`): a person who takes
confident suggestions makes them "right" by construction, which would inflate
exactly the high scores a threshold uses.

The file goes to `--out` (default `~/Documents/money_bin_data/models/`), which
must be outside any git repository; it holds numbers only, but it is fitted on
personal labels. The console prints counts and the share of items that
would pass a 95% threshold on these same items, which is optimistic: fit on
one part of the labelled receipts and evaluate on another (`--ids`).
"""

import argparse
import hashlib
import json
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TextIO

from app.categorise.calibration import FORMAT, FORMAT_VERSION
from evaluation.common import (
    UsageError,
    ensure_private_folder,
    inside_git_repository,
    read_jsonl,
    write_private_json,
)
from evaluation.item_categories_run import TASK, prefilled_by_run, read_ground_truth
from evaluation.ocr_run import read_ids

DEFAULT_OUT = Path("~/Documents/money_bin_data/models")
MIN_ITEMS = 30
TARGET_PRECISION = 0.95


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.item_categories_calibrate",
        description="Fit an isotonic calibration of the categoriser's scores.",
    )
    parser.add_argument("--run", required=True, type=Path, help="an item_categories run folder")
    parser.add_argument("--ground-truth", required=True, type=Path, help="ground_truth.jsonl")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the folder for the file")
    parser.add_argument("--ids", type=Path, help="fit on these receipt ids only")
    parser.add_argument("--min-items", type=int, default=MIN_ITEMS, help="refuse fewer pairs")
    return parser.parse_args(argv)


def read_run(run_dir: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    summary_path = run_dir / "run.json"
    if not summary_path.is_file() or not (run_dir / "predictions.jsonl").is_file():
        raise UsageError(f"not a run folder: {run_dir}")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    if summary.get("task") != TASK:
        raise UsageError("the run is not an item_categories run")
    if summary.get("calibrated"):
        raise UsageError("the run's scores are calibrated already; fit on a run without one")
    kinds = summary.get("score_kinds") or {}
    if len(kinds) != 1:
        raise UsageError("the run's answers have more than one score kind (or none)")
    if len(summary.get("prompt_versions") or {}) > 1:
        raise UsageError("the run's answers come from more than one prompt version")
    return summary, list(read_jsonl(run_dir / "predictions.jsonl"))


def pairs(
    predictions: list[dict[str, Any]], labels: dict[tuple[str, int], str], ids: set[str] | None
) -> list[tuple[float, int]]:
    """(best score, 1 if right else 0) for each labelled item the model answered."""
    result = []
    for line in predictions:
        if line.get("source") != "model" or not line.get("candidates"):
            continue
        if ids is not None and line.get("receipt_id") not in ids:
            continue
        label = labels.get((line.get("receipt_id"), line.get("position")))
        if label is None:
            continue
        best = line["candidates"][0]
        result.append((float(best["score"]), int(best["category_slug"] == label)))
    return result


UNKNOWN_CATEGORISER = "source:unknown"


def prefilled_by(categoriser: str | None, model_name: str) -> bool:
    """Whether labels chosen with `categoriser`'s suggestions on screen are this model's own."""
    return categoriser is not None and categoriser.strip() in (model_name, UNKNOWN_CATEGORISER)


def fit(points: list[tuple[float, int]]) -> tuple[list[float], list[float]]:
    from sklearn.isotonic import IsotonicRegression

    model = IsotonicRegression(y_min=0.0, y_max=1.0, increasing=True, out_of_bounds="clip")
    model.fit([score for score, _ in points], [right for _, right in points])
    xs = [float(value) for value in model.X_thresholds_]
    ys = [float(value) for value in model.y_thresholds_]
    return xs, ys


def coverage_at(points: list[tuple[float, int]], mapped: list[float], target: float) -> float:
    kept = sum(1 for value in mapped if value >= target)
    return kept / len(points) if points else 0.0


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    from app.categorise.calibration import Calibration

    folder = args.out.expanduser().resolve()
    if inside_git_repository(folder):
        raise UsageError("--out is inside a git repository")
    summary, predictions = read_run(args.run.expanduser())
    receipts = read_ground_truth(args.ground_truth.expanduser())
    labels = {
        (receipt.ingest_id, item.position): item.label
        for receipt in receipts
        if not prefilled_by_run(receipt.categories_prefilled_by, summary)
        for item in receipt.items
        if item.label
    }
    ids = set(read_ids(args.ids)) if args.ids else None
    points = pairs(predictions, labels, ids)
    if len(points) < args.min_items:
        raise UsageError(f"only {len(points)} labelled item(s) to fit on; need {args.min_items}")
    xs, ys = fit(points)
    (score_kind,) = summary["score_kinds"]
    calibration = Calibration(
        backend=summary["backend"],
        model_name=summary["model_name"],
        prompt_version=summary["prompt_version"],
        score_kind=score_kind,
        xs=tuple(xs),
        ys=tuple(ys),
        labelled_items=len(points),
    )
    mapped = [calibration.map(score) for score, _ in points]
    accuracy = sum(right for _, right in points) / len(points)
    document = {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "backend": calibration.backend,
        "model_name": calibration.model_name,
        "model_version": summary.get("model_version"),
        "prompt_version": calibration.prompt_version,
        "score_kind": score_kind,
        "method": "isotonic",
        "xs": xs,
        "ys": ys,
        "labelled_items": len(points),
        "accuracy": round(accuracy, 4),
        "fitted_at": datetime.now(UTC).isoformat(),
        "run_id": summary.get("run_id"),
        "ground_truth_sha256": hashlib.sha256(
            args.ground_truth.expanduser().read_bytes()
        ).hexdigest(),
    }
    ensure_private_folder(folder)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    path = folder / f"item-categoriser-calibration-{stamp}-{summary.get('run_id', 'run')}.json"
    write_private_json(path, document)
    share = coverage_at(points, mapped, TARGET_PRECISION)
    print(f"fitted on {len(points)} item(s); accuracy {accuracy:.3f}", file=out)
    print(
        f"share of these items at a calibrated score of {TARGET_PRECISION} or more: {share:.3f} "
        "(on the items it was fitted on: optimistic)",
        file=out,
    )
    print(f"written: {path.name}", file=out)
    return {"path": str(path), "items": len(points), "accuracy": accuracy, "coverage_95": share}


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
