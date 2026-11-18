"""How well item candidates match known labels: accuracy, top-3, reliability, auto-accept share.

Shared by the sanity command (`evaluation.item_sanity`) and the combiner
(`evaluation.item_categories_combine`). An item without candidates counts as wrong, with a top
score of 0. Aggregates only: nothing here keeps an item name.
"""

import itertools
import math
import statistics
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

# Reliability bins of the top score: [low, high), the last one closed.
RELIABILITY_EDGES = (0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 1.0)
TARGET_PRECISION = 0.95


@dataclass(frozen=True)
class Scored:
    """One item: its candidates' slugs best first, the top score, and the true category."""

    ranked: tuple[str, ...]
    top_score: float
    truth: str

    @property
    def correct(self) -> bool:
        return bool(self.ranked) and self.ranked[0] == self.truth

    @property
    def in_top3(self) -> bool:
        return self.truth in self.ranked[:3]


def accepted_at_precision(
    items: Sequence[Scored], target: float = TARGET_PRECISION
) -> dict[str, Any]:
    """The largest share of items, most confident first, whose precision is at least `target`.

    Items of equal top score are kept or dropped together, so the result does not depend on their
    order. `threshold` is the lowest top score kept (None when no share reaches the target).
    """
    ordered = sorted(items, key=lambda item: -item.top_score)
    best: dict[str, Any] = {"share": 0.0, "items": 0, "threshold": None}
    correct = 0
    position = 0
    while position < len(ordered):
        score = ordered[position].top_score
        while position < len(ordered) and ordered[position].top_score == score:
            correct += ordered[position].correct
            position += 1
        if score > 0 and correct / position >= target:
            best = {
                "share": round(position / len(ordered), 4),
                "items": position,
                "threshold": round(score, 4),
            }
    return best


def reliability(items: Sequence[Scored]) -> list[dict[str, Any]]:
    """Per top-score bin: the item count, the mean top score and the accuracy."""
    table = []
    edges = RELIABILITY_EDGES
    for low, high in itertools.pairwise(edges):
        last = high == edges[-1]
        members = [
            item
            for item in items
            if low <= item.top_score < high or (last and item.top_score == high)
        ]
        table.append(
            {
                "low": low,
                "high": high,
                "items": len(members),
                "mean_score": round(statistics.fmean(m.top_score for m in members), 4)
                if members
                else None,
                "accuracy": round(sum(m.correct for m in members) / len(members), 4)
                if members
                else None,
            }
        )
    return table


def expected_calibration_error(items: Sequence[Scored]) -> float | None:
    """The item-weighted mean gap between the top score and the accuracy over the bins."""
    if not items:
        return None
    total = 0.0
    for row in reliability(items):
        if row["items"]:
            total += row["items"] * abs(row["mean_score"] - row["accuracy"])
    return round(total / len(items), 4)


def summary(items: Sequence[Scored]) -> dict[str, Any]:
    """Accuracy, top-3, the top-score distribution, reliability and the auto-accept share."""
    if not items:
        return {"items": 0}
    scores = sorted(item.top_score for item in items)

    def quantile(share: float) -> float:
        return round(scores[max(0, math.ceil(share * len(scores)) - 1)], 4)

    return {
        "items": len(items),
        "top1": sum(item.correct for item in items),
        "top3": sum(item.in_top3 for item in items),
        "accuracy": round(sum(item.correct for item in items) / len(items), 4),
        "top3_accuracy": round(sum(item.in_top3 for item in items) / len(items), 4),
        "without_candidates": sum(not item.ranked for item in items),
        "top_score": {
            "mean": round(statistics.fmean(scores), 4),
            "p10": quantile(0.1),
            "p25": quantile(0.25),
            "median": quantile(0.5),
            "p75": quantile(0.75),
            "p90": quantile(0.9),
        },
        "reliability": reliability(items),
        "expected_calibration_error": expected_calibration_error(items),
        "accepted_at_95_precision": accepted_at_precision(items),
    }
