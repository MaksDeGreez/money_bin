"""Rule baselines the model has to beat, and the common shape of a system's predictions.

- `MajorityBaseline`: always the most frequent training category.
- `PayeeMccBaseline`: the most frequent training category of the row's payee; for a payee not seen
  in training (or no payee), that of its MCC; otherwise the majority category. This is what a simple
  hand-written rule set does.

Both are fitted on training rows only. Every system ranks categories, so top-3 accuracy and the
confidence-based coverage curves apply to the baselines too.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np
from sklearn.pipeline import Pipeline

from categoriser.dataset import Row
from categoriser.features import features

TOP_K = 3


@dataclass(frozen=True)
class Predictions:
    """Per row: the categories ranked best first (up to `TOP_K`) and the first one's confidence."""

    ranked: list[list[str]]
    confidence: np.ndarray

    @property
    def top1(self) -> list[str]:
        return [labels[0] for labels in self.ranked]


@dataclass(frozen=True)
class _Ranking:
    labels: list[str]  # best first
    share: float  # the share of the first label among the counted rows

    @classmethod
    def of(cls, counter: Counter[str]) -> _Ranking:
        # Ties are broken by the label, so the result does not depend on the order of the rows.
        ordered = sorted(counter.items(), key=lambda item: (-item[1], item[0]))
        total = sum(counter.values())
        return cls(labels=[label for label, _ in ordered], share=ordered[0][1] / total)


def _fill(primary: list[str], *fallbacks: list[str]) -> list[str]:
    ranked: list[str] = []
    for labels in (primary, *fallbacks):
        for label in labels:
            if label not in ranked:
                ranked.append(label)
            if len(ranked) == TOP_K:
                return ranked
    return ranked


class MajorityBaseline:
    name = "majority"

    def fit(self, rows: Sequence[Row]) -> MajorityBaseline:
        self.ranking = _Ranking.of(Counter(row.label for row in rows))
        return self

    def predict(self, rows: Sequence[Row]) -> Predictions:
        ranked = self.ranking.labels[:TOP_K]
        return Predictions(
            ranked=[list(ranked) for _ in rows],
            confidence=np.full(len(rows), self.ranking.share),
        )


class PayeeMccBaseline:
    name = "payee_mcc"

    def fit(self, rows: Sequence[Row]) -> PayeeMccBaseline:
        by_payee: dict[str, Counter[str]] = {}
        by_mcc: dict[str, Counter[str]] = {}
        for row in rows:
            if row.payee:
                by_payee.setdefault(row.payee, Counter())[row.label] += 1
            if row.mcc:
                by_mcc.setdefault(row.mcc, Counter())[row.label] += 1
        self.payees = {key: _Ranking.of(counter) for key, counter in by_payee.items()}
        self.mccs = {key: _Ranking.of(counter) for key, counter in by_mcc.items()}
        self.majority = _Ranking.of(Counter(row.label for row in rows))
        return self

    def predict(self, rows: Sequence[Row]) -> Predictions:
        ranked: list[list[str]] = []
        confidence: list[float] = []
        for row in rows:
            payee = self.payees.get(row.payee) if row.payee else None
            mcc = self.mccs.get(row.mcc) if row.mcc else None
            chain = [r for r in (payee, mcc, self.majority) if r is not None]
            ranked.append(_fill(*(r.labels for r in chain)))
            confidence.append(chain[0].share)
        return Predictions(ranked=ranked, confidence=np.asarray(confidence, dtype=float))


def model_predictions(model: Pipeline, rows: Sequence[Row]) -> Predictions:
    """Rank the categories of a fitted model by probability."""
    probabilities = model.predict_proba(features(rows))
    classes = model.classes_
    order = np.argsort(-probabilities, axis=1, kind="stable")[:, :TOP_K]
    ranked = [[str(classes[i]) for i in row_order] for row_order in order]
    return Predictions(ranked=ranked, confidence=probabilities.max(axis=1))
