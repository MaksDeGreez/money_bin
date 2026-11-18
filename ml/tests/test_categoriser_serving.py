"""The fit for serving: what it fits on, what it refuses, and that it scores as training does."""

from __future__ import annotations

import json
import shutil
import stat
from decimal import Decimal
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from categoriser import common, score, selection, serving
from categoriser.common import TrainingError, load_rows
from categoriser.dataset import build_rows
from categoriser.embeddings import CachedEncoder, EmbeddingCache
from categoriser.export import load_export
from categoriser.hybrid import HybridParams, RuleTables, _shares, combine
from categoriser.serving import ServingError, TransactionInput, fit_artefact, load
from categoriser.systems import Config, fit_system
from categoriser.taxonomy import DEFAULT_TAXONOMY, load_taxonomy
from tests.categoriser_export import private_strings, write_export
from tests.categoriser_fakes import FakeEncoder
from tests.test_categoriser_selection import SMALL

CLEAN = {"sha": "0" * 40, "dirty": False}
# The configuration the real selection chose, in miniature: TF-IDF and a sentence embedding,
# recency and class weights, mixed with the payee's and the MCC's history.
HYBRID = Config(
    feature_set="tfidf+embedding",
    encoder="fake",
    c=3.0,
    half_life_days=365.0,
    class_weight_power=0.5,
    hybrid=HybridParams(mode="mix", k=0.5, beta=0.0, alpha_mcc=0.6),
)


@pytest.fixture(scope="module", autouse=True)
def committed_code(tmp_path_factory: pytest.TempPathFactory) -> Any:
    with pytest.MonkeyPatch.context() as patch:
        for module in (common, score, serving):
            patch.setattr(module, "git_state", lambda: dict(CLEAN))
        patch.setattr(serving, "categoriser_changes", lambda _sha: [])
        patch.setattr(score, "DEFAULT_LEDGER", tmp_path_factory.mktemp("home") / "scores.jsonl")
        patch.setattr(serving, "DEFAULT_LEDGER", tmp_path_factory.mktemp("home") / "scores.jsonl")
        yield patch


@pytest.fixture(scope="module")
def selected(tmp_path_factory: pytest.TempPathFactory, committed_code: Any) -> dict[str, Any]:
    root = tmp_path_factory.mktemp("serving")
    export = write_export(root / "export")
    encoders = {"fake": FakeEncoder()}
    chosen = selection.run(
        export_dir=export, out_dir=root / "models", encoders=encoders, echo=lambda _: None, **SMALL
    )
    ledger = root / "data" / "scores.jsonl"
    score.run(
        export_dir=export,
        selection_path=chosen["selection_path"],
        out_dir=root / "models",
        resamples=20,
        encoders=encoders,
        ledger_path=ledger,
        echo=lambda _: None,
    )
    return {
        "root": root,
        "export": export,
        "selection_path": chosen["selection_path"],
        "ledger": ledger,
        "encoders": encoders,
    }


def _run(selected: dict[str, Any], **changes: Any) -> dict[str, Any]:
    options = {
        "export_dir": selected["export"],
        "selection_path": selected["selection_path"],
        "out_dir": selected["root"] / "serving",
        "encoders": selected["encoders"],
        "ledger_path": selected["ledger"],
        "echo": lambda _: None,
    }
    options.update(changes)
    return serving.run(**options)


def test_it_fits_the_chosen_configuration_on_every_labelled_row(selected: dict[str, Any]) -> None:
    result = _run(selected)
    metadata = result["metadata"]
    chosen = json.loads(selected["selection_path"].read_text())
    _export, rows, _counts = load_rows(selected["export"], DEFAULT_TAXONOMY, lambda _: None)
    split = chosen["split"]
    assert metadata["rows"]["fitted"] == len(rows)
    assert len(rows) == split["fit"]["rows"] + split["validation"]["rows"] + split["test"]["rows"]
    assert metadata["rows"]["last_date"] == str(max(row.occurred_on for row in rows))
    assert metadata["configuration"]["config"] == chosen["chosen"]["config"]
    assert metadata["export"]["manifest_sha256"] == chosen["export"]["manifest_sha256"]
    assert metadata["selection"]["sha256"] == common.sha256_file(selected["selection_path"])
    assert metadata["selection"]["split"] == split
    assert "test period" in metadata["fitted_on"]
    assert "no test score of its own" in metadata["evaluation"]["note"]
    assert metadata["evaluation"]["scored_at"]
    assert metadata["code"]["libraries"]["scikit-learn"]
    assert metadata["model_version"].startswith(metadata["fitted_at"][:10])
    assert {entry["label"] for entry in metadata["classes"]} == {row.label for row in rows}


def test_the_files_are_private_and_hold_no_text_of_the_export(selected: dict[str, Any]) -> None:
    result = _run(selected)
    for path in (result["artefact_path"], result["metadata_path"]):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    described = result["metadata_path"].read_text()
    for text in private_strings():
        assert text not in described


def test_the_artefact_scores_as_a_fresh_fit_on_the_same_rows(selected: dict[str, Any]) -> None:
    """The artefact is the training code's fit: the same configuration on the same rows gives the
    same probabilities, and nothing about the test rows was treated differently."""
    result = _run(selected)
    _export, rows, _counts = load_rows(selected["export"], DEFAULT_TAXONOMY, lambda _: None)
    ordered = sorted(rows, key=lambda row: (row.occurred_on, row.legacy_id))
    config = Config.from_dict(result["metadata"]["configuration"]["config"])
    fresh = fit_system(config, ordered, seed=42, encoders=selected["encoders"])
    model = load(result["artefact_path"])
    np.testing.assert_allclose(model.probabilities(rows[:40]), fresh.probabilities(rows[:40]))


def test_a_selection_never_scored_is_refused(selected: dict[str, Any], tmp_path: Path) -> None:
    with pytest.raises(TrainingError, match="no score of this selection"):
        _run(selected, ledger_path=tmp_path / "empty.jsonl")


def test_another_export_is_refused(selected: dict[str, Any], tmp_path: Path) -> None:
    other = tmp_path / "export"
    shutil.copytree(selected["export"], other)
    manifest = json.loads((other / "MANIFEST.json").read_text())
    manifest["note"] = "another export"
    (other / "MANIFEST.json").write_text(json.dumps(manifest))
    with pytest.raises(TrainingError, match="not the one the selection used"):
        _run(selected, export_dir=other)


def test_another_taxonomy_is_refused(selected: dict[str, Any], tmp_path: Path) -> None:
    taxonomy = tmp_path / "taxonomy.yml"
    taxonomy.write_text(DEFAULT_TAXONOMY.read_text() + "\n# changed\n")
    with pytest.raises(TrainingError, match="taxonomy"):
        _run(selected, taxonomy_path=taxonomy)


@pytest.mark.parametrize(
    ("changes", "libraries"),
    [(["ml/categoriser/features.py"], None), (None, None), ([], {"scikit-learn": "0.0"})],
)
def test_code_that_may_fit_differently_is_refused_unless_a_reason_is_given(
    selected: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    changes: list[str] | None,
    libraries: dict[str, str] | None,
) -> None:
    monkeypatch.setattr(serving, "categoriser_changes", lambda _sha: changes)
    if libraries:
        real = common.environment

        def other_libraries() -> dict[str, Any]:
            state = real()
            return {**state, "libraries": {**state["libraries"], **libraries}}

        monkeypatch.setattr(serving, "environment", other_libraries)
    with pytest.raises(TrainingError, match="may fit differently"):
        _run(selected)
    result = _run(selected, code_change_reason="a documented reason")
    assert result["metadata"]["code"]["code_change_reason"] == "a documented reason"


def test_a_changed_selection_is_refused(selected: dict[str, Any], tmp_path: Path) -> None:
    document = json.loads(selected["selection_path"].read_text())
    document["chosen"]["config"]["c"] = 123.0
    path = tmp_path / "selection.json"
    path.write_text(json.dumps(document))
    with pytest.raises(TrainingError, match="selection rule picks"):
        _run(selected, selection_path=path)


def test_an_output_folder_inside_a_repository_is_refused(
    selected: dict[str, Any], tmp_path: Path
) -> None:
    (tmp_path / ".git").mkdir()
    with pytest.raises(TrainingError, match="git repository"):
        _run(selected, out_dir=tmp_path / "models")


def test_the_command_line_fits_and_reports_the_version(
    selected: dict[str, Any], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(serving, "DEFAULT_LEDGER", selected["ledger"])
    monkeypatch.setattr(serving, "real_encoders", lambda names, _cache: selected["encoders"])
    code = serving.main(
        [
            str(selected["export"]),
            "--selection",
            str(selected["selection_path"]),
            "--out",
            str(selected["root"] / "cli"),
        ]
    )
    assert code == 0
    assert "Version:" in capsys.readouterr().out
    assert serving.main([str(selected["export"]), "--selection", "/nonexistent.json"]) == 1


# --- Serving --------------------------------------------------------------------------------------


class ScaledEncoder(FakeEncoder):
    """The fake encoder with vectors far from unit length, as mean pooling gives them."""

    def encode(self, texts: Any) -> np.ndarray:
        return super().encode(texts) * 7.5 + 0.25


def cached(encoder: Any, folder: Path) -> CachedEncoder:
    """The encoder as training uses it: behind the on-disk cache (`selection.real_encoders`)."""
    return CachedEncoder(encoder, EmbeddingCache(folder))


@pytest.fixture(scope="module")
def hybrid(selected: dict[str, Any]) -> dict[str, Any]:
    """The real configuration's shape, fitted on the synthetic rows through `fit_artefact`, with the
    encoder behind the cache as in training."""
    export = load_export(selected["export"])
    rows, _counts = build_rows(export, load_taxonomy())
    encoders = {"fake": cached(ScaledEncoder(), selected["root"] / "cache")}
    result = fit_artefact(
        HYBRID,
        rows,
        seed=42,
        encoders=encoders,
        taxonomy_path=DEFAULT_TAXONOMY,
        out_dir=selected["root"] / "hybrid",
        stem_suffix="synthetic",
        described={},
    )
    model = load(result["artefact_path"], encoder_factory=lambda _name: ScaledEncoder())
    return {"export": export, "rows": rows, "model": model, "encoders": encoders, **result}


def _inputs_from_export(export: Any) -> list[TransactionInput]:
    """What the app would send for the export's own transactions: raw names, decimal strings."""
    accounts = {str(a["legacy_id"]): a for a in export.accounts}
    payees = {str(p["legacy_id"]): p["name"] for p in export.payees}
    inputs = []
    for tx in export.transactions:
        if tx["transfer_key"] is not None:
            continue
        account = accounts[str(tx["account_legacy_id"])]
        payee_id = tx["payee_legacy_id"]
        inputs.append(
            (
                str(tx["legacy_id"]),
                TransactionInput(
                    payee=None if payee_id is None else payees[str(payee_id)],
                    comment=tx["comment"],
                    bank_description=tx["bank_description"],
                    merchant=tx["merchant"],
                    mcc=tx["mcc"],
                    amount=Decimal(tx["amount"]),
                    currency=account["currency"],
                    account_kind=account["kind"],
                ),
            )
        )
    return inputs


def test_serving_and_training_give_the_same_probabilities_for_the_same_rows(
    hybrid: dict[str, Any],
) -> None:
    """The served input path (raw fields → `row_of` → the training code's `System`) and the
    training path (`build_rows` → `fit_system`'s system) agree on every labelled row."""
    rows = hybrid["rows"]
    by_id = dict(_inputs_from_export(hybrid["export"]))
    model = hybrid["model"]
    served = model.probabilities([serving.row_of(by_id[row.legacy_id]) for row in rows])
    training = fit_system(HYBRID, rows, seed=42, encoders=hybrid["encoders"])
    np.testing.assert_allclose(served, training.probabilities(rows), rtol=0, atol=1e-12)
    assert model.labels == training.classes
    scored = model.score([by_id[row.legacy_id] for row in rows[:25]])
    best = np.argsort(-training.probabilities(rows[:25]), axis=1, kind="stable")[:, :3]
    assert [s.labels for s in scored] == [[training.classes[j] for j in r] for r in best]


def test_served_vectors_are_scaled_as_the_cache_scales_them(tmp_path: Path) -> None:
    texts = ["example market", "corner cafe demo", "example market"]
    training = cached(ScaledEncoder(), tmp_path).encode(texts)
    served = serving.UnitEncoder(ScaledEncoder()).encode(texts)
    assert served.dtype == training.dtype == np.float32
    np.testing.assert_array_equal(served, training)
    np.testing.assert_allclose(np.linalg.norm(served, axis=1), 1.0, rtol=1e-6)
    assert serving.UnitEncoder(ScaledEncoder()).encode([]).shape == (0, 0)


def test_the_history_weights_are_the_hybrids_own(hybrid: dict[str, Any]) -> None:
    model = hybrid["model"]
    tables: RuleTables = model._tables
    rows = [serving.row_of(t) for _id, t in _inputs_from_export(hybrid["export"])][:60]
    rows.append(serving.row_of(TransactionInput(merchant="never seen shop", mcc="5411")))
    rows.append(serving.row_of(TransactionInput(comment="nothing known at all")))
    p = model._get_system().model_probabilities(rows)
    combined = combine(p, model.labels, rows, tables, HYBRID.hybrid)
    index = {label: i for i, label in enumerate(model.labels)}
    weights = serving.history_weights(rows, tables, HYBRID.hybrid)
    for i, (row, (history, weight)) in enumerate(zip(rows, weights, strict=True)):
        if history is None:
            np.testing.assert_allclose(combined[i], p[i])
            continue
        counter = tables.payees[row.payee] if history == "payee" else tables.mccs[row.mcc]
        q, _n = _shares(counter, index, len(model.labels))
        np.testing.assert_allclose(combined[i], weight * q + (1 - weight) * p[i])
    assert {history for history, _ in weights} == {"payee", "mcc", None}


def test_the_answer_says_where_it_came_from(hybrid: dict[str, Any]) -> None:
    known = next(row for row in hybrid["rows"] if row.payee)
    model = hybrid["model"]
    seen, unseen = model.score(
        [
            TransactionInput(payee=known.payee.upper(), amount=Decimal("-10.00"), currency="UAH"),
            TransactionInput(comment="an invented text no payee has"),
        ]
    )
    assert (seen.source, seen.history) == ("mix", "payee")
    assert 0 < seen.history_weight < 1
    assert (unseen.source, unseen.history, unseen.history_weight) == ("model", None, 0.0)
    for item in (seen, unseen):
        assert len(item.labels) == 3
        assert item.probabilities == sorted(item.probabilities, reverse=True)
        assert sum(item.probabilities) <= 1 + 1e-9


def test_a_missing_amount_adds_no_size_feature() -> None:
    row = serving.row_of(TransactionInput(merchant="  Some   Shop "))
    assert row.merchant == "Some Shop"
    assert row.amount < 0
    assert row.currency == ""


def test_an_artefact_this_code_cannot_serve_is_refused(
    hybrid: dict[str, Any], tmp_path: Path
) -> None:
    import joblib

    with pytest.raises(ServingError, match="does not exist"):
        load(tmp_path / "missing.serving.joblib")
    broken = tmp_path / "broken.serving.joblib"
    broken.write_bytes(b"not a joblib file")
    with pytest.raises(ServingError, match="cannot be read"):
        load(broken)
    artefact = joblib.load(hybrid["artefact_path"])
    for change, message in (
        ({"kind": "something else"}, "not a serving artefact"),
        ({"format_version": 99}, "another artefact format"),
    ):
        path = tmp_path / "changed.serving.joblib"
        joblib.dump({**artefact, **change}, path)
        with pytest.raises(ServingError, match=message):
            load(path)
    for change, message in (
        ({"feature_version": 99}, "other features"),
        ({"code": {"libraries": {"scikit-learn": "0.0"}}}, "scikit-learn 0.0"),
    ):
        path = tmp_path / "changed.serving.joblib"
        joblib.dump({**artefact, "metadata": {**artefact["metadata"], **change}}, path)
        with pytest.raises(ServingError, match=message):
            load(path)
    no_encoder = load(hybrid["artefact_path"])
    with pytest.raises(ServingError, match="needs a sentence encoder"):
        no_encoder.score([TransactionInput(merchant="a shop")])
    other_encoder = load(hybrid["artefact_path"], lambda _name: ScaledEncoder(key="other@2"))
    with pytest.raises(ServingError, match="encoder differs"):
        other_encoder.score([TransactionInput(merchant="a shop")])
