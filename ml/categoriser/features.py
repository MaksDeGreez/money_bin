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
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from decimal import Decimal
from typing import Any

from sklearn.feature_extraction import DictVectorizer
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer

from categoriser.dataset import Row

FEATURE_VERSION = 1
TEXT_SEPARATOR = " | "


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


def features(rows: Iterable[Row]) -> list[dict[str, Any]]:
    return [row_features(row) for row in rows]


def select_text(items: Sequence[dict[str, Any]]) -> list[str]:
    return [item["text"] for item in items]


def select_fields(items: Sequence[dict[str, Any]]) -> list[dict[str, str]]:
    return [item["fields"] for item in items]


def build_model(c: float, seed: int, min_df: int = 2, max_iter: int = 2000) -> Pipeline:
    """An unfitted pipeline: TF-IDF words and characters + one-hot fields → logistic regression."""
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
    return Pipeline(
        [
            ("features", FeatureUnion([("word", word), ("char", char), ("fields", fields)])),
            (
                "classifier",
                LogisticRegression(
                    C=c, class_weight="balanced", max_iter=max_iter, random_state=seed
                ),
            ),
        ]
    )
