"""Item-category metrics of one item-category run.

**The run's format** (written by the item categoriser; `docs/decisions/0014-evaluation-harness.md`):
`RUNS_DIR/<run id>/run.json` with `"task": "item_categories"`, `run_id`, `backend`, `model_name`,
`model_version`, `prompt_version`, `git` (`sha`, `dirty`), `counts`, `seconds_per_item`,
`cost_usd` (null for a local model), `scores_calibrated` (true, false, or absent when not
known) and, for a combined run, `combined_from` (`[{"run_id", "backend", "model_name"}, ...]`); and
`predictions.jsonl`, one line per item:

    {"receipt_id": "rcpt_000123", "ground_truth_source": "manual", "position": 2,
     "candidates": [{"category_slug": "groceries/groceries", "score": 0.82}, ...],
     "source": "model", "seconds": 0.004, "cost_usd": null}

`position` is the item's 1-based place in the `items` of the ground-truth record named by
`ground_truth_source` (`dps_xml` or `manual`; when absent, the record the harness chooses); a card
slip's line has `position: null` and predicts the receipt's own category. `candidates`: up to
three, best first. `source`: an open set of short lower-case words (`memory`, `model`,
`decision`, `combined`, ...). `seconds` a number or a decimal string; `cost_usd` a decimal string
or null. `evaluation.item_categories_run` writes this format (it omits `ground_truth_source`, and
says `calibrated` and `memory` in `run.json`).

**Rows.** For every receipt the run has a line for, the reference record is
`GroundTruth.categories` (exclusions, precedence and the pre-fill rule on
`categories_prefilled_by`, against the run's own model and, for a combined run, every model it
combines). Each of its items with a `category_slug` is a row; an item without one
is not scored (`unlabelled_items`). A row without a prediction line counts as wrong, with the label
`_none` and confidence 0. A line for another source or a position the record does not have is not
scored (`unmatched_lines`). Card slips are not item rows: their receipt-level category is scored
apart (`card_slips`). A predicted slug that is not in the app's `group/category` form, or that no
ground-truth record uses, becomes `_other`: a model's free text never becomes a label (and it would
be wrong anyway).

**Metrics** reuse `categoriser.metrics`: macro-F1 (the main one: the mean F1 over categories that
are a true label or a top-1 prediction), weighted F1, accuracy, top-3 accuracy, with 95% intervals
from resampling whole receipts; precision at coverage levels and at confidence thresholds (the top
candidate's score is the confidence); the auto-accept point (the largest coverage at which the
precision of the kept rows is at least 95%); per-category support and F1; the confusion counts;
calibration (`calibration`: a reliability table over ten fixed bins, the expected calibration error
and the Brier score of the top candidate); the headline and calibration split by every `source`
value that occurs; seconds per item and the cost.
"""

import re
from collections import Counter
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any

import numpy as np

from app.decimals import exact_sum, wide_context
from categoriser.metrics import (
    HEADLINE,
    Encoded,
    coverage_curve,
    day_block_samples,
    headline,
    intervals,
    per_class_f1,
)
from evaluation.bootstrap import interval, rng_for
from evaluation.common import COST_PER_1000_PLACES, COST_PER_RECEIPT_PLACES, timing_summary
from evaluation.inputs import KNOWN_CATEGORY_SOURCES, ReceiptInfo, Run, seconds_value
from evaluation.truth import GroundTruth

SLUG = re.compile(r"\A[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*\Z")
NONE_LABEL = "_none"
OTHER_LABEL = "_other"
AUTO_ACCEPT_PRECISION = 0.95
CALIBRATION_BINS = 10
# `by_source` keys besides the run's sources: items with no prediction or no stated source, and
# lines whose source is neither known nor declared in `run.json`.
NO_SOURCE = "unstated"
OTHER_SOURCE = "other"


def clean_slug(value: Any, known: frozenset[str] | None = None) -> str:
    """A category slug (`group/category`) as a label; `_other` for anything else, and for a slug
    the ground truth never uses when `known` is given (free text never becomes a label)."""
    if not isinstance(value, str) or len(value) > 120 or not SLUG.match(value):
        return OTHER_LABEL
    if known is not None and value not in known:
        return OTHER_LABEL
    return value


@dataclass(frozen=True)
class Row:
    receipt_id: str
    position: int | None
    label: str
    ranked: tuple[str, ...]
    confidence: float
    source: str | None
    line: dict[str, Any] | None
    has_score: bool = False


@dataclass
class _Ranked:
    """The shape `categoriser.metrics.Encoded` reads: ranked labels and a confidence per row."""

    ranked: list[list[str]]
    confidence: np.ndarray


def seed_for(seed: int, *labels: str) -> int:
    return int(rng_for(seed, *labels).integers(0, 2**31 - 1))


def _row(
    receipt_id: str,
    position: int | None,
    label: str,
    line: dict[str, Any] | None,
    known: frozenset[str],
) -> Row:
    if line is None:
        return Row(receipt_id, position, label, (NONE_LABEL,), 0.0, None, None)
    candidates = line.get("candidates") or []
    ranked = tuple(clean_slug(c["category_slug"], known) for c in candidates) or (NONE_LABEL,)
    score = candidates[0].get("score") if candidates else None
    has_score = isinstance(score, int | float) and not isinstance(score, bool)
    confidence = min(1.0, max(0.0, float(score))) if has_score else 0.0
    return Row(receipt_id, position, label, ranked, confidence, line.get("source"), line, has_score)


def build_rows(
    run: Run, receipts: dict[str, ReceiptInfo], truth: GroundTruth
) -> tuple[list[Row], list[Row], dict[str, int]]:
    """The item rows and the card-slip rows of a run, and counts of what was left out."""
    lines: dict[tuple[str, str | None, int | None], dict[str, Any]] = {}
    covered: list[str] = []
    for line in run.records:
        key = (line["receipt_id"], line.get("ground_truth_source"), line.get("position"))
        lines[key] = line
        if line["receipt_id"] not in covered:
            covered.append(line["receipt_id"])
    counts: Counter[str] = Counter()
    used: set[tuple[str, str | None, int | None]] = set()
    items: list[Row] = []
    slips: list[Row] = []
    scored: set[str] = set()
    known = truth.category_slugs()

    def take(receipt_id: str, source: str, position: int | None) -> dict[str, Any] | None:
        for key in ((receipt_id, source, position), (receipt_id, None, position)):
            if key in lines:
                used.add(key)
                return lines[key]
        return None

    for receipt_id in sorted(covered):
        if receipt_id not in receipts:
            counts["receipts_not_in_receipt_set"] += 1
            continue
        chosen = truth.categories(receipt_id, run)
        if chosen.excluded_prefilled:
            counts["receipts_excluded_prefilled"] += 1
            counts["receipts_excluded_prefilled_unknown"] += chosen.reason == "unknown"
            continue
        record = chosen.record
        if record is None:
            counts["receipts_without_category_truth"] += 1
            continue
        counts["receipts"] += 1
        scored.add(receipt_id)
        if record.document.get("kind") == "card_slip":
            label = record.document.get("category_slug")
            line = take(receipt_id, record.source, None)
            if label is None:
                counts["unlabelled_card_slips"] += 1
            else:
                slips.append(_row(receipt_id, None, clean_slug(label), line, known))
            continue
        for position, item in enumerate(record.items, start=1):
            label = item.get("category_slug") if isinstance(item, dict) else None
            line = take(receipt_id, record.source, position)
            if label is None:
                counts["unlabelled_items"] += 1
                continue
            if line is None:
                counts["items_without_prediction"] += 1
            items.append(_row(receipt_id, position, clean_slug(label), line, known))
    counts["unmatched_lines"] = sum(1 for key in lines if key not in used and key[0] in scored)
    keys = (
        "receipts",
        "receipts_not_in_receipt_set",
        "receipts_excluded_prefilled",
        "receipts_excluded_prefilled_unknown",
        "receipts_without_category_truth",
        "unlabelled_items",
        "unlabelled_card_slips",
        "items_without_prediction",
        "unmatched_lines",
    )
    return items, slips, {key: int(counts.get(key, 0)) for key in keys}


def _scores_calibrated(run: Run) -> bool | None:
    """What the run says about its scores: `run.json`'s `scores_calibrated`, or `calibrated` as
    `evaluation.item_categories_run` writes it (true when the scores were calibrated, for example
    by `evaluation.item_categories_calibrate`), null when it says neither."""
    for key in ("scores_calibrated", "calibrated"):
        value = run.meta.get(key)
        if isinstance(value, bool):
            return value
    return None


def encode(rows: list[Row], systems: dict[str, list[Row]] | None = None) -> Encoded:
    """`rows` as one system named `run`, or several systems over the same rows."""
    systems = systems or {"run": rows}
    return Encoded(
        [row.label for row in rows],
        {
            name: _Ranked(
                [list(row.ranked) for row in system_rows],
                np.array([row.confidence for row in system_rows], dtype=float),
            )
            for name, system_rows in systems.items()
        },
    )


def auto_accept(correct: np.ndarray, confidence: np.ndarray) -> dict[str, Any]:
    """The largest coverage whose kept rows (the most confident first, whole tie groups) have a
    precision of at least `AUTO_ACCEPT_PRECISION`."""
    n = len(correct)
    best: dict[str, Any] = {
        "target_precision": AUTO_ACCEPT_PRECISION,
        "coverage": 0.0,
        "rows": 0,
        "precision": None,
        "min_confidence": None,
    }
    if n == 0:
        return best
    for threshold in sorted(set(confidence.tolist()), reverse=True):
        kept = confidence >= threshold
        precision = float(correct[kept].mean())
        if precision >= AUTO_ACCEPT_PRECISION:
            best.update(
                coverage=int(kept.sum()) / n,
                rows=int(kept.sum()),
                precision=precision,
                min_confidence=float(threshold),
            )
    return best


def headline_block(rows: list[Row], *, seed: int, resamples: int) -> dict[str, Any]:
    if not rows:
        return {"items": 0, **{metric: {"value": None, "ci95": None} for metric in HEADLINE}}
    encoded = encode(rows)
    point = headline(encoded.true, encoded.top1["run"], encoded.in_top3["run"], len(encoded.labels))
    samples = day_block_samples(
        encoded, [row.receipt_id for row in rows], resamples=resamples, seed=seed
    )
    ci = intervals(samples)["run"]
    return {
        "items": len(rows),
        **{metric: {"value": point[metric], "ci95": ci[metric]} for metric in HEADLINE},
    }


def _calibration_point(confidence: np.ndarray, correct: np.ndarray) -> tuple[float, float]:
    """(ECE over the fixed bins, Brier score of the top candidate)."""
    bins = np.minimum((confidence * CALIBRATION_BINS).astype(int), CALIBRATION_BINS - 1)
    counts = np.bincount(bins, minlength=CALIBRATION_BINS)
    hits = np.bincount(bins, weights=correct.astype(float), minlength=CALIBRATION_BINS)
    sums = np.bincount(bins, weights=confidence, minlength=CALIBRATION_BINS)
    filled = counts > 0
    gap = np.abs(hits[filled] / counts[filled] - sums[filled] / counts[filled])
    ece = float((counts[filled] / len(confidence) * gap).sum())
    brier = float(np.mean((confidence - correct.astype(float)) ** 2))
    return ece, brier


def calibration(rows: list[Row], *, seed: int, resamples: int) -> dict[str, Any]:
    """Whether the top candidate's score means what it says (rows with a score only).

    Bins: `CALIBRATION_BINS` equal-width bins of the score over [0, 1] (the last one closed), fixed
    rather than fitted to the data, so two runs are binned alike. ECE: the bins' gaps between the
    share correct and the mean score, weighted by their share of rows. Brier score: the mean of
    (score - correct)^2 for the top candidate. Intervals: resampling whole receipts."""
    scored = [row for row in rows if row.has_score]
    result: dict[str, Any] = {
        "rows": len(scored),
        "rows_without_score": len(rows) - len(scored),
        "bins": [],
        "ece": {"value": None, "ci95": None},
        "brier": {"value": None, "ci95": None},
    }
    if not scored:
        return result
    confidence = np.array([row.confidence for row in scored])
    correct = np.array([row.ranked[0] == row.label for row in scored])
    bins = np.minimum((confidence * CALIBRATION_BINS).astype(int), CALIBRATION_BINS - 1)
    for b in range(CALIBRATION_BINS):
        members = bins == b
        count = int(members.sum())
        result["bins"].append(
            {
                "low": b / CALIBRATION_BINS,
                "high": (b + 1) / CALIBRATION_BINS,
                "rows": count,
                "mean_score": float(confidence[members].mean()) if count else None,
                "share_correct": float(correct[members].mean()) if count else None,
            }
        )
    ece, brier = _calibration_point(confidence, correct)
    groups: dict[str, list[int]] = {}
    for i, row in enumerate(scored):
        groups.setdefault(row.receipt_id, []).append(i)
    blocks = [np.array(members) for members in groups.values()]
    rng = np.random.default_rng(seed)
    ece_samples = np.empty(resamples)
    brier_samples = np.empty(resamples)
    for i in range(resamples):
        chosen = rng.integers(0, len(blocks), size=len(blocks))
        index = np.concatenate([blocks[j] for j in chosen])
        ece_samples[i], brier_samples[i] = _calibration_point(confidence[index], correct[index])
    result["ece"] = {"value": ece, "ci95": interval(ece_samples)}
    result["brier"] = {"value": brier, "ci95": interval(brier_samples)}
    return result


def _cost(rows: list[Row]) -> dict[str, Any] | None:
    values = [row.line.get("cost_usd") for row in rows if row.line is not None]
    if not any(value is not None for value in values):
        return None
    known: list[Decimal] = []
    for value in values:
        try:
            cost = Decimal(value) if isinstance(value, str) else None
        except InvalidOperation:
            cost = None
        if cost is not None and cost.is_finite() and cost >= 0:
            known.append(cost)
    total = exact_sum(known)
    per_item = per_1000 = None
    if known:
        with wide_context():
            per_item = format((total / len(known)).quantize(COST_PER_RECEIPT_PLACES), "f")
            per_1000 = format((total * 1000 / len(known)).quantize(COST_PER_1000_PLACES), "f")
    return {
        "total_usd": format(total, "f"),
        "items_with_cost": len(known),
        "items_without_cost": len(values) - len(known),
        "complete": len(known) == len(values),
        "per_item_usd": per_item,
        "per_1000_items_usd": per_1000,
    }


@dataclass
class CategoryRunScores:
    run: Run
    rows: list[Row]
    slips: list[Row]
    result: dict[str, Any]


def score_run(
    run: Run,
    receipts: dict[str, ReceiptInfo],
    truth: GroundTruth,
    *,
    seed: int,
    resamples: int,
) -> CategoryRunScores:
    rows, slips, counts = build_rows(run, receipts, truth)
    result: dict[str, Any] = {"counts": counts}
    result["headline"] = headline_block(
        rows, seed=seed_for(seed, run.run_id, "all"), resamples=resamples
    )
    if rows:
        encoded = encode(rows)
        correct = encoded.true == encoded.top1["run"]
        confidence = encoded.confidence["run"]
        curve = coverage_curve(correct, confidence)
        f1, support = per_class_f1(encoded.true, encoded.top1["run"], len(encoded.labels))
        predicted = np.bincount(encoded.top1["run"], minlength=len(encoded.labels))
        per_class = [
            {
                "category_slug": label,
                "support": int(support[i]),
                "predicted": int(predicted[i]),
                "f1": float(f1[i]),
            }
            for i, label in enumerate(encoded.labels)
            if support[i] or predicted[i]
        ]
        confusion: dict[str, dict[str, int]] = {}
        for row in rows:
            cell = confusion.setdefault(row.label, {})
            cell[row.ranked[0]] = cell.get(row.ranked[0], 0) + 1
        result["coverage"] = curve
        result["auto_accept"] = auto_accept(correct, confidence)
        result["per_class"] = per_class
        result["confusion"] = confusion
    else:
        result["coverage"] = None
        result["auto_accept"] = auto_accept(np.zeros(0, dtype=bool), np.zeros(0))
        result["per_class"] = []
        result["confusion"] = {}
    result["calibration"] = calibration(
        rows, seed=seed_for(seed, run.run_id, "calibration"), resamples=resamples
    )
    result["calibration"]["scores_calibrated"] = _scores_calibrated(run)
    allowed = KNOWN_CATEGORY_SOURCES | run.declared_sources

    def source_of(row: Row) -> str:
        if not row.source:
            return NO_SOURCE
        return row.source if row.source in allowed else OTHER_SOURCE

    sources = sorted({source_of(row) for row in rows})
    result["by_source"] = {
        source: {
            **headline_block(
                [row for row in rows if source_of(row) == source],
                seed=seed_for(seed, run.run_id, "source", source),
                resamples=resamples,
            ),
            "calibration": calibration(
                [row for row in rows if source_of(row) == source],
                seed=seed_for(seed, run.run_id, "calibration", source),
                resamples=resamples,
            ),
        }
        for source in sources
    }
    slip_correct = [row.ranked[0] == row.label for row in slips]
    slip_top3 = [row.label in row.ranked for row in slips]
    result["card_slips"] = {
        "receipts": len(slips),
        "accuracy": float(np.mean(slip_correct)) if slips else None,
        "top3_accuracy": float(np.mean(slip_top3)) if slips else None,
    }
    predicted_rows = [row for row in rows + slips if row.line is not None]
    seconds = [
        seconds_value(row.line.get("seconds")) for row in predicted_rows if row.line is not None
    ]
    result["seconds_per_item"] = timing_summary(value for value in seconds if value is not None)
    result["cost_usd"] = _cost(predicted_rows)
    return CategoryRunScores(run=run, rows=rows, slips=slips, result=result)


def diagnostics(scores: CategoryRunScores) -> list[dict[str, Any]]:
    """Per-item detail for the private diagnostics folder (never for `eval/results/`)."""
    return [
        {
            "receipt_id": row.receipt_id,
            "position": row.position,
            "label": row.label,
            "ranked": list(row.ranked),
            "confidence": row.confidence,
            "source": row.source,
        }
        for row in scores.rows + scores.slips
    ]
