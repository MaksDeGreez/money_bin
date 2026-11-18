"""The hybrid: the model's class probabilities combined with the payee's (and the MCC's) history.

The first version showed two regimes: on rows whose payee was seen in training, the payee rule
(most frequent category of the payee) was more accurate than the model; on rows with a new or no
payee, the model was clearly better. The hybrid uses each where it is strong.

`RuleTables` counts, from the training rows only, how often each category occurs per payee and per
MCC. For a row, the rule distribution `q` is the payee's category shares when the payee is known,
else (in `mix` mode) the MCC's; the combined distribution is

    p = w * q + (1 - w) * p_model

and the categories are ranked by `p` (top-3 included). Two forms:

- `mix`: for a known payee seen `n` times whose most frequent category has share `purity`,
  `w = n / (n + k) * purity ** beta`: a payee seen often with one category almost decides; one seen
  once, or spread over several categories, only nudges the model. For a row whose payee is unknown
  but whose MCC is known, `w = alpha_mcc * n_mcc / (n_mcc + k) * purity_mcc ** beta`.
- `switch`: the rule decides (`w` just below 1, so the model only breaks ties and fills the top-3)
  when the payee was seen at least `min_count` times with a purity of at least `min_purity`;
  otherwise the model alone.

The parameters are tuned on the validation slice with the model and the tables fitted on the rows
before it; for the final model both are refitted on the whole training period and the parameters are
kept as numbers. Every parameter is defined in counts and shares, so it means the same with more
training rows.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Sequence
from dataclasses import asdict, dataclass

import numpy as np

from categoriser.dataset import Row

SWITCH_WEIGHT = 1 - 1e-6


@dataclass(frozen=True)
class HybridParams:
    mode: str  # "mix" or "switch"
    k: float = 1.0
    beta: float = 0.0
    alpha_mcc: float = 0.0
    min_count: int = 1
    min_purity: float = 0.0

    def as_dict(self) -> dict[str, object]:
        values = asdict(self)
        keep = ("mode", "k", "beta", "alpha_mcc") if self.mode == "mix" else ("mode",)
        keep += ("min_count", "min_purity") if self.mode == "switch" else ()
        return {key: values[key] for key in keep}

    @classmethod
    def from_dict(cls, values: dict[str, object]) -> HybridParams:
        return cls(**values)  # type: ignore[arg-type]


class RuleTables:
    """Category counts per payee and per MCC, from the rows given to `fit` only."""

    def fit(self, rows: Sequence[Row]) -> RuleTables:
        self.payees: dict[str, Counter[str]] = {}
        self.mccs: dict[str, Counter[str]] = {}
        for row in rows:
            if row.payee:
                self.payees.setdefault(row.payee, Counter())[row.label] += 1
            if row.mcc:
                self.mccs.setdefault(row.mcc, Counter())[row.label] += 1
        return self


def _shares(counter: Counter[str], index: dict[str, int], size: int) -> tuple[np.ndarray, int]:
    q = np.zeros(size)
    total = sum(counter.values())
    for label, count in counter.items():
        q[index[label]] = count / total
    return q, total


def combine(
    probabilities: np.ndarray,
    classes: Sequence[str],
    rows: Sequence[Row],
    tables: RuleTables,
    params: HybridParams,
) -> np.ndarray:
    """The combined distribution of every row (same columns as `probabilities`)."""
    if params.mode not in ("mix", "switch"):
        raise ValueError(f"unknown hybrid mode {params.mode!r}")
    index = {label: i for i, label in enumerate(classes)}
    size = len(classes)
    combined = np.array(probabilities, dtype=float, copy=True)
    payees: dict[str, tuple[np.ndarray, int]] = {}
    mccs: dict[str, tuple[np.ndarray, int]] = {}
    for i, row in enumerate(rows):
        weight = 0.0
        q = None
        if row.payee and row.payee in tables.payees:
            if row.payee not in payees:
                payees[row.payee] = _shares(tables.payees[row.payee], index, size)
            q, n = payees[row.payee]
            purity = q.max()
            if params.mode == "mix":
                weight = n / (n + params.k) * purity**params.beta
            elif n >= params.min_count and purity >= params.min_purity:
                weight = SWITCH_WEIGHT
        elif params.mode == "mix" and params.alpha_mcc > 0 and row.mcc in tables.mccs:
            if row.mcc not in mccs:
                mccs[row.mcc] = _shares(tables.mccs[row.mcc], index, size)
            q, n = mccs[row.mcc]
            weight = params.alpha_mcc * n / (n + params.k) * q.max() ** params.beta
        if weight > 0 and q is not None:
            combined[i] = weight * q + (1 - weight) * combined[i]
    return combined
