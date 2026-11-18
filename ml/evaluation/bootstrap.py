"""Bootstrap intervals over receipts for ratio-of-sums metrics.

Every OCR metric of the harness is a ratio of per-receipt sums: a field's accuracy is hits over
receipts that have the field, micro precision is matched items over predicted items, macro F1 is
the sum of per-receipt F1 over the receipts with item ground truth. So one estimator covers them:
resample receipts with replacement (`resamples` times, a fixed seed), recompute the ratio, take the
2.5th and 97.5th percentiles (`categoriser.metrics`' percentile interval).

The receipt is the unit of resampling because items of one receipt are not independent (one bad
photo spoils all of them). The intervals describe the sampling of receipts from this receipt set
only: not the choice of receipts that got ground truth, not a model's run-to-run variation (the
runs are greedy and deterministic) and not other shops or printers.

Seeds are derived from the base seed and the names of what is resampled (a run id, a segment, a
pair of run ids), so adding a run never changes another run's intervals.
"""

import zlib
from dataclasses import dataclass

import numpy as np

from categoriser.metrics import _interval as percentile_interval


def rng_for(seed: int, *labels: str) -> np.random.Generator:
    return np.random.default_rng([seed, *(zlib.crc32(label.encode()) for label in labels)])


def draws_for(n: int, resamples: int, rng: np.random.Generator) -> np.ndarray:
    return rng.integers(0, n, size=(resamples, n)) if n else np.zeros((resamples, 0), dtype=int)


@dataclass(frozen=True)
class Ratio:
    """Per-receipt numerators and denominators of one metric (a denominator of 0: not counted)."""

    num: np.ndarray
    den: np.ndarray

    @classmethod
    def of(cls, pairs: list[tuple[float, float]]) -> "Ratio":
        if not pairs:
            return cls(np.zeros(0), np.zeros(0))
        array = np.asarray(pairs, dtype=float)
        return cls(array[:, 0], array[:, 1])

    def value(self) -> float | None:
        den = float(self.den.sum())
        return float(self.num.sum()) / den if den else None

    def resampled(self, draws: np.ndarray) -> np.ndarray:
        num = self.num[draws].sum(axis=1)
        den = self.den[draws].sum(axis=1)
        with np.errstate(invalid="ignore", divide="ignore"):
            return np.where(den > 0, num / np.where(den > 0, den, 1), np.nan)

    def masked(self, mask: np.ndarray) -> "Ratio":
        return Ratio(self.num * mask, self.den * mask)


def interval(samples: np.ndarray) -> list[float] | None:
    finite = samples[np.isfinite(samples)]
    if finite.size == 0:
        return None
    return percentile_interval(finite)


def estimate(ratio: Ratio, draws: np.ndarray) -> dict[str, float | list[float] | None]:
    value = ratio.value()
    return {
        "value": value,
        "ci95": interval(ratio.resampled(draws)) if value is not None else None,
    }


def paired_difference(a: Ratio, b: Ratio, draws: np.ndarray) -> dict[str, object]:
    """`a - b` on the receipts where both have a denominator, with a paired bootstrap interval
    (the same resampled receipts for both)."""
    mask = (a.den > 0) & (b.den > 0)
    a_masked, b_masked = a.masked(mask), b.masked(mask)
    value_a, value_b = a_masked.value(), b_masked.value()
    if value_a is None or value_b is None:
        return {"receipts": 0, "a": None, "b": None, "difference": None, "ci95": None}
    samples = a_masked.resampled(draws) - b_masked.resampled(draws)
    return {
        "receipts": int(mask.sum()),
        "a": value_a,
        "b": value_b,
        "difference": value_a - value_b,
        "ci95": interval(samples),
    }
