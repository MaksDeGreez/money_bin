"""Comparisons between two runs of the same task, on the receipts (or items) both runs scored.

A comparison is declared (`--compare A B`, or a line `A B` in a comparisons file) or found
automatically: two runs of the same task, with the same prompt version, image size and token
limit, that differ in exactly one of the model (`model`: name and version), the photos (`crops`),
or the backend (`backend`: local against hosted, whatever the model, as long as the crops agree).

Every difference is A - B. In an automatic comparison A is the cropped run (`crops`), the run whose
backend name sorts first (`backend`, so `mlx` before `openrouter`) or whose model name sorts first
(`model`).

OCR: for every headline metric, the paired difference on the receipts where both runs have it,
with a paired bootstrap interval (the same resampled receipts for both); McNemar's test on
per-receipt correctness for the QR fields, the merchant, the kind and the items-sum check.
Item categories: the headline metrics of both runs and the intervals of their differences on the
items both scored with the same label (resampling receipts); McNemar's test on per-item top-1
correctness.
"""

from typing import Any

import numpy as np

from categoriser.metrics import HEADLINE, day_block_samples, difference, headline, mcnemar
from evaluation.bootstrap import Ratio, draws_for, paired_difference, rng_for
from evaluation.category_scoring import CategoryRunScores, encode, seed_for
from evaluation.inputs import Run
from evaluation.ocr_fields import FIELDS
from evaluation.ocr_scoring import OcrRunScores, ratio_of

DIMENSIONS = ("model", "crops", "backend", "declared")
OCR_DIFFERENCES = (
    *(f"fields.{name}" for name in FIELDS),
    "merchant",
    "kind",
    "items.main.precision",
    "items.main.recall",
    "items.main.f1_micro",
    "items.main.f1_macro",
    "items.strict.f1_micro",
    "items.lenient.f1_micro",
    "items.cer_normalised",
    "items_sum_to_total",
    "parse_failed",
)
OCR_MCNEMAR = (*(f"fields.{name}" for name in FIELDS), "merchant", "kind", "items_sum_to_total")


def _context(run: Run) -> tuple[Any, ...]:
    settings = run.meta.get("settings") or {}
    return (
        run.task,
        run.meta.get("prompt_version"),
        settings.get("image_max_side"),
        settings.get("max_tokens"),
    )


def automatic_pairs(runs: list[Run]) -> list[tuple[Run, Run, str]]:
    pairs = []
    for i, first in enumerate(runs):
        for second in runs[i + 1 :]:
            if _context(first) != _context(second):
                continue
            model_differs = (first.model_name, first.model_version) != (
                second.model_name,
                second.model_version,
            )
            backend_differs = first.backend != second.backend
            crops_differ = first.crops != second.crops
            if crops_differ and not model_differs and not backend_differs:
                a, b = (first, second) if first.crops else (second, first)
                pairs.append((a, b, "crops"))
            elif backend_differs and not crops_differ:
                a, b = sorted((first, second), key=lambda run: (run.backend, run.run_id))
                pairs.append((a, b, "backend"))
            elif model_differs and not backend_differs and not crops_differ:
                a, b = sorted((first, second), key=lambda run: (run.model_name, run.run_id))
                pairs.append((a, b, "model"))
    return pairs


def _seconds_mean(scores: OcrRunScores, ids: set[str]) -> float | None:
    values = [
        o.seconds
        for o in scores.outcomes
        if o.receipt_id in ids and o.status in ("ok", "parse_failed") and o.seconds is not None
    ]
    return float(np.mean(values)) if values else None


def compare_ocr(
    a: OcrRunScores, b: OcrRunScores, *, seed: int, resamples: int
) -> dict[str, Any] | None:
    by_id_a = {o.receipt_id: o for o in a.outcomes}
    by_id_b = {o.receipt_id: o for o in b.outcomes}
    common = sorted(set(by_id_a) & set(by_id_b))
    if not common:
        return None
    outcomes_a = [by_id_a[i] for i in common]
    outcomes_b = [by_id_b[i] for i in common]
    draws = draws_for(len(common), resamples, rng_for(seed, "compare", a.run.run_id, b.run.run_id))
    differences = {
        key: paired_difference(ratio_of(outcomes_a, key), ratio_of(outcomes_b, key), draws)
        for key in OCR_DIFFERENCES
    }
    tests = {}
    for key in OCR_MCNEMAR:
        ratio_a: Ratio = ratio_of(outcomes_a, key)
        ratio_b: Ratio = ratio_of(outcomes_b, key)
        mask = (ratio_a.den > 0) & (ratio_b.den > 0)
        tests[key] = {
            "receipts": int(mask.sum()),
            **mcnemar(ratio_a.num[mask] > 0.5, ratio_b.num[mask] > 0.5),
        }
    ids = set(common)
    return {
        "receipts": len(common),
        "differences": differences,
        "mcnemar": tests,
        "seconds_mean": {"a": _seconds_mean(a, ids), "b": _seconds_mean(b, ids)},
    }


def compare_categories(
    a: CategoryRunScores, b: CategoryRunScores, *, seed: int, resamples: int
) -> dict[str, Any] | None:
    rows_b = {(row.receipt_id, row.position): row for row in b.rows}
    common_a = [
        row
        for row in a.rows
        if (row.receipt_id, row.position) in rows_b
        and rows_b[(row.receipt_id, row.position)].label == row.label
    ]
    if not common_a:
        return None
    common_b = [rows_b[(row.receipt_id, row.position)] for row in common_a]
    encoded = encode(common_a, {"a": common_a, "b": common_b})
    n_labels = len(encoded.labels)
    points = {
        name: headline(encoded.true, encoded.top1[name], encoded.in_top3[name], n_labels)
        for name in ("a", "b")
    }
    samples = day_block_samples(
        encoded,
        [row.receipt_id for row in common_a],
        resamples=resamples,
        seed=seed_for(seed, "compare", a.run.run_id, b.run.run_id),
    )
    intervals = difference(samples, "a", "b")
    correct_a = encoded.true == encoded.top1["a"]
    correct_b = encoded.true == encoded.top1["b"]
    return {
        "items": len(common_a),
        "receipts": len({row.receipt_id for row in common_a}),
        "differences": {
            metric: {
                "a": points["a"][metric],
                "b": points["b"][metric],
                "difference": points["a"][metric] - points["b"][metric],
                "ci95": intervals[metric],
            }
            for metric in HEADLINE
        },
        "mcnemar": {"top1": {"items": len(common_a), **mcnemar(correct_a, correct_b)}},
    }
