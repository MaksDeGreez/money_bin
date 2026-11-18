"""Features of a row and the model pipeline.

A row becomes two things:

- `text`: payee, merchant, bank description and comment joined in one string. It feeds two TF-IDF
  vectorisers: words (1- and 2-grams) and characters (2- to 5-grams inside word boundaries), which
  cope with the mixed Ukrainian / Russian / English spelling and the bank's truncated texts.
- `fields`: one-hot categorical values: the MCC, the amount's sign, the amount's size bucket (a
  power of ten, per currency, since 100 UAH and 100 USD are different sizes), the account kind, and
  the payee as a whole (so an exact payee match counts by itself, not only through its words).

The model is a multinomial logistic regression with balanced class weights over all of these. Every
part of the pipeline is fitted on the rows given to `fit`, never on the rows it is evaluated on.

Two more feature sets are built for the improved categoriser (`categoriser.systems`): a sentence
embedding of the same text (computed locally, `categoriser.embeddings`) with the one-hot fields, and
the embedding next to the TF-IDF features. The first version's pipeline (`feature_set="tfidf"`) is
unchanged.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from decimal import Decimal
from typing import Any

import numpy as np
from sklearn.feature_extraction import DictVectorizer
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer

from categoriser.dataset import Row

FEATURE_VERSION = 1
TEXT_SEPARATOR = " | "
FEATURE_SETS = ("tfidf", "embedding", "tfidf+embedding")


def amount_bucket(amount: Decimal) -> int:
    """The power of ten of the absolute amount: 0 for below 10, 1 for 10 to 99.99, and so on."""
    size = abs(amount)
    if size < 10:
        return 0
    return min(size.adjusted(), 6)  # the exponent of the leading digit: floor(log10), exactly


def row_features(row: Row) -> dict[str, Any]:
    """The model input of one row."""
    parts = [row.payee, row.merchant, row.bank_description, row.comment]
    return {
        "text": TEXT_SEPARATOR.join(part for part in parts if part),
        "fields": {
            "mcc": row.mcc or "none",
            "sign": "out" if row.amount < 0 else "in",
            "bucket": f"{row.currency}:{amount_bucket(row.amount)}",
            "account_kind": row.account_kind or "none",
            "payee": row.payee or "none",
        },
    }


def row_text(row: Row) -> str:
    """The joined text of a row (what the TF-IDF vectorisers and the sentence encoders read)."""
    return row_features(row)["text"]


def features(rows: Iterable[Row], embeddings: np.ndarray | None = None) -> list[dict[str, Any]]:
    """The model input of each row; `embeddings` (one vector per row) adds an `embedding` key."""
    items = [row_features(row) for row in rows]
    if embeddings is not None:
        if len(embeddings) != len(items):
            raise ValueError("one embedding per row is needed")
        for item, vector in zip(items, embeddings, strict=True):
            item["embedding"] = vector
    return items


def select_text(items: Sequence[dict[str, Any]]) -> list[str]:
    return [item["text"] for item in items]


def select_fields(items: Sequence[dict[str, Any]]) -> list[dict[str, str]]:
    return [item["fields"] for item in items]


def select_embedding(items: Sequence[dict[str, Any]]) -> np.ndarray:
    return np.vstack([item["embedding"] for item in items])


def build_model(
    c: float,
    seed: int,
    min_df: int = 2,
    max_iter: int = 2000,
    *,
    feature_set: str = "tfidf",
    class_weight: str | Mapping[str, float] = "balanced",
) -> Pipeline:
    """An unfitted pipeline: features → logistic regression.

    `tfidf` (the first version): TF-IDF words and characters + one-hot fields. `embedding`: the
    row's sentence embedding + one-hot fields. `tfidf+embedding`: all three.
    """
    if feature_set not in FEATURE_SETS:
        raise ValueError(f"unknown feature set {feature_set!r}")
    word = Pipeline(
        [
            ("select", FunctionTransformer(select_text)),
            (
                "tfidf",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 2),
                    min_df=min_df,
                    sublinear_tf=True,
                    token_pattern=r"(?u)\b\w+\b",
                ),
            ),
        ]
    )
    char = Pipeline(
        [
            ("select", FunctionTransformer(select_text)),
            (
                "tfidf",
                TfidfVectorizer(
                    analyzer="char_wb", ngram_range=(2, 5), min_df=min_df, sublinear_tf=True
                ),
            ),
        ]
    )
    fields = Pipeline(
        [
            ("select", FunctionTransformer(select_fields)),
            ("onehot", DictVectorizer()),
        ]
    )
    embedding = Pipeline([("select", FunctionTransformer(select_embedding))])
    parts: list[tuple[str, Pipeline]] = []
    if feature_set in ("tfidf", "tfidf+embedding"):
        parts += [("word", word), ("char", char)]
    if feature_set in ("embedding", "tfidf+embedding"):
        parts.append(("embedding", embedding))
    parts.append(("fields", fields))
    return Pipeline(
        [
            ("features", FeatureUnion(parts)),
            (
                "classifier",
                LogisticRegression(
                    C=c, class_weight=class_weight, max_iter=max_iter, random_state=seed
                ),
            ),
        ]
    )
