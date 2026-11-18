"""One-to-one matching of predicted receipt items to ground-truth items.

For every pair of a predicted item `p` and a reference item `r`:

- `name` = `text.similarity(normalise_name(p.name), normalise_name(r.name))`;
- `amount` = how well the amounts agree: 1 when they are equal as decimals, otherwise
  `max(0, 1 - |p - r| / max(|p|, |r|))` (0 when either amount is missing);
- `score` = `NAME_WEIGHT * name + AMOUNT_WEIGHT * amount` (0.6 and 0.4).

A pair may be matched only when `name >= NAME_THRESHOLD` (0.6). Among such pairs, one assignment
is chosen that maximises the sum of `score` (the Hungarian method, SciPy's
`linear_sum_assignment`), so every item is matched at most once: a duplicated prediction cannot
match one reference item twice, and the amounts tell apart two items with similar names. The
assigned pairs are then counted three ways:

- `lenient`: every assigned pair (the name matches; the amount is ignored);
- `main`: assigned pairs with `score >= MATCH_THRESHOLD` (0.76). As the amount term is at most
  0.4, this implies `name >= 0.6`; an exact amount lets a name down to 0.6 match, a name that is
  exactly right still matches with an amount up to 40% off;
- `strict`: assigned pairs whose amounts are exactly equal.

So `strict` ⊆ `main` ⊆ `lenient` for every receipt, and a reader sees how much of the score comes
from names and how much from amounts.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any

import numpy as np
from scipy.optimize import linear_sum_assignment

from evaluation.text import normalise_name, similarity

NAME_WEIGHT = 0.6
AMOUNT_WEIGHT = 0.4
NAME_THRESHOLD = 0.6
MATCH_THRESHOLD = 0.76
VARIANTS = ("main", "strict", "lenient")
# Floating-point slack for the thresholds: 0.6 * 0.6 + 0.4 must count as 0.76.
EPSILON = 1e-9


@dataclass(frozen=True)
class Pair:
    """An assigned pair: positions (0-based) in the predicted and reference lists."""

    predicted: int
    reference: int
    name: float
    amount: float
    score: float
    exact_amount: bool


@dataclass(frozen=True)
class Matching:
    predicted: int
    reference: int
    pairs: tuple[Pair, ...]

    def matched(self, variant: str) -> tuple[Pair, ...]:
        if variant == "lenient":
            return self.pairs
        if variant == "main":
            return tuple(pair for pair in self.pairs if pair.score >= MATCH_THRESHOLD - EPSILON)
        if variant == "strict":
            return tuple(pair for pair in self.pairs if pair.exact_amount)
        raise ValueError(f"unknown variant {variant}")


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


def match_items(
    predicted: Sequence[dict[str, Any]], reference: Sequence[dict[str, Any]]
) -> Matching:
    """Match items (dicts with `name` and `amount`) one to one; see the module docstring."""
    if not predicted or not reference:
        return Matching(len(predicted), len(reference), ())
    predicted_names = [normalise_name(item.get("name")) for item in predicted]
    reference_names = [normalise_name(item.get("name")) for item in reference]
    predicted_amounts = [decimal_or_none(item.get("amount")) for item in predicted]
    reference_amounts = [decimal_or_none(item.get("amount")) for item in reference]
    weights = np.zeros((len(predicted), len(reference)))
    details: dict[tuple[int, int], Pair] = {}
    for i, name_p in enumerate(predicted_names):
        for j, name_r in enumerate(reference_names):
            name = similarity(name_p, name_r)
            if name < NAME_THRESHOLD - EPSILON:
                continue
            amount = amount_agreement(predicted_amounts[i], reference_amounts[j])
            score = NAME_WEIGHT * name + AMOUNT_WEIGHT * amount
            exact = (
                predicted_amounts[i] is not None and predicted_amounts[i] == reference_amounts[j]
            )
            details[(i, j)] = Pair(i, j, name, amount, score, exact)
            weights[i, j] = score
    if not details:
        return Matching(len(predicted), len(reference), ())
    rows, columns = linear_sum_assignment(weights, maximize=True)
    pairs = tuple(
        details[(int(i), int(j))]
        for i, j in zip(rows, columns, strict=True)
        if (int(i), int(j)) in details
    )
    return Matching(len(predicted), len(reference), pairs)
