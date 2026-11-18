"""Calibration: from a model's raw score to the precision it had on labelled items.

A model's probability is not a precision: a model can be sure and wrong (on the
sanity set, Qwen3-VL gave two wrong answers a probability above 0.99). A
calibration is a monotone mapping fitted on labelled items: isotonic
regression of "the best candidate was right" on its raw score
(`python -m evaluation.item_categories_calibrate`). It is stored as the
breakpoints of a piecewise-linear function in a JSON file outside the
repository, with the backend, model, prompt version and score kind it was
fitted for; the service applies it only to answers of exactly that kind and
reports `calibrated: true` only then.

Applying it: the best candidate's score is mapped; the others are mapped too
and, if the three would add up to more than 1, scaled down so they fit beside
it. "Calibrated" describes the best candidate's score.
"""

import bisect
import json
import math
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from app.categorise.base import Candidate, Categorisation

FORMAT = "item-categoriser-calibration"
FORMAT_VERSION = 1


class CalibrationError(ValueError):
    """The calibration file cannot be used. The service does not start."""


@dataclass(frozen=True)
class Calibration:
    backend: str
    model_name: str
    prompt_version: str | None
    score_kind: str
    xs: tuple[float, ...]
    ys: tuple[float, ...]
    labelled_items: int

    def applies_to(
        self, backend: str, model_name: str, prompt_version: str | None, score_kind: str
    ) -> bool:
        return (self.backend, self.model_name, self.prompt_version, self.score_kind) == (
            backend,
            model_name,
            prompt_version,
            score_kind,
        )

    def map(self, score: float) -> float:
        """The fitted value at `score`: linear between breakpoints, flat beyond the ends."""
        if score <= self.xs[0]:
            return self.ys[0]
        if score >= self.xs[-1]:
            return self.ys[-1]
        right = bisect.bisect_right(self.xs, score)
        x0, x1 = self.xs[right - 1], self.xs[right]
        y0, y1 = self.ys[right - 1], self.ys[right]
        if x1 == x0:
            return y1
        return y0 + (y1 - y0) * (score - x0) / (x1 - x0)

    def apply(self, candidates: Sequence[Candidate]) -> list[Candidate]:
        if not candidates:
            return []
        best = Candidate(candidates[0].slug, self.map(candidates[0].score))
        others = [Candidate(c.slug, self.map(c.score)) for c in candidates[1:]]
        room = max(0.0, 1.0 - best.score)
        total = sum(c.score for c in others)
        if total > room:
            factor = room / total if total else 0.0
            others = [Candidate(c.slug, c.score * factor) for c in others]
        # Keep the order of the model's ranking: the mapping is monotone, so it holds.
        return [best, *others]


def _numbers(value: Any, name: str) -> tuple[float, ...]:
    if not isinstance(value, list) or not value:
        raise CalibrationError(f"the calibration file has no list of numbers at {name}")
    numbers = []
    for item in value:
        if isinstance(item, bool) or not isinstance(item, int | float) or not math.isfinite(item):
            raise CalibrationError(f"the calibration file has a non-number at {name}")
        numbers.append(float(item))
    return tuple(numbers)


def load_calibration(path: Path) -> Calibration:
    """Read and check a calibration file. Any problem raises `CalibrationError`."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise CalibrationError(f"the calibration file cannot be read ({error.strerror})") from None
    except ValueError:
        raise CalibrationError("the calibration file is not JSON") from None
    if not isinstance(document, dict) or document.get("format") != FORMAT:
        raise CalibrationError("the file is not an item categoriser calibration")
    if document.get("format_version") != FORMAT_VERSION:
        raise CalibrationError("the calibration file has an unknown format version")
    xs = _numbers(document.get("xs"), "xs")
    ys = _numbers(document.get("ys"), "ys")
    if len(xs) != len(ys):
        raise CalibrationError("the calibration file's xs and ys differ in length")
    if list(xs) != sorted(xs) or list(ys) != sorted(ys):
        raise CalibrationError("the calibration file's mapping is not increasing")
    if not all(0.0 <= value <= 1.0 for value in (*xs, *ys)):
        raise CalibrationError("the calibration file has values outside 0..1")
    fields = {}
    for key in ("backend", "model_name", "score_kind"):
        value = document.get(key)
        if not isinstance(value, str) or not value:
            raise CalibrationError(f"the calibration file has no {key}")
        fields[key] = value
    prompt_version = document.get("prompt_version")
    if prompt_version is not None and not isinstance(prompt_version, str):
        raise CalibrationError("the calibration file has an odd prompt_version")
    labelled = document.get("labelled_items")
    if isinstance(labelled, bool) or not isinstance(labelled, int):
        raise CalibrationError("the calibration file has no labelled_items count")
    return Calibration(
        backend=fields["backend"],
        model_name=fields["model_name"],
        prompt_version=prompt_version,
        score_kind=fields["score_kind"],
        xs=xs,
        ys=ys,
        labelled_items=labelled,
    )


def calibrate(
    categorisation: Categorisation,
    calibration: Calibration | None,
    backend: str,
    model_name: str,
) -> tuple[list[list[Candidate]], bool]:
    """The candidates with calibrated scores when the calibration fits this answer.

    Returns the candidates and whether they were calibrated. An answer of
    another kind (a hosted answer without log-probabilities, say) keeps its
    raw scores and is reported as not calibrated.
    """
    if calibration is None or not calibration.applies_to(
        backend, model_name, categorisation.prompt_version, categorisation.score_kind
    ):
        return categorisation.candidates, False
    return [calibration.apply(candidates) for candidates in categorisation.candidates], True
