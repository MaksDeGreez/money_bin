"""One-to-one matching of predicted receipt items to ground-truth items.

For every pair of a predicted item `p` and a reference item `r`:

- `name` = `text.similarity(normalise_name(p.name), normalise_name(r.name))`;
- `amount` = how well the amounts agree: 1 when they are equal as decimals, otherwise
  `max(0, 1 - |p - r| / max(|p|, |r|))` (0 when either amount is missing);
- `score` = `NAME_WEIGHT * name + AMOUNT_WEIGHT * amount` (0.5 and 0.5).

Which pairs qualify depends on the variant:

- `lenient`: `name >= NAME_THRESHOLD` (0.6); the amount is ignored;
- `main`: `score >= MATCH_THRESHOLD` (0.8). As the amount term is at most 0.5, this implies
  `name >= 0.6`; an exact amount lets a name down to 0.6 match, and an exactly right name matches
  with an amount up to 40% off the larger of the two;
- `strict`: `name >= 0.6` and the amounts exactly equal.

For each variant, one assignment is chosen with the Hungarian method (SciPy's
`linear_sum_assignment`): the largest number of qualifying pairs, each item used at most once, and
among assignments of that size the one with the highest total `score`. So a duplicated prediction
cannot match one reference item twice, an extra prediction can never take a match away, and the
amounts tell apart two items with similar names. Every pair that qualifies for `strict` qualifies
for `main`, and every `main` pair for `lenient`, so the counts nest: `strict` <= `main` <=
`lenient` on every receipt, and a reader sees how much of the score comes from names and how much
from amounts.
"""

from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from typing import Any

import numpy as np
from scipy.optimize import linear_sum_assignment

from evaluation.text import normalise_name, similarity

NAME_WEIGHT = 0.5
AMOUNT_WEIGHT = 0.5
NAME_THRESHOLD = 0.6
MATCH_THRESHOLD = 0.8
VARIANTS = ("main", "strict", "lenient")
# Floating-point slack for the thresholds: 0.5 * 0.6 + 0.5 must count as 0.8.
EPSILON = 1e-9


@dataclass(frozen=True)
class Pair:
    """A candidate pair: positions (0-based) in the predicted and reference lists."""

    predicted: int
    reference: int
    name: float
    amount: float
    score: float
    exact_amount: bool


QUALIFIES: dict[str, Callable[[Pair], bool]] = {
    "lenient": lambda pair: pair.name >= NAME_THRESHOLD - EPSILON,
    "main": lambda pair: pair.score >= MATCH_THRESHOLD - EPSILON,
    "strict": lambda pair: pair.name >= NAME_THRESHOLD - EPSILON and pair.exact_amount,
}


@dataclass(frozen=True)
class Matching:
    predicted: int
    reference: int
    by_variant: dict[str, tuple[Pair, ...]] = field(default_factory=dict)

    def matched(self, variant: str) -> tuple[Pair, ...]:
        if variant not in QUALIFIES:
            raise ValueError(f"unknown variant {variant}")
        return self.by_variant.get(variant, ())


def decimal_or_none(value: Any) -> Decimal | None:
    if not isinstance(value, str):
        return None
    try:
        number = Decimal(value)
    except InvalidOperation:
        return None
    return number if number.is_finite() else None


def amount_agreement(predicted: Decimal | None, reference: Decimal | None) -> float:
    if predicted is None or reference is None:
        return 0.0
    if predicted == reference:
        return 1.0
    largest = max(abs(predicted), abs(reference))
    return max(0.0, 1.0 - float(abs(predicted - reference) / largest))


def _assign(candidates: list[Pair], shape: tuple[int, int]) -> tuple[Pair, ...]:
    """The largest set of disjoint pairs from `candidates`, then the highest total score.

    Each pair weighs `1 + score / (k + 1)`, where k is the most pairs an assignment can have: one
    more pair always adds more (at least 1) than any total of the score parts (below 1)."""
    if not candidates:
        return ()
    k = min(shape)
    weights = np.zeros(shape)
    by_cell = {}
    for pair in candidates:
        weights[pair.predicted, pair.reference] = 1.0 + pair.score / (k + 1)
        by_cell[(pair.predicted, pair.reference)] = pair
    rows, columns = linear_sum_assignment(weights, maximize=True)
    chosen = [
        by_cell[(int(i), int(j))]
        for i, j in zip(rows, columns, strict=True)
        if (int(i), int(j)) in by_cell
    ]
    return tuple(sorted(chosen, key=lambda pair: (pair.predicted, pair.reference)))


def match_items(
    predicted: Sequence[dict[str, Any]], reference: Sequence[dict[str, Any]]
) -> Matching:
    """Match items (dicts with `name` and `amount`) one to one; see the module docstring."""
    if not predicted or not reference:
        return Matching(len(predicted), len(reference))
    predicted_names = [normalise_name(item.get("name")) for item in predicted]
    reference_names = [normalise_name(item.get("name")) for item in reference]
    predicted_amounts = [decimal_or_none(item.get("amount")) for item in predicted]
    reference_amounts = [decimal_or_none(item.get("amount")) for item in reference]
    candidates: list[Pair] = []
    for i, name_p in enumerate(predicted_names):
        for j, name_r in enumerate(reference_names):
            name = similarity(name_p, name_r)
            if name < NAME_THRESHOLD - EPSILON:
                continue
            amount = amount_agreement(predicted_amounts[i], reference_amounts[j])
            exact = (
                predicted_amounts[i] is not None and predicted_amounts[i] == reference_amounts[j]
            )
            score = NAME_WEIGHT * name + AMOUNT_WEIGHT * amount
            candidates.append(Pair(i, j, name, amount, score, exact))
    shape = (len(predicted), len(reference))
    return Matching(
        len(predicted),
        len(reference),
        {
            variant: _assign([pair for pair in candidates if qualifies(pair)], shape)
            for variant, qualifies in QUALIFIES.items()
        },
    )
