"""A categoriser configuration, and fitting it on rows into a system that ranks categories.

A `Config` names everything that defines a candidate: the feature set (TF-IDF, a sentence embedding,
or both), the encoder, the regularisation strength `C`, an optional recency half-life for the sample
weights, the strength of the class weights, and an optional hybrid with the payee and MCC history.
`Config()` with its defaults and a chosen `C` is the first version exactly: the same pipeline, the
balanced class weights, no sample weights, no hybrid.

`fit_system` fits every part (vectorisers, model, rule tables) on the rows it is given and nothing
else. Recency weights are measured back from the last day of those rows, so a half-life tuned with
the fitting rows means the same after a refit on the whole training period.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass, replace
from typing import Any

import numpy as np
from sklearn.pipeline import Pipeline

from categoriser.baselines import TOP_K, Predictions
from categoriser.common import TrainingError, labels
from categoriser.dataset import Row
from categoriser.embeddings import Encoder
from categoriser.features import FEATURE_SETS, build_model, features, row_text
from categoriser.hybrid import HybridParams, RuleTables, combine


@dataclass(frozen=True)
class Config:
    feature_set: str = "tfidf"
    encoder: str | None = None
    c: float = 1.0
    half_life_days: float | None = None
    class_weight_power: float = 1.0
    hybrid: HybridParams | None = None
    min_df: int = 2

    def __post_init__(self) -> None:
        if self.feature_set not in FEATURE_SETS:
            raise TrainingError(f"unknown feature set {self.feature_set!r}")
        if (self.encoder is None) != (self.feature_set == "tfidf"):
            raise TrainingError("an encoder is needed exactly when the features use embeddings")
        if self.c <= 0:
            raise TrainingError("every C must be above 0")
        if self.half_life_days is not None and self.half_life_days <= 0:
            raise TrainingError("a half-life must be above 0 days")
        if self.class_weight_power < 0:
            raise TrainingError("the class weight power must be at least 0")

    def but(self, **changes: Any) -> Config:
        return replace(self, **changes)

    @property
    def name(self) -> str:
        """A short readable name: the features, then each modifier."""
        parts = [
            {"tfidf": "tfidf", "embedding": "emb", "tfidf+embedding": "tfidf+emb"}[self.feature_set]
        ]
        if self.encoder:
            parts[0] += f":{self.encoder}"
        if self.half_life_days is not None:
            parts.append("recency")
        if self.class_weight_power != 1.0:
            parts.append("classweight")
        if self.hybrid is not None:
            parts.append(self.hybrid.mode)
        return "+".join(parts)

    @property
    def complexity(self) -> tuple[int, int]:
        """(needs a neural encoder, number of parts beyond the first version); lower is simpler."""
        extras = sum(
            [
                self.feature_set == "tfidf+embedding",
                self.half_life_days is not None,
                self.class_weight_power != 1.0,
                self.hybrid is not None,
            ]
        )
        return (int(self.encoder is not None), extras)

    def as_dict(self) -> dict[str, Any]:
        values = asdict(self)
        values["hybrid"] = None if self.hybrid is None else self.hybrid.as_dict()
        return values

    @classmethod
    def from_dict(cls, values: Mapping[str, Any]) -> Config:
        values = dict(values)
        hybrid = values.pop("hybrid", None)
        return cls(**values, hybrid=None if hybrid is None else HybridParams.from_dict(hybrid))


def recency_weights(rows: Sequence[Row], half_life_days: float) -> np.ndarray:
    """0.5 ** (age in days / half-life), age counted back from the last day; mean 1."""
    last = max(row.occurred_on for row in rows)
    ages = np.array([(last - row.occurred_on).days for row in rows], dtype=float)
    weights = 0.5 ** (ages / half_life_days)
    return weights / weights.mean()


def class_weights(y: Sequence[str], power: float) -> dict[str, float]:
    """(n / (K * n_c)) ** power: 1 is scikit-learn's "balanced", 0 gives every class weight 1."""
    counts = Counter(y)
    n, k = len(y), len(counts)
    return {label: (n / (k * count)) ** power for label, count in counts.items()}


class System:
    """A fitted configuration: ranks the categories of new rows."""

    def __init__(
        self,
        config: Config,
        pipeline: Pipeline,
        tables: RuleTables,
        encoder: Encoder | None,
    ) -> None:
        self.config = config
        self.pipeline = pipeline
        self.tables = tables
        self.encoder = encoder

    @property
    def classes(self) -> list[str]:
        return [str(label) for label in self.pipeline.classes_]

    def model_probabilities(self, rows: Sequence[Row]) -> np.ndarray:
        return self.pipeline.predict_proba(_inputs(rows, self.encoder))

    def probabilities(self, rows: Sequence[Row], model: np.ndarray | None = None) -> np.ndarray:
        """The model's class probabilities, combined with the rule tables when there is a hybrid.
        `model` reuses probabilities already computed for the same rows."""
        p = self.model_probabilities(rows) if model is None else model
        if self.config.hybrid is None:
            return p
        return combine(p, self.classes, rows, self.tables, self.config.hybrid)

    def predict(self, rows: Sequence[Row], model: np.ndarray | None = None) -> Predictions:
        return ranked(self.probabilities(rows, model), self.classes)

    def with_hybrid(self, hybrid: HybridParams | None) -> System:
        """The same fitted model and tables with other hybrid parameters (no refit)."""
        return System(self.config.but(hybrid=hybrid), self.pipeline, self.tables, self.encoder)


def ranked(probabilities: np.ndarray, classes: Sequence[str]) -> Predictions:
    order = np.argsort(-probabilities, axis=1, kind="stable")[:, :TOP_K]
    return Predictions(
        ranked=[[str(classes[i]) for i in row_order] for row_order in order],
        confidence=probabilities.max(axis=1),
    )


def fit_system(
    config: Config, rows: Sequence[Row], *, seed: int, encoders: Mapping[str, Encoder]
) -> System:
    """Fit `config` on `rows` only: vectorisers, model and the hybrid's rule tables."""
    y = labels(rows)
    if len(set(y)) < 2:
        raise TrainingError("the rows to fit hold fewer than two categories")
    encoder = None
    if config.encoder is not None:
        if config.encoder not in encoders:
            raise TrainingError(f"the encoder {config.encoder!r} is not available")
        encoder = encoders[config.encoder]
    weight: str | dict[str, float] = (
        "balanced"
        if config.class_weight_power == 1.0
        else class_weights(y, config.class_weight_power)
    )
    pipeline = build_model(
        c=config.c,
        seed=seed,
        min_df=config.min_df,
        feature_set=config.feature_set,
        class_weight=weight,
    )
    options = {}
    if config.half_life_days is not None:
        options["classifier__sample_weight"] = recency_weights(rows, config.half_life_days)
    try:
        pipeline.fit(_inputs(rows, encoder), y, **options)
    except ValueError as error:
        # scikit-learn's message may quote data; say only what kind of problem it is.
        raise TrainingError(
            f"the model could not be fitted ({type(error).__name__}; for example, no text is "
            "left after --min-df)"
        ) from None
    return System(config, pipeline, RuleTables().fit(rows), encoder)


def _inputs(rows: Sequence[Row], encoder: Encoder | None) -> list[dict[str, Any]]:
    if encoder is None:
        return features(rows)
    return features(rows, encoder.encode([row_text(row) for row in rows]))
