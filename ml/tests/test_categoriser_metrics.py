"""Baselines, features and metrics of the transaction categoriser."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import numpy as np
import pytest
from sklearn.metrics import f1_score

from categoriser.baselines import MajorityBaseline, PayeeMccBaseline, Predictions
from categoriser.features import amount_bucket, row_features
from categoriser.metrics import (
    Encoded,
    coverage_curve,
    day_block_intervals,
    difference,
    evaluate,
    headline,
    mcnemar,
    per_class,
    per_class_f1,
)
from tests.test_categoriser_data import make_row

GROCERIES = "Groceries / Groceries"
CAFE = "Eating out / Cafes, bars & restaurants"
FUEL = "Car / Fuel"
PHARMACY = "Health / Health & pharmacy"


def training_rows() -> list:
    day = date(2025, 1, 1)
    return [
        make_row(day, "1", label=GROCERIES, payee="market", mcc="5411"),
        make_row(day, "2", label=GROCERIES, payee="market", mcc="5411"),
        make_row(day, "3", label=CAFE, payee="market", mcc="5411"),
        make_row(day, "4", label=CAFE, payee="bistro", mcc="5812"),
        make_row(day, "5", label=FUEL, payee="", mcc="5541"),
        make_row(day, "6", label=GROCERIES, payee="", mcc=""),
        make_row(day, "7", label=PHARMACY, payee="", mcc="5541"),
    ]


# Baselines


def test_the_majority_baseline_ranks_by_training_frequency() -> None:
    baseline = MajorityBaseline().fit(training_rows())
    predictions = baseline.predict([make_row(date(2025, 2, 1)), make_row(date(2025, 2, 2))])

    assert predictions.ranked == [[GROCERIES, CAFE, FUEL]] * 2
    assert predictions.confidence.tolist() == [3 / 7, 3 / 7]


def test_the_payee_baseline_falls_back_to_the_mcc_then_to_the_majority() -> None:
    baseline = PayeeMccBaseline().fit(training_rows())
    day = date(2025, 2, 1)
    predictions = baseline.predict(
        [
            make_row(day, payee="market", mcc="5812"),  # a known payee wins over its MCC
            make_row(day, payee="new shop", mcc="5541"),  # unknown payee: the MCC
            make_row(day, payee="", mcc="9999"),  # nothing known: the majority
        ]
    )

    assert predictions.ranked[0] == [GROCERIES, CAFE, FUEL]
    assert predictions.ranked[1] == [FUEL, PHARMACY, GROCERIES]
    assert predictions.ranked[2] == [GROCERIES, CAFE, FUEL]
    assert predictions.confidence.tolist() == pytest.approx([2 / 3, 1 / 2, 3 / 7])
    assert predictions.top1 == [GROCERIES, FUEL, GROCERIES]


def test_a_baseline_never_sees_the_rows_it_predicts() -> None:
    baseline = PayeeMccBaseline().fit(training_rows())
    baseline.predict([make_row(date(2025, 2, 1), payee="later payee", label=FUEL)])

    assert "later payee" not in baseline.payees


# Features


@pytest.mark.parametrize(
    ("amount", "bucket"),
    [
        ("-0.01", 0),
        ("9.99", 0),
        ("-10.00", 1),
        ("99.99", 1),
        ("100", 2),
        ("-2500.50", 3),
        ("1E9", 6),
    ],
)
def test_amount_bucket(amount: str, bucket: int) -> None:
    assert amount_bucket(Decimal(amount)) == bucket


def test_row_features() -> None:
    row = make_row(
        date(2025, 1, 1),
        payee="market",
        merchant="Market",
        bank_description="MARKET 12",
        comment="",
        mcc="5411",
        amount=Decimal("-250.00"),
        currency="USD",
        account_kind="credit",
    )

    assert row_features(row) == {
        "text": "market | Market | MARKET 12",
        "fields": {
            "mcc": "5411",
            "sign": "out",
            "bucket": "USD:2",
            "account_kind": "credit",
            "payee": "market",
        },
    }
    empty = row_features(make_row(date(2025, 1, 1), amount=Decimal("5"), account_kind=""))
    assert empty["text"] == ""
    assert empty["fields"]["mcc"] == "none"
    assert empty["fields"]["sign"] == "in"
    assert empty["fields"]["payee"] == "none"
    assert empty["fields"]["account_kind"] == "none"


# Metrics


def predictions(ranked: list[list[str]], confidence: list[float] | None = None) -> Predictions:
    values = confidence if confidence is not None else [0.5] * len(ranked)
    return Predictions(ranked=ranked, confidence=np.asarray(values, dtype=float))


def test_f1_matches_scikit_learn() -> None:
    rng = np.random.default_rng(0)
    labels = ["a", "b", "c", "d", "e"]
    y_true = [labels[i] for i in rng.integers(0, 4, size=300)]  # "e" is only ever predicted
    y_pred = [labels[i] for i in rng.integers(0, 5, size=300)]
    encoded = Encoded(y_true, {"s": predictions([[p] for p in y_pred])})

    values = headline(encoded.true, encoded.top1["s"], encoded.in_top3["s"], len(encoded.labels))

    # scikit-learn's defaults: macro over true and predicted categories, "e" included at F1 0.
    assert values["macro_f1"] == pytest.approx(f1_score(y_true, y_pred, average="macro"))
    assert values["weighted_f1"] == pytest.approx(f1_score(y_true, y_pred, average="weighted"))
    assert values["accuracy"] == pytest.approx(np.mean(np.array(y_true) == np.array(y_pred)))


def test_per_class_f1_is_zero_for_a_class_never_true_nor_predicted() -> None:
    f1, support = per_class_f1(np.array([0, 0, 1]), np.array([0, 1, 1]), 3)

    assert f1.tolist() == pytest.approx([2 / 3, 2 / 3, 0.0])
    assert support.tolist() == [2, 1, 0]


def test_top3_counts_a_true_label_anywhere_in_the_ranking() -> None:
    encoded = Encoded(["a", "b", "c"], {"s": predictions([["a"], ["c", "b"], ["a", "b", "d"]])})

    assert encoded.in_top3["s"].tolist() == [True, True, False]


def test_coverage_curve_keeps_the_most_confident_rows() -> None:
    correct = np.array([True, False, True, True, False, True, True, True, True, False])
    confidence = np.array([0.95, 0.2, 0.9, 0.85, 0.3, 0.8, 0.75, 0.72, 0.6, 0.1])

    curve = coverage_curve(correct, confidence)

    by_level = {entry["target_coverage"]: entry for entry in curve["at_coverage"]}
    assert by_level[0.1] == {
        "target_coverage": 0.1,
        "coverage": 0.1,
        "rows": 1,
        "precision": 1.0,
        "min_confidence": 0.95,
    }
    assert by_level[0.5]["precision"] == 1.0
    assert by_level[1.0]["precision"] == pytest.approx(0.7)
    by_threshold = {entry["threshold"]: entry for entry in curve["at_threshold"]}
    assert by_threshold[0.7]["rows"] == 6
    assert by_threshold[0.7]["precision"] == 1.0
    assert by_threshold[0.9]["coverage"] == pytest.approx(0.2)
    empty = coverage_curve(np.array([True]), np.array([0.1]))
    assert empty["at_threshold"][0]["precision"] is None


def test_coverage_keeps_whole_tie_groups_whatever_the_row_order() -> None:
    correct = np.array([True, False, True, False, True, False, True, False, True, False])
    confidence = np.full(10, 0.4)

    forward = coverage_curve(correct, confidence)
    backward = coverage_curve(correct[::-1].copy(), confidence)

    assert forward == backward
    first = forward["at_coverage"][0]
    assert (first["target_coverage"], first["coverage"], first["rows"]) == (0.1, 1.0, 10)
    assert first["precision"] == 0.5


def test_mcnemar_with_equal_wins_is_not_significant() -> None:
    a = np.array([True, False, True])
    b = np.array([False, True, True])

    result = mcnemar(a, b)

    assert result["chi2_corrected"] == 0.0
    assert result["chi2_p_value"] == 1.0
    assert result["exact_p_value"] == 1.0


def test_day_block_intervals_resample_whole_days() -> None:
    rng = np.random.default_rng(2)
    y_true = [str(v) for v in rng.integers(0, 3, size=120)]
    ranked = [[t] if rng.random() < 0.7 else ["x"] for t in y_true]
    encoded = Encoded(y_true, {"s": predictions(ranked)})
    days = [i // 4 for i in range(120)]

    first = day_block_intervals(encoded, days, resamples=100, seed=5)
    again = day_block_intervals(encoded, days, resamples=100, seed=5)

    assert first == again
    low, high = first["s"]["accuracy"]
    assert 0 <= low < 0.7 < high <= 1


def test_mcnemar() -> None:
    a = np.array([True] * 10 + [False] * 2 + [True] * 5)
    b = np.array([False] * 10 + [True] * 2 + [True] * 5)

    result = mcnemar(a, b)

    assert result["a_only_correct"] == 10
    assert result["b_only_correct"] == 2
    assert result["chi2_corrected"] == pytest.approx((abs(10 - 2) - 1) ** 2 / 12)
    assert result["exact_p_value"] == pytest.approx(0.0386, abs=1e-4)
    assert mcnemar(a, a)["exact_p_value"] == 1.0


def test_bootstrap_intervals_are_reproducible_and_paired() -> None:
    rng = np.random.default_rng(1)
    y_true = [str(v) for v in rng.integers(0, 3, size=200)]
    good = [[t] if rng.random() < 0.8 else ["x"] for t in y_true]
    bad = [[t] if rng.random() < 0.4 else ["x"] for t in y_true]
    encoded = Encoded(y_true, {"good": predictions(good), "bad": predictions(bad)})

    first = evaluate(encoded, resamples=200, seed=3)
    second = evaluate(encoded, resamples=200, seed=3)

    assert first["rows"] == 200
    for name in ("good", "bad"):
        for metric in ("macro_f1", "weighted_f1", "accuracy", "top3_accuracy"):
            entry = first["systems"][name][metric]
            assert entry == second["systems"][name][metric]
            assert 0 <= entry["ci95"][0] <= entry["ci95"][1] <= 1
    gap = difference(first["_bootstrap"], "good", "bad")
    assert gap["accuracy"][0] > 0


def test_evaluate_on_a_segment_and_on_an_empty_one() -> None:
    encoded = Encoded(["a", "b", "a"], {"s": predictions([["a"], ["a"], ["a"]])})

    part = evaluate(encoded, np.array([True, False, True]), resamples=10, seed=0, detail=False)
    assert part["rows"] == 2
    assert part["systems"]["s"]["accuracy"]["value"] == 1.0
    assert "coverage" not in part["systems"]["s"]
    assert evaluate(encoded, np.zeros(3, dtype=bool), resamples=10, seed=0) == {
        "rows": 0,
        "systems": {},
    }


def test_per_class_lists_support_and_f1() -> None:
    encoded = Encoded(["a", "b", "a"], {"s": predictions([["a"], ["a", "d"], ["c"]])})

    table = per_class(encoded, {"a": 5, "c": 1})  # "d" is only a second guess: not listed

    assert [entry["category"] for entry in table] == ["a", "b", "c"]
    assert table[0]["train_support"] == 5
    assert table[0]["test_support"] == 2
    assert table[0]["f1"]["s"] == pytest.approx(0.5)
    assert table[2]["test_support"] == 0
