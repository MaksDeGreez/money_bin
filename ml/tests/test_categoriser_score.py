"""The final scoring step on the synthetic export: one score, of the chosen configuration."""

from __future__ import annotations

import json
import shutil
import stat
from pathlib import Path
from typing import Any

import joblib
import pytest

from categoriser import common, score, selection
from categoriser.common import TrainingError
from categoriser.taxonomy import DEFAULT_TAXONOMY
from tests.categoriser_export import build_transactions, private_strings, write_export
from tests.categoriser_fakes import FakeEncoder
from tests.test_categoriser_selection import SMALL

# The first version (`categoriser.train` before the improvements) on the synthetic export, with
# C chosen from (0.5, 2.0), seed 42 and 50 resamples: its model's test metrics. The final step must
# reproduce them for the first version's configuration.
FIRST_VERSION_TEST = {
    "macro_f1": (0.8956867093105899, [0.8481464815810045, 0.945662087527569]),
    "weighted_f1": (0.9009574419894251, [0.8528149252350872, 0.9436403199796851]),
    "accuracy": (0.9010989010989011, [0.8541208791208791, 0.9438186813186813]),
    "top3_accuracy": (0.9395604395604396, [0.9023351648351648, 0.981043956043956]),
}
FIRST_VERSION_DAYS = {
    "macro_f1": [0.8615719829611979, 0.9301046925360426],
    "top3_accuracy": [0.9110209424083769, 0.9723079658605974],
}


CLEAN = {"sha": "0" * 40, "dirty": False}


@pytest.fixture(scope="module", autouse=True)
def committed_code(tmp_path_factory: pytest.TempPathFactory) -> Any:
    """The checks compare git states; the tests run on a fixed, clean one. No test may touch
    the real record of test scores."""
    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(common, "git_state", lambda: dict(CLEAN))
        patch.setattr(score, "git_state", lambda: dict(CLEAN))
        patch.setattr(score, "DEFAULT_LEDGER", tmp_path_factory.mktemp("home") / "scores.jsonl")
        yield patch


@pytest.fixture(scope="module")
def scored(tmp_path_factory: pytest.TempPathFactory, committed_code: Any) -> dict[str, Any]:
    root = tmp_path_factory.mktemp("score")
    export = write_export(root / "export")
    encoders = {"fake": FakeEncoder()}
    chosen = selection.run(
        export_dir=export,
        out_dir=root / "models",
        encoders=encoders,
        echo=lambda _line: None,
        **SMALL,
    )
    fitted: list[tuple[str, set[str]]] = []
    original = score.fit_system

    def recording_fit(config: Any, rows: list, **options: Any) -> Any:
        fitted.append((config.name, {row.legacy_id for row in rows}))
        return original(config, rows, **options)

    lines: list[str] = []
    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(score, "fit_system", recording_fit)
        result = score.run(
            export_dir=export,
            selection_path=chosen["selection_path"],
            out_dir=root / "models",
            resamples=50,
            encoders=encoders,
            ledger_path=root / "data" / "scores.jsonl",
            echo=lines.append,
        )
    result.update(
        root=root,
        export=export,
        console="\n".join(lines),
        fitted=fitted,
        selection=chosen,
        encoders=encoders,
    )
    return result


def test_the_first_version_gives_the_same_numbers_as_before(scored: dict[str, Any]) -> None:
    metrics = scored["metrics"]
    first = metrics["test"]["systems"]["first_version"]

    assert metrics["selection"]["first_version"]["config"]["c"] == 0.5
    for metric, (value, interval) in FIRST_VERSION_TEST.items():
        assert first[metric]["value"] == pytest.approx(value, rel=1e-12)
        assert first[metric]["ci95"] == pytest.approx(interval, rel=1e-12)
    for metric, interval in FIRST_VERSION_DAYS.items():
        assert metrics["test_ci95_resampling_days"]["first_version"][metric] == pytest.approx(
            interval, rel=1e-12
        )


def test_the_final_refit_uses_exactly_the_training_and_validation_rows(
    scored: dict[str, Any],
) -> None:
    split = scored["selection"]["split"]
    train_ids = {row.legacy_id for row in split.fit} | {row.legacy_id for row in split.validation}
    chosen = scored["metrics"]["final_scoring"]["configuration"]["name"]

    assert [name for name, _ in scored["fitted"]] == [chosen, "tfidf"]
    for _name, ids in scored["fitted"]:
        assert ids == train_ids
    assert scored["metrics"]["split"]["train"]["rows"] == len(train_ids)


def test_the_metrics_record_what_was_scored_and_when(scored: dict[str, Any]) -> None:
    metrics = scored["metrics"]
    final = metrics["final_scoring"]
    chosen = scored["selection"]["selection"]["chosen"]

    assert metrics["kind"] == "categoriser-final-score"
    assert final["configuration"] == {"name": chosen["name"], "config": chosen["config"]}
    assert final["scored_at"] == metrics["created_at"]
    assert final["earlier_scores_of_this_export"] == []
    assert final["rescore_reason"] is None
    assert "had been seen" in final["protocol"]
    assert final["unsealed_for"].startswith(f"final score of {chosen['name']}")
    assert metrics["selection"]["file"] == scored["selection"]["selection_path"].name
    assert len(metrics["selection"]["sha256"]) == 64
    assert metrics["selection"]["rule"] == selection.SELECTION_RULE


def test_every_system_and_comparison_is_reported(scored: dict[str, Any]) -> None:
    metrics = scored["metrics"]

    assert set(metrics["test"]["systems"]) == {"majority", "payee_mcc", "first_version", "final"}
    assert set(metrics["test_ci95_resampling_days"]) == set(metrics["test"]["systems"])
    for key in (
        "final_minus_best_baseline_ci95",
        "final_minus_best_baseline_ci95_resampling_days",
        "final_minus_first_version_ci95",
        "final_minus_first_version_ci95_resampling_days",
    ):
        assert set(metrics[key]) == {"macro_f1", "weighted_f1", "accuracy", "top3_accuracy"}
    assert metrics["mcnemar_final_vs_best_baseline"]["baseline"] == "payee_mcc"
    assert "final_only_correct" in metrics["mcnemar_final_vs_first_version"]
    assert "first_version_only_correct" in metrics["mcnemar_final_vs_first_version"]
    assert "baseline_only_correct" in metrics["mcnemar_first_version_vs_best_baseline"]
    assert set(metrics["segments"]) == {
        "with_bank_fields",
        "without_bank_fields",
        "payee_seen_in_train",
        "payee_unseen_or_missing",
    }
    assert metrics["per_class"]
    assert metrics["profile"]["test"]["with_bank_fields"] > 0


def test_files_are_private_and_the_model_scores_new_rows(scored: dict[str, Any]) -> None:
    for path in (scored["model_path"], scored["metrics_path"]):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(scored["metrics_path"].read_text()) == scored["metrics"]
    artifact = joblib.load(scored["model_path"])
    assert artifact["config"] == scored["metrics"]["final_scoring"]["configuration"]["config"]
    assert artifact["labels"]


def test_nothing_from_the_export_reaches_an_output(scored: dict[str, Any]) -> None:
    outputs = scored["metrics_path"].read_text() + scored["console"]

    for text in private_strings():
        assert text.lower() not in outputs.lower()
    assert "Scoring the test set once" in scored["console"]
    assert "McNemar, final vs first_version" in scored["console"]


def _fresh(tmp_path: Path) -> dict[str, Path]:
    """An empty output folder and record, so the check under test is the one that refuses."""
    return {"out_dir": tmp_path / "out", "ledger_path": tmp_path / "scores.jsonl"}


def _options(scored: dict[str, Any], **changes: Any) -> dict[str, Any]:
    options = {
        "export_dir": scored["export"],
        "selection_path": scored["selection"]["selection_path"],
        "out_dir": scored["root"] / "models",
        "resamples": 5,
        "encoders": scored["encoders"],
        "ledger_path": scored["root"] / "data" / "scores.jsonl",
        "echo": lambda _line: None,
    }
    options.update(changes)
    return options


def test_the_unsealing_is_recorded_privately(scored: dict[str, Any]) -> None:
    ledger = scored["root"] / "data" / "scores.jsonl"
    entries = [json.loads(line) for line in ledger.read_text().splitlines()]

    assert stat.S_IMODE(ledger.stat().st_mode) == 0o600
    assert entries[0]["manifest_sha256"] == scored["metrics"]["export"]["manifest_sha256"]
    assert entries[0]["unsealed_at"] == scored["metrics"]["final_scoring"]["scored_at"]
    assert (
        entries[0]["configuration"] == scored["metrics"]["final_scoring"]["configuration"]["name"]
    )
    assert scored["metrics"]["final_scoring"]["code"]["at_selection"] == CLEAN


def test_a_second_score_is_refused_unless_a_reason_is_given(
    scored: dict[str, Any], tmp_path: Path
) -> None:
    with pytest.raises(TrainingError, match="already scored"):
        score.run(**_options(scored))
    with pytest.raises(TrainingError, match="already scored"):
        score.run(**_options(scored, rescore_reason="  "))
    # Another output folder does not help: the record of test scores is kept apart from it.
    with pytest.raises(TrainingError, match=r"scores.jsonl line 1"):
        score.run(**_options(scored, out_dir=tmp_path / "elsewhere"))

    again = score.run(**_options(scored, rescore_reason="a crash in the plotting script"))

    final = again["metrics"]["final_scoring"]
    assert final["rescore_reason"] == "a crash in the plotting script"
    assert scored["metrics_path"].name in final["earlier_scores_of_this_export"]
    again["metrics_path"].unlink()
    again["model_path"].unlink()


def test_the_seal_stays_closed_when_the_refit_fails(
    scored: dict[str, Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def failing_fit(*_args: Any, **_kwargs: Any) -> Any:
        raise TrainingError("the model could not be fitted")

    monkeypatch.setattr(score, "fit_system", failing_fit)
    ledger = tmp_path / "scores.jsonl"

    with pytest.raises(TrainingError, match="could not be fitted"):
        score.run(**_options(scored, out_dir=tmp_path / "out", ledger_path=ledger))

    assert not ledger.exists()


def test_an_encoder_that_cannot_load_fails_before_the_seal_opens(
    scored: dict[str, Any], tmp_path: Path
) -> None:
    class Broken(FakeEncoder):
        def prepare(self) -> None:
            raise score.EmbeddingError("the weights are not in the local cache")

    data = json.loads(scored["selection"]["selection_path"].read_text())
    ledger = tmp_path / "scores.jsonl"

    with pytest.raises(score.EmbeddingError, match="weights"):
        score.run(
            **_options(
                scored,
                encoders={"fake": Broken(data["reproducibility"]["encoders"]["fake"])},
                **_fresh(tmp_path),
            )
        )

    assert not ledger.exists()


def test_a_score_recorded_meanwhile_stops_the_run(tmp_path: Path) -> None:
    ledger = tmp_path / "scores.jsonl"
    entry = {"manifest_sha256": "abc"}
    score._record(ledger, entry, known=0, rescore=False)

    with pytest.raises(TrainingError, match="meanwhile"):
        score._record(ledger, entry, known=0, rescore=False)
    score._record(ledger, entry, known=0, rescore=True)

    assert len(ledger.read_text().splitlines()) == 2
    assert stat.S_IMODE(ledger.stat().st_mode) == 0o600


def test_other_code_is_refused_unless_a_reason_is_given(
    scored: dict[str, Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    options = _options(scored, out_dir=tmp_path / "out", ledger_path=tmp_path / "scores.jsonl")
    for state in (
        {"sha": "1" * 40, "dirty": False},
        {"sha": "0" * 40, "dirty": True},
        {"sha": None, "dirty": None},
    ):
        monkeypatch.setattr(score, "git_state", lambda state=state: dict(state))
        with pytest.raises(TrainingError, match="not the committed code"):
            score.run(**options)

    result = score.run(**options, code_change_reason="a comment was fixed")

    assert result["metrics"]["final_scoring"]["code_change_reason"] == "a comment was fixed"
    assert result["metrics"]["final_scoring"]["code"]["at_scoring"]["dirty"] is None


def test_another_encoder_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    data = json.loads(scored["selection"]["selection_path"].read_text())
    # Make the rule pick the embedding candidate, as if it had won on validation.
    row = next(row for row in data["candidates"] if row["name"] == "emb:fake")
    row.update(macro_f1=1.0, top3_accuracy=1.0)
    data["chosen"] = {"name": row["name"], "config": row["config"]}
    changed = tmp_path / "selection.json"
    changed.write_text(json.dumps(data))
    other = {"fake": FakeEncoder("fake-encoder@2")}

    with pytest.raises(TrainingError, match="encoder 'fake' is not the one"):
        score.run(**_options(scored, selection_path=changed, encoders=other, **_fresh(tmp_path)))
    with pytest.raises(TrainingError, match="encoder 'fake' is not the one"):
        score.run(**_options(scored, selection_path=changed, encoders={}, **_fresh(tmp_path)))


def test_another_export_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    transactions = build_transactions()
    transactions[0]["comment"] = "changed"
    other = write_export(tmp_path / "export", transactions)

    with pytest.raises(TrainingError, match="not the one the selection used"):
        score.run(**_options(scored, export_dir=other, **_fresh(tmp_path)))


def test_another_taxonomy_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    taxonomy = tmp_path / "taxonomy.yml"
    shutil.copy(DEFAULT_TAXONOMY, taxonomy)
    taxonomy.write_text(taxonomy.read_text() + "\n# changed\n")

    with pytest.raises(TrainingError, match="taxonomy is not the one"):
        score.run(**_options(scored, out_dir=tmp_path / "out", taxonomy_path=taxonomy))


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda data: data["split"]["fit"].update(rows=data["split"]["fit"]["rows"] + 1), "split"),
        (lambda data: data["split"]["test"].update(rows=1), "test set differs"),
        (lambda data: data["split"]["test"].update(first_date="2000-01-01"), "test set differs"),
        (lambda data: data.update(selection_version=0), "another version"),
        (lambda data: data["reproducibility"]["git"].update(dirty=True), "committed code"),
        (lambda data: data["reproducibility"]["git"].update(sha=None), "committed code"),
        (lambda data: data["reproducibility"]["libraries"].update(numpy="0.0"), "library"),
        (lambda data: data["chosen"].update(name="tfidf+switch"), "selection rule picks"),
        (lambda data: data["chosen"]["config"].update(c=123.0), "selection rule picks"),
        (lambda data: data.pop("chosen"), "no usable chosen"),
    ],
)
def test_a_changed_selection_is_refused(
    scored: dict[str, Any], tmp_path: Path, change: Any, message: str
) -> None:
    data = json.loads(scored["selection"]["selection_path"].read_text())
    change(data)
    changed = tmp_path / "selection.json"
    changed.write_text(json.dumps(data))

    with pytest.raises(TrainingError, match=message):
        score.run(**_options(scored, selection_path=changed, **_fresh(tmp_path)))


@pytest.mark.parametrize("content", ["not json", json.dumps({"kind": "other"}), "[]"])
def test_a_bad_selection_file_is_refused(tmp_path: Path, content: str) -> None:
    path = tmp_path / "selection.json"
    path.write_text(content)

    with pytest.raises(TrainingError, match="selection"):
        score.run(export_dir=tmp_path, selection_path=path, out_dir=tmp_path / "out")


def test_unreadable_earlier_scores_count_as_scores(tmp_path: Path) -> None:
    (tmp_path / "transaction-categoriser-x.final.json").write_text("{")
    (tmp_path / "transaction-categoriser-y.final.json").write_text(
        json.dumps({"export": {"manifest_sha256": "other"}})
    )
    ledger = tmp_path / "scores.jsonl"
    ledger.write_text('{"manifest_sha256": "other"}\nnot json\n{"manifest_sha256": "abc"}\n')

    assert score._earlier_scores(tmp_path, "abc") == ["transaction-categoriser-x.final.json"]
    assert score._ledger_scores(ledger, "abc") == ["scores.jsonl line 2", "scores.jsonl line 3"]
    assert score._ledger_scores(tmp_path / "none.jsonl", "abc") == []


def test_main_scores_from_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    export = write_export(tmp_path / "export")
    out = tmp_path / "out"
    selection.main(
        [str(export), "--out", str(out), "--c-grid", "1", "--resamples", "5", "--encoders"]
    )
    path = next(out.glob("*.selection.json"))
    capsys.readouterr()

    code = score.main(
        [str(export), "--selection", str(path), "--out", str(out), "--resamples", "5"]
    )

    assert code == 0
    printed = capsys.readouterr().out
    assert "Metrics:" in printed
    assert len(list(out.glob("*.final.json"))) == 1
    for text in private_strings():
        assert text not in printed

    code = score.main([str(export), "--selection", str(path), "--out", str(tmp_path / "other")])

    assert code == 1
    assert "already scored" in capsys.readouterr().err
