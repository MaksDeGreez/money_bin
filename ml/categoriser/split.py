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
