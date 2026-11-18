"""Configurations, fitted systems, the hybrid and the embedding cache of the categoriser."""

from __future__ import annotations

import stat
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pytest

from categoriser import selection
from categoriser.common import TrainingError
from categoriser.embeddings import (
    ENCODERS,
    CachedEncoder,
    EmbeddingCache,
    EmbeddingError,
    TransformerEncoder,
    text_key,
)
from categoriser.features import build_model, features
from categoriser.hybrid import SWITCH_WEIGHT, HybridParams, RuleTables, combine
from categoriser.selection import real_encoders
from categoriser.systems import Config, class_weights, fit_system, recency_weights
from tests.categoriser_fakes import FakeEncoder
from tests.test_categoriser_data import make_row

GROCERIES = "Groceries / Groceries"
CAFES = "Eating out / Cafes, bars & restaurants"
FUEL = "Car / Fuel"


def training_rows() -> list:
    start = date(2025, 1, 1)
    rows = []
    for i in range(60):
        payee, label, mcc = [
            ("market one", GROCERIES, "5411"),
            ("cafe two", CAFES, "5814"),
            ("station three", FUEL, "5541"),
        ][i % 3]
        rows.append(
            make_row(
                start + timedelta(days=i), str(i), label=label, payee=payee, mcc=mcc, comment=payee
            )
        )
    return rows


# Config ----------------------------------------------------------------------------------------


def test_the_default_config_is_the_first_version() -> None:
    config = Config(c=3.0)

    assert config.name == "tfidf"
    assert config.complexity == (0, 0)
    rows = training_rows()
    system = fit_system(config, rows, seed=42, encoders={})
    plain = build_model(c=3.0, seed=42).fit(features(rows), [row.label for row in rows])
    np.testing.assert_array_equal(
        system.model_probabilities(rows), plain.predict_proba(features(rows))
    )


def test_config_names_complexity_and_round_trip() -> None:
    config = Config(
        feature_set="tfidf+embedding",
        encoder="e5-large",
        c=0.3,
        half_life_days=180.0,
        class_weight_power=0.5,
        hybrid=HybridParams(mode="mix", k=2.0, beta=1.0, alpha_mcc=0.3),
    )

    assert config.name == "tfidf+emb:e5-large+recency+classweight+mix"
    assert config.complexity == (1, 4)
    assert Config.from_dict(config.as_dict()) == config
    switch = Config(hybrid=HybridParams(mode="switch", min_count=2, min_purity=0.7))
    assert switch.as_dict()["hybrid"] == {"mode": "switch", "min_count": 2, "min_purity": 0.7}
    assert Config.from_dict(switch.as_dict()) == switch
    assert Config(feature_set="embedding", encoder="e5-base").name == "emb:e5-base"


@pytest.mark.parametrize(
    ("options", "message"),
    [
        ({"feature_set": "words"}, "unknown feature set"),
        ({"feature_set": "embedding"}, "an encoder is needed"),
        ({"encoder": "e5-large"}, "an encoder is needed"),
        ({"c": 0.0}, "every C"),
        ({"half_life_days": 0.0}, "half-life"),
        ({"class_weight_power": -1.0}, "class weight power"),
    ],
)
def test_bad_configs_are_refused(options: dict, message: str) -> None:
    with pytest.raises(TrainingError, match=message):
        Config(**options)


def test_recency_weights_halve_per_half_life_and_average_one() -> None:
    rows = [make_row(date(2025, 1, 1)), make_row(date(2025, 1, 11)), make_row(date(2025, 1, 21))]

    weights = recency_weights(rows, half_life_days=10.0)

    assert weights.mean() == pytest.approx(1.0)
    assert weights[2] / weights[1] == pytest.approx(2.0)
    assert weights[1] / weights[0] == pytest.approx(2.0)


def test_class_weights_power_one_is_balanced_and_zero_is_flat() -> None:
    y = ["a", "a", "a", "b"]

    assert class_weights(y, 1.0) == {"a": 4 / 6, "b": 2.0}
    assert class_weights(y, 0.0) == {"a": 1.0, "b": 1.0}


def test_weighted_configs_fit_and_rank() -> None:
    rows = training_rows()
    config = Config(c=1.0, half_life_days=30.0, class_weight_power=0.5)

    predictions = fit_system(config, rows, seed=1, encoders={}).predict(rows[:5])

    assert len(predictions.ranked) == 5
    assert all(len(ranked) == 3 for ranked in predictions.ranked)


def test_fit_needs_two_categories_and_a_known_encoder() -> None:
    rows = training_rows()
    with pytest.raises(TrainingError, match="fewer than two"):
        fit_system(Config(), [row for row in rows if row.label == GROCERIES], seed=1, encoders={})
    with pytest.raises(TrainingError, match="not available"):
        fit_system(Config(feature_set="embedding", encoder="x"), rows, seed=1, encoders={})
    with pytest.raises(TrainingError, match="could not be fitted"):
        fit_system(Config(min_df=10_000), rows, seed=1, encoders={})


@pytest.mark.parametrize("feature_set", ["embedding", "tfidf+embedding"])
def test_embedding_feature_sets_use_the_encoder(feature_set: str) -> None:
    rows = training_rows()
    encoder = FakeEncoder()
    config = Config(feature_set=feature_set, encoder="fake")

    system = fit_system(config, rows, seed=1, encoders={"fake": encoder})
    predictions = system.predict(rows[:3])

    assert [ranked[0] for ranked in predictions.ranked] == [GROCERIES, CAFES, FUEL]
    assert len(encoder.encoded_texts) == len(rows) + 3


def test_features_need_one_embedding_per_row() -> None:
    with pytest.raises(ValueError, match="one embedding per row"):
        features(training_rows()[:2], np.zeros((1, 4)))
    with pytest.raises(ValueError, match="unknown feature set"):
        build_model(c=1.0, seed=1, feature_set="words")


# Hybrid ----------------------------------------------------------------------------------------


def test_rule_tables_count_only_the_rows_they_are_fitted_on() -> None:
    rows = training_rows()
    later = [make_row(date(2026, 1, 1), "x", label=FUEL, payee="market one", mcc="5411")]

    tables = RuleTables().fit(rows)

    assert sum(sum(c.values()) for c in tables.payees.values()) == len(rows)
    assert tables.payees["market one"] == {GROCERIES: 20}
    assert FUEL not in tables.payees["market one"]
    assert sum(sum(c.values()) for c in tables.mccs.values()) == len(rows)
    refitted = RuleTables().fit(rows + later)
    assert refitted.payees["market one"][FUEL] == 1


def test_the_hybrid_of_a_fitted_system_is_built_from_its_own_rows_only() -> None:
    rows = training_rows()
    config = Config(hybrid=HybridParams(mode="mix", k=1.0))

    system = fit_system(config, rows[:30], seed=1, encoders={})

    assert sum(sum(c.values()) for c in system.tables.payees.values()) == 30


def test_mix_weights_the_payee_by_count_and_purity() -> None:
    classes = [GROCERIES, CAFES, FUEL]
    tables = RuleTables().fit(
        [make_row(date(2025, 1, 1), label=GROCERIES, payee="p")] * 3
        + [make_row(date(2025, 1, 1), label=CAFES, payee="p")]
    )
    model = np.array([[0.1, 0.1, 0.8]])
    row = [make_row(date(2025, 2, 1), payee="p")]

    flat = combine(model, classes, row, tables, HybridParams(mode="mix", k=4.0, beta=0.0))
    pure = combine(model, classes, row, tables, HybridParams(mode="mix", k=4.0, beta=2.0))

    weight = 4 / (4 + 4)
    np.testing.assert_allclose(
        flat[0], weight * np.array([0.75, 0.25, 0]) + (1 - weight) * model[0]
    )
    weight = 0.5 * 0.75**2
    np.testing.assert_allclose(
        pure[0], weight * np.array([0.75, 0.25, 0]) + (1 - weight) * model[0]
    )
    np.testing.assert_allclose(flat.sum(axis=1), 1.0)


def test_mix_falls_back_to_the_mcc_for_an_unknown_payee() -> None:
    classes = [GROCERIES, CAFES]
    tables = RuleTables().fit([make_row(date(2025, 1, 1), label=CAFES, payee="p", mcc="5814")])
    model = np.array([[0.9, 0.1], [0.9, 0.1]])
    rows = [make_row(date(2025, 2, 1), payee="new", mcc="5814"), make_row(date(2025, 2, 1))]

    off = combine(model, classes, rows, tables, HybridParams(mode="mix", k=1.0))
    on = combine(model, classes, rows, tables, HybridParams(mode="mix", k=1.0, alpha_mcc=0.6))

    np.testing.assert_allclose(off, model)
    np.testing.assert_allclose(on[0], 0.3 * np.array([0, 1]) + 0.7 * model[0])
    np.testing.assert_allclose(on[1], model[1])


def test_switch_lets_a_consistent_payee_decide() -> None:
    classes = [GROCERIES, CAFES, FUEL]
    tables = RuleTables().fit(
        [make_row(date(2025, 1, 1), label=CAFES, payee="often")] * 3
        + [make_row(date(2025, 1, 1), label=CAFES, payee="once")]
    )
    model = np.array([[0.5, 0.1, 0.4]] * 3)
    rows = [
        make_row(date(2025, 2, 1), payee="often"),
        make_row(date(2025, 2, 1), payee="once"),
        make_row(date(2025, 2, 1), payee="never"),
    ]

    combined = combine(
        model, classes, rows, tables, HybridParams(mode="switch", min_count=2, min_purity=0.9)
    )

    assert combined[0].argmax() == 1
    assert combined[0][1] == pytest.approx(SWITCH_WEIGHT + (1 - SWITCH_WEIGHT) * 0.1)
    assert list(np.argsort(-combined[0])) == [1, 0, 2]  # the model still orders the rest
    np.testing.assert_allclose(combined[1:], model[1:])


def test_an_unknown_hybrid_mode_is_refused() -> None:
    with pytest.raises(ValueError, match="hybrid mode"):
        combine(np.ones((0, 1)), ["a"], [], RuleTables().fit([]), HybridParams(mode="vote"))


# Embedding cache -------------------------------------------------------------------------------


def test_the_cache_key_names_the_encoder_and_the_text() -> None:
    assert text_key("model-a", "text") == text_key("model-a", "text")
    assert text_key("model-a", "text") != text_key("model-b", "text")
    assert text_key("model-a", "text") != text_key("model-a", "text ")
    base, large = ENCODERS["e5-base"], ENCODERS["e5-large"]
    assert base.revision in base.key
    assert "query: " in base.key
    assert "pooling=mean" in large.key
    assert base.key != large.key


def test_cached_encoder_encodes_each_text_once(tmp_path: Path) -> None:
    cache = EmbeddingCache(tmp_path / "cache")
    fake = FakeEncoder()
    encoder = CachedEncoder(fake, cache, batch=2)

    first = encoder.encode(["alpha", "beta", "alpha", "gamma"])
    second = encoder.encode(["gamma", "alpha", "delta"])

    assert fake.encoded_texts == ["alpha", "beta", "gamma", "delta"]
    assert encoder.encoded == 4
    np.testing.assert_allclose(first[0], first[2])
    np.testing.assert_allclose(second[1], first[0])
    np.testing.assert_allclose(np.linalg.norm(first, axis=1), 1.0, rtol=1e-6)
    assert len(cache) == 4
    assert encoder.key == fake.key
    assert encoder.encode([]).shape == (0, 0)


def test_the_cache_persists_and_separates_encoders(tmp_path: Path) -> None:
    folder = tmp_path / "cache"
    first = CachedEncoder(FakeEncoder("model-a"), EmbeddingCache(folder))
    vectors = first.encode(["alpha", "beta"])
    first.cache.close()

    again = FakeEncoder("model-a")
    reopened = CachedEncoder(again, EmbeddingCache(folder))
    np.testing.assert_allclose(reopened.encode(["beta", "alpha"]), vectors[::-1])
    assert again.calls == []

    other = FakeEncoder("model-b")
    CachedEncoder(other, EmbeddingCache(folder)).encode(["alpha"])
    assert other.encoded_texts == ["alpha"]
    assert stat.S_IMODE((folder / "embeddings.sqlite3").stat().st_mode) == 0o600


def test_a_wrong_number_of_vectors_is_refused(tmp_path: Path) -> None:
    class Broken(FakeEncoder):
        def encode(self, texts):  # type: ignore[no-untyped-def]
            return super().encode(texts)[:1]

    encoder = CachedEncoder(Broken(), EmbeddingCache(tmp_path))

    with pytest.raises(EmbeddingError, match="wrong number"):
        encoder.encode(["a", "b"])


def test_real_encoders_are_named_cached_and_lazy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert real_encoders([], tmp_path / "unused") == {}
    with pytest.raises(TrainingError, match="unknown encoder"):
        real_encoders(["nope"], tmp_path / "cache")
    (tmp_path / "repo" / ".git").mkdir(parents=True)
    with pytest.raises(TrainingError, match="embedding cache is inside a git repository"):
        real_encoders(["e5-large"], tmp_path / "repo" / "cache")
    monkeypatch.setattr(selection.importlib.util, "find_spec", lambda _name: None)
    with pytest.raises(EmbeddingError, match="torch and transformers not installed"):
        real_encoders(["e5-base"], tmp_path / "cache")
    monkeypatch.setattr(selection.importlib.util, "find_spec", lambda name: name)

    encoders = real_encoders(["e5-base", "e5-large"], tmp_path / "cache")

    assert set(encoders) == {"e5-base", "e5-large"}
    assert encoders["e5-base"].key == ENCODERS["e5-base"].key
    assert isinstance(encoders["e5-large"].encoder, TransformerEncoder)  # nothing loaded yet


def test_prepare_loads_the_encoder_without_encoding(tmp_path: Path) -> None:
    class Loading(FakeEncoder):
        loaded = 0

        def prepare(self) -> None:
            self.loaded += 1

    loading = Loading()
    CachedEncoder(loading, EmbeddingCache(tmp_path)).prepare()
    CachedEncoder(FakeEncoder(), EmbeddingCache(tmp_path)).prepare()  # nothing to load

    assert loading.loaded == 1
    assert loading.calls == []
