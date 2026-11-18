"""Split rows by date, keeping every calendar day entirely on one side.

The rows are ordered by date. The tail starts on the day of the first row of the last `fraction` of
the rows, and that whole day belongs to the tail, so the tail holds at least `fraction` of the rows
(more by at most the rest of that day). The one exception: when that day is the first day, the tail
starts on the second day instead and may hold less. Every row of the head is dated strictly before
every row of the tail; the share actually reached is recorded in the metrics.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date

from categoriser.dataset import Row


class SplitError(ValueError):
    """The rows cannot be split as asked (too few rows or days)."""


@dataclass(frozen=True)
class Split:
    head: list[Row]
    tail: list[Row]
    cut: date  # the first day of the tail


def split_by_date(rows: Sequence[Row], fraction: float) -> Split:
    """Cut `rows` into an earlier head and a later tail of at least `fraction` of them."""
    if not 0 < fraction < 1:
        raise SplitError("the fraction must be between 0 and 1")
    ordered = sorted(rows, key=lambda row: (row.occurred_on, row.legacy_id))
    if len({row.occurred_on for row in ordered}) < 2:
        raise SplitError("the rows must cover at least two days")
    first_tail = len(ordered) - max(1, math.ceil(len(ordered) * fraction))
    cut = ordered[max(first_tail, 0)].occurred_on
    if cut == ordered[0].occurred_on:
        # The tail would swallow everything: move the cut to the second day.
        cut = min(row.occurred_on for row in ordered if row.occurred_on > cut)
    head = [row for row in ordered if row.occurred_on < cut]
    tail = [row for row in ordered if row.occurred_on >= cut]
    return Split(head=head, tail=tail, cut=cut)


class SealedTestError(RuntimeError):
    """The test rows were asked for outside the final scoring step."""


class SealedTest:
    """The test rows behind a seal.

    Choosing anything (a variant, a hyper-parameter, a threshold) happens on the validation slice;
    the test set is scored once, for the single final configuration, by `categoriser.score`. Until
    that step unseals it, the only things anyone can learn about the test set are its size and its
    first day, which the split itself defines. `rows` refuses, so a selection run that reached for
    the test rows (or their labels) stops instead of quietly using them.
    """

    def __init__(self, rows: Sequence[Row], cut: date) -> None:
        self.__rows = tuple(rows)
        self.cut = cut
        self.size = len(self.__rows)
        self.unsealed_for: str | None = None

    @property
    def rows(self) -> list[Row]:
        if self.unsealed_for is None:
            raise SealedTestError(
                "the test set is sealed: choices are made on the validation slice, and only the "
                "final scoring step (categoriser.score) may read the test rows"
            )
        return list(self.__rows)

    def unseal(self, purpose: str) -> list[Row]:
        """Open the seal for the final scoring step; `purpose` is recorded in its metrics."""
        if not purpose.strip():
            raise SealedTestError("say what the test set is unsealed for")
        self.unsealed_for = purpose
        return self.rows


@dataclass(frozen=True)
class TimeSplit:
    """Training rows (a fitting part and a validation slice at its end) and a sealed test set."""

    fit: list[Row]
    validation: list[Row]
    test: SealedTest
    validation_cut: date

    @property
    def train(self) -> list[Row]:
        """The whole training period: the fitting rows and the validation slice."""
        return [*self.fit, *self.validation]


def time_split(rows: Sequence[Row], test_fraction: float, validation_fraction: float) -> TimeSplit:
    """The last `test_fraction` of the rows (whole days) sealed as the test set, and the last
    `validation_fraction` of the rest (whole days again) as the validation slice."""
    outer = split_by_date(rows, test_fraction)
    inner = split_by_date(outer.head, validation_fraction)
    return TimeSplit(
        fit=inner.head,
        validation=inner.tail,
        test=SealedTest(outer.tail, outer.cut),
        validation_cut=inner.cut,
    )
