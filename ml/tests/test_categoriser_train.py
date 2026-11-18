"""The training command, end to end, on the synthetic export."""

from __future__ import annotations

import json
import stat
from datetime import date
from pathlib import Path
from typing import Any

import joblib
import pytest

from categoriser import train
from categoriser.features import features
from categoriser.train import TrainingError, main, run
from tests.categoriser_export import private_strings, write_export
from tests.test_categoriser_data import make_row


@pytest.fixture(scope="module")
def trained(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    root = tmp_path_factory.mktemp("categoriser")
    export = write_export(root / "export")
    lines: list[str] = []
    result = run(
        export_dir=export,
        out_dir=root / "models",
        c_grid=(0.5, 2.0),
        resamples=50,
        echo=lines.append,
    )
    result["console"] = "\n".join(lines)
    result["root"] = root
    return result


def test_run_writes_a_private_model_file_and_metrics(trained: dict[str, Any]) -> None:
    model_path: Path = trained["model_path"]
    metrics_path: Path = trained["metrics_path"]

    assert model_path.parent == metrics_path.parent == trained["root"] / "models"
    assert model_path.name.startswith("transaction-categoriser-")
    assert model_path.name.endswith(".joblib")
    for path in (model_path, metrics_path):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(metrics_path.read_text()) == trained["metrics"]


def test_the_metrics_name_the_data_and_the_run(trained: dict[str, Any]) -> None:
    metrics = trained["metrics"]

    assert len(metrics["export"]["manifest_sha256"]) == 64
    assert metrics["reproducibility"]["seed"] == train.DEFAULT_SEED
    assert set(metrics["reproducibility"]["libraries"]) == {
        "scikit-learn",
        "numpy",
        "scipy",
        "joblib",
    }
    assert "sha" in metrics["reproducibility"]["git"]
    assert metrics["rows"]["multi_line"] > 0
    assert metrics["rows"]["multi_line_tied"] > 0
    assert metrics["training_seconds"] >= 0
    assert metrics["model_file"] == trained["model_path"].name
    assert len(metrics["reproducibility"]["taxonomy_sha256"]) == 64
    assert metrics["rows"]["dropped_not_in_taxonomy"] > 0
    by_day = metrics["test_ci95_resampling_days"]
    assert set(by_day) == {"majority", "payee_mcc", "model"}
    assert len(by_day["model"]["macro_f1"]) == 2


def test_the_split_is_by_date_with_validation_inside_training(trained: dict[str, Any]) -> None:
    split = trained["metrics"]["split"]

    assert split["train"]["last_date"] < split["test"]["first_date"]
    assert split["train"]["first_date"] < split["validation"]["first_date"]
    assert split["validation"]["last_date"] == split["train"]["last_date"]
    assert split["test_share"] >= 0.2
    assert (
        split["train"]["rows"] + split["test"]["rows"]
        == trained["metrics"]["rows"]["labelled_rows"]
    )


def test_every_system_has_headline_metrics_with_intervals(trained: dict[str, Any]) -> None:
    metrics = trained["metrics"]

    assert set(metrics["test"]["systems"]) == {"majority", "payee_mcc", "model"}
    for values in metrics["test"]["systems"].values():
        for metric in ("macro_f1", "weighted_f1", "accuracy", "top3_accuracy"):
            low, high = values[metric]["ci95"]
            assert 0 <= low <= high <= 1
            assert 0 <= values[metric]["value"] <= 1
        assert len(values["coverage"]["at_coverage"]) == 6
    model = metrics["test"]["systems"]["model"]
    majority = metrics["test"]["systems"]["majority"]
    assert model["macro_f1"]["value"] > majority["macro_f1"]["value"]
    assert metrics["tuning"]["chosen_c"] in (0.5, 2.0)
    assert metrics["tuning"]["best_baseline"] == "payee_mcc"
    mcnemar = metrics["mcnemar_model_vs_best_baseline"]
    assert mcnemar["baseline"] == "payee_mcc"
    assert 0 <= mcnemar["exact_p_value"] <= 1


def test_segments_show_the_shift_in_the_data(trained: dict[str, Any]) -> None:
    metrics = trained["metrics"]
    segments = metrics["segments"]

    assert set(segments) == {
        "with_bank_fields",
        "without_bank_fields",
        "payee_seen_in_train",
        "payee_unseen_or_missing",
    }
    test_rows = metrics["split"]["test"]["rows"]
    assert segments["with_bank_fields"]["rows"] + segments["without_bank_fields"]["rows"] == (
        test_rows
    )
    assert (
        metrics["profile"]["test"]["with_bank_fields"]
        > metrics["profile"]["train"]["with_bank_fields"]
    )
    assert 0 < metrics["profile"]["test"]["payee_seen_in_train"] < 1
    assert segments["payee_unseen_or_missing"]["rows"] > 0


def test_tuning_and_fitting_see_only_earlier_rows(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Record every set of rows anything is fitted on and check their dates against the cuts."""
    fitted: list[tuple[str, date]] = []
    original_features = train.features

    def recording_features(rows: list) -> list:
        fitted.append(("model", max(row.occurred_on for row in rows)))
        return original_features(rows)

    def recording_fit(original: Any, kind: str) -> Any:
        def fit(self: Any, rows: list) -> Any:
            fitted.append((kind, max(row.occurred_on for row in rows)))
            return original(self, rows)

        return fit

    monkeypatch.setattr(train, "features", recording_features)
    monkeypatch.setattr(
        train.MajorityBaseline, "fit", recording_fit(train.MajorityBaseline.fit, "majority")
    )
    monkeypatch.setattr(
        train.PayeeMccBaseline, "fit", recording_fit(train.PayeeMccBaseline.fit, "payee_mcc")
    )

    result = run(
        export_dir=write_export(tmp_path / "export"),
        out_dir=tmp_path / "out",
        c_grid=(0.5, 2.0),
        resamples=5,
        echo=lambda _line: None,
    )

    split = result["metrics"]["split"]
    validation_start = date.fromisoformat(split["validation"]["first_date"])
    test_start = date.fromisoformat(split["test"]["first_date"])
    assert [kind for kind, _ in fitted] == [
        "model",
        "model",
        "majority",
        "payee_mcc",
        "model",
        "majority",
        "payee_mcc",
    ]
    tuning, final = fitted[:4], fitted[4:]
    assert all(last < validation_start for _, last in tuning)
    assert all(validation_start <= last < test_start for _, last in final)


def test_a_model_that_cannot_be_fitted_stops_cleanly(tmp_path: Path) -> None:
    export = write_export(tmp_path / "export")

    with pytest.raises(TrainingError, match="could not be fitted"):
        run(export_dir=export, out_dir=tmp_path / "out", min_df=10_000, echo=lambda _l: None)


def test_one_category_is_not_enough(tmp_path: Path) -> None:
    from tests.categoriser_export import build_transactions

    rows = [t for t in build_transactions() if t["lines"]]
    for row in rows:
        row["lines"] = [{"amount": row["amount"], "category_legacy_id": 10}]
    export = write_export(tmp_path / "export", rows)

    with pytest.raises(TrainingError, match="fewer than two categories"):
        run(export_dir=export, out_dir=tmp_path / "out", echo=lambda _l: None)


def test_a_missing_taxonomy_stops_from_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    export = write_export(tmp_path / "export")

    code = main(
        [str(export), "--out", str(tmp_path / "o"), "--taxonomy", str(tmp_path / "none.yml")]
    )

    assert code == 1
    assert "taxonomy file" in capsys.readouterr().err


def test_nothing_is_fitted_on_test_rows(trained: dict[str, Any]) -> None:
    """The late payee occurs only in the test period: no fitted vocabulary may know it."""
    pipeline = joblib.load(trained["model_path"])["pipeline"]
    union = pipeline.named_steps["features"]
    parts = dict(union.transformer_list)
    vocabulary: set[str] = set(parts["fields"].named_steps["onehot"].feature_names_)
    for name in ("word", "char"):
        vocabulary |= set(parts[name].named_steps["tfidf"].vocabulary_)

    assert not any("zeta" in term for term in vocabulary)
    assert any("market" in term for term in vocabulary)


def test_the_saved_model_scores_new_rows(trained: dict[str, Any]) -> None:
    artifact = joblib.load(trained["model_path"])
    rows = [make_row(date(2026, 1, 1), payee="example market", mcc="5411")]

    probabilities = artifact["pipeline"].predict_proba(features(rows))

    assert probabilities.shape == (1, len(artifact["labels"]))
    assert artifact["manifest_sha256"] == trained["metrics"]["export"]["manifest_sha256"]


def test_no_text_from_the_export_reaches_an_output(trained: dict[str, Any]) -> None:
    outputs = trained["metrics_path"].read_text() + trained["console"]

    for text in private_strings():
        assert text not in outputs
        assert text.lower() not in outputs.lower()


def test_the_console_shows_counts_and_metrics(trained: dict[str, Any]) -> None:
    console = trained["console"]

    assert "labelled rows" in console
    assert "macro-F1" in console
    assert "McNemar" in console


def test_an_output_folder_inside_a_git_repository_is_refused(tmp_path: Path) -> None:
    (tmp_path / "repo" / ".git").mkdir(parents=True)

    with pytest.raises(TrainingError, match="inside a git repository"):
        run(export_dir=tmp_path / "unused", out_dir=tmp_path / "repo" / "models")


@pytest.mark.parametrize(
    ("options", "message"),
    [({"c_grid": ()}, "every C"), ({"c_grid": (0.0,)}, "every C"), ({"resamples": 0}, "resamples")],
)
def test_bad_options_are_refused(tmp_path: Path, options: dict[str, Any], message: str) -> None:
    with pytest.raises(TrainingError, match=message):
        run(export_dir=tmp_path, out_dir=tmp_path / "out", **options)


def test_too_few_rows_are_refused(tmp_path: Path) -> None:
    export = write_export(tmp_path / "export", [])

    with pytest.raises(TrainingError, match="labelled rows"):
        run(export_dir=export, out_dir=tmp_path / "out", echo=lambda _line: None)


def test_main_trains_from_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    export = write_export(tmp_path / "export")

    code = main([str(export), "--out", str(tmp_path / "out"), "--c-grid", "1", "--resamples", "20"])

    assert code == 0
    out = capsys.readouterr().out
    assert "Metrics:" in out
    assert len(list((tmp_path / "out").glob("*.metrics.json"))) == 1
    for text in private_strings():
        assert text not in out


def test_main_reports_a_bad_export_without_a_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = main([str(tmp_path / "missing"), "--out", str(tmp_path / "out")])

    assert code == 1
    assert "The training stopped: the export folder does not exist" in capsys.readouterr().err
