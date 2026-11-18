"""Evaluation metrics: F1, accuracy, top-3, precision by coverage, bootstrap intervals, McNemar.

Macro-F1 is scikit-learn's default: the mean F1 over every category that is a true label or a top-1
prediction in the evaluated rows (a category that is only ever predicted counts with F1 0). Weighted
F1 weights each category by its true support. Both are computed from integer-coded labels with
`numpy.bincount`, which keeps a thousand bootstrap resamples fast; the tests check them against
scikit-learn.

Precision at a coverage level keeps whole groups of equal confidence: when the k-th most confident
row ties with others, all of them are kept and the coverage actually reached is reported, so the
result does not depend on the order of the rows.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from typing import Any

import numpy as np
from scipy.stats import binomtest, chi2

from categoriser.baselines import Predictions

COVERAGE_LEVELS = (0.1, 0.25, 0.5, 0.75, 0.9, 1.0)
CONFIDENCE_THRESHOLDS = (0.5, 0.7, 0.9)
HEADLINE = ("macro_f1", "weighted_f1", "accuracy", "top3_accuracy")


class Encoded:
    """The true labels and every system's predictions of one evaluation set, as integer codes."""

    def __init__(self, y_true: Sequence[str], systems: Mapping[str, Predictions]) -> None:
        labels = set(y_true)
        for predictions in systems.values():
            for ranked in predictions.ranked:
                labels.update(ranked)
        self.labels = sorted(labels)
        code = {label: i for i, label in enumerate(self.labels)}
        self.true = np.array([code[label] for label in y_true], dtype=np.int64)
        self.top1: dict[str, np.ndarray] = {}
        self.in_top3: dict[str, np.ndarray] = {}
        self.confidence: dict[str, np.ndarray] = {}
        for name, predictions in systems.items():
            self.top1[name] = np.array([code[r[0]] for r in predictions.ranked], dtype=np.int64)
            self.in_top3[name] = np.array(
                [t in r for t, r in zip(y_true, predictions.ranked, strict=True)], dtype=bool
            )
            self.confidence[name] = np.asarray(predictions.confidence, dtype=float)

    @property
    def systems(self) -> list[str]:
        return list(self.top1)


def per_class_f1(
    true: np.ndarray, pred: np.ndarray, n_labels: int
) -> tuple[np.ndarray, np.ndarray]:
    """F1 and true support per label code (0 for a label with no true or predicted row)."""
    tp = np.bincount(true[true == pred], minlength=n_labels).astype(float)
    support = np.bincount(true, minlength=n_labels).astype(float)
    predicted = np.bincount(pred, minlength=n_labels).astype(float)
    denominator = support + predicted
    f1 = np.divide(2 * tp, denominator, out=np.zeros(n_labels), where=denominator > 0)
    return f1, support


def headline(
    true: np.ndarray, pred: np.ndarray, in_top3: np.ndarray, n_labels: int
) -> dict[str, float]:
    f1, support = per_class_f1(true, pred, n_labels)
    present = (support > 0) | (np.bincount(pred, minlength=n_labels) > 0)
    return {
        "macro_f1": float(f1[present].mean()),
        "weighted_f1": float((f1 * support).sum() / support.sum()),
        "accuracy": float((true == pred).mean()),
        "top3_accuracy": float(in_top3.mean()),
    }


def coverage_curve(correct: np.ndarray, confidence: np.ndarray) -> dict[str, Any]:
    """Precision when only the most confident rows are kept, by coverage level and by threshold."""
    n = len(correct)
    sorted_confidence = np.sort(confidence)[::-1]
    at_coverage = []
    for level in COVERAGE_LEVELS:
        k = max(1, math.ceil(level * n))
        threshold = sorted_confidence[k - 1]
        kept = confidence >= threshold  # the whole tie group at the boundary
        count = int(kept.sum())
        at_coverage.append(
            {
                "target_coverage": level,
                "coverage": count / n,
                "rows": count,
                "precision": float(correct[kept].mean()),
                "min_confidence": float(threshold),
            }
        )
    at_threshold = []
    for threshold in CONFIDENCE_THRESHOLDS:
        kept = confidence >= threshold
        count = int(kept.sum())
        at_threshold.append(
            {
                "threshold": threshold,
                "rows": count,
                "coverage": count / n,
                "precision": float(correct[kept].mean()) if count else None,
            }
        )
    return {"at_coverage": at_coverage, "at_threshold": at_threshold}


def mcnemar(correct_a: np.ndarray, correct_b: np.ndarray) -> dict[str, Any]:
    """McNemar's test on paired correctness: exact binomial test and corrected chi-square."""
    a_only = int((correct_a & ~correct_b).sum())
    b_only = int((~correct_a & correct_b).sum())
    discordant = a_only + b_only
    if discordant == 0:
        return {
            "a_only_correct": 0,
            "b_only_correct": 0,
            "exact_p_value": 1.0,
            "chi2_corrected": 0.0,
            "chi2_p_value": 1.0,
        }
    statistic = max(abs(a_only - b_only) - 1, 0) ** 2 / discordant
    return {
        "a_only_correct": a_only,
        "b_only_correct": b_only,
        "exact_p_value": float(binomtest(min(a_only, b_only), discordant, 0.5).pvalue),
        "chi2_corrected": float(statistic),
        "chi2_p_value": float(chi2.sf(statistic, df=1)),
    }


def evaluate(
    encoded: Encoded,
    mask: np.ndarray | None = None,
    *,
    resamples: int,
    seed: int,
    detail: bool = True,
) -> dict[str, Any]:
    """Headline metrics of every system on the rows in `mask`, with paired bootstrap intervals.

    The same resampled row indices are used for every system, so the interval of a difference
    between two systems is meaningful. `detail` adds the coverage curves.
    """
    index = np.arange(len(encoded.true)) if mask is None else np.flatnonzero(mask)
    n_labels = len(encoded.labels)
    result: dict[str, Any] = {"rows": len(index), "systems": {}}
    if len(index) == 0:
        return result
    true = encoded.true[index]
    rng = np.random.default_rng(seed)
    draws = rng.integers(0, len(index), size=(resamples, len(index)))
    samples: dict[str, dict[str, np.ndarray]] = {}
    for name in encoded.systems:
        pred = encoded.top1[name][index]
        in_top3 = encoded.in_top3[name][index]
        point = headline(true, pred, in_top3, n_labels)
        boot = {metric: np.empty(resamples) for metric in HEADLINE}
        for i, draw in enumerate(draws):
            values = headline(true[draw], pred[draw], in_top3[draw], n_labels)
            for metric in HEADLINE:
                boot[metric][i] = values[metric]
        samples[name] = boot
        entry: dict[str, Any] = {
            metric: {"value": point[metric], "ci95": _interval(boot[metric])} for metric in HEADLINE
        }
        if detail:
            entry["coverage"] = coverage_curve(true == pred, encoded.confidence[name][index])
        result["systems"][name] = entry
    result["_bootstrap"] = samples
    return result


def day_block_samples(
    encoded: Encoded, days: Sequence[Any], *, resamples: int, seed: int
) -> dict[str, dict[str, np.ndarray]]:
    """Bootstrap samples of the headline metrics that resample whole days instead of rows.

    Rows of the same day (and the same payee over nearby days) are not independent, so the row
    bootstrap is likely too narrow; resampling days is a sensitivity check on it. The same days are
    drawn for every system, so `difference` works on these samples too.
    """
    groups: dict[Any, list[int]] = {}
    for i, day in enumerate(days):
        groups.setdefault(day, []).append(i)
    blocks = [np.array(rows, dtype=np.int64) for rows in groups.values()]
    rng = np.random.default_rng(seed)
    n_labels = len(encoded.labels)
    samples = {
        name: {metric: np.empty(resamples) for metric in HEADLINE} for name in encoded.systems
    }
    for i in range(resamples):
        chosen = rng.integers(0, len(blocks), size=len(blocks))
        index = np.concatenate([blocks[j] for j in chosen])
        for name in encoded.systems:
            values = headline(
                encoded.true[index],
                encoded.top1[name][index],
                encoded.in_top3[name][index],
                n_labels,
            )
            for metric in HEADLINE:
                samples[name][metric][i] = values[metric]
    return samples


def intervals(samples: dict[str, dict[str, np.ndarray]]) -> dict[str, dict[str, list[float]]]:
    """The 95% percentile interval of every system's samples, per headline metric."""
    return {
        name: {metric: _interval(values) for metric, values in boot.items()}
        for name, boot in samples.items()
    }


def difference(samples: dict[str, dict[str, np.ndarray]], a: str, b: str) -> dict[str, Any]:
    """The bootstrap interval of `a` minus `b` for each headline metric (paired resamples)."""
    return {metric: _interval(samples[a][metric] - samples[b][metric]) for metric in HEADLINE}


def per_class(encoded: Encoded, train_support: Mapping[str, int]) -> list[dict[str, Any]]:
    """Support (training and test) and F1 of every category that is true or a top-1 prediction.

    A system's F1 is null for a category that is neither a true label nor one of its own top-1
    predictions: it is undefined there, and macro-F1 leaves it out too.
    """
    n_labels = len(encoded.labels)
    f1s = {
        name: per_class_f1(encoded.true, encoded.top1[name], n_labels) for name in encoded.systems
    }
    support = np.bincount(encoded.true, minlength=n_labels)
    predicted = {
        name: np.bincount(encoded.top1[name], minlength=n_labels) > 0 for name in encoded.systems
    }
    listed = support > 0
    for name in encoded.systems:
        listed |= predicted[name]
    out = []
    for i, label in enumerate(encoded.labels):
        if not listed[i]:
            continue
        out.append(
            {
                "category": label,
                "train_support": int(train_support.get(label, 0)),
                "test_support": int(support[i]),
                "f1": {
                    name: float(f1s[name][0][i]) if support[i] or predicted[name][i] else None
                    for name in encoded.systems
                },
            }
        )
    return out


def _interval(values: np.ndarray) -> list[float]:
    low, high = np.percentile(values, [2.5, 97.5])
    return [float(low), float(high)]
