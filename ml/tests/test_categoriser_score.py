"""The final scoring step on the synthetic export: one score, of the chosen configuration."""

from __future__ import annotations

import json
import shutil
import stat
from pathlib import Path
from typing import Any

import joblib
import pytest

from categoriser import score, selection
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


@pytest.fixture(scope="module")
def scored(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
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


def test_a_second_score_is_refused_unless_a_reason_is_given(scored: dict[str, Any]) -> None:
    options = {
        "export_dir": scored["export"],
        "selection_path": scored["selection"]["selection_path"],
        "out_dir": scored["root"] / "models",
        "resamples": 5,
        "encoders": scored["encoders"],
        "echo": lambda _line: None,
    }
    with pytest.raises(TrainingError, match="already scored"):
        score.run(**options)
    with pytest.raises(TrainingError, match="already scored"):
        score.run(**options, rescore_reason="  ")

    again = score.run(**options, rescore_reason="a crash in the plotting script")

    final = again["metrics"]["final_scoring"]
    assert final["rescore_reason"] == "a crash in the plotting script"
    assert scored["metrics_path"].name in final["earlier_scores_of_this_export"]
    again["metrics_path"].unlink()
    again["model_path"].unlink()


def test_another_export_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    transactions = build_transactions()
    transactions[0]["comment"] = "changed"
    other = write_export(tmp_path / "export", transactions)

    with pytest.raises(TrainingError, match="not the one the selection used"):
        score.run(
            export_dir=other,
            selection_path=scored["selection"]["selection_path"],
            out_dir=tmp_path / "out",
            echo=lambda _line: None,
        )


def test_another_taxonomy_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    taxonomy = tmp_path / "taxonomy.yml"
    shutil.copy(DEFAULT_TAXONOMY, taxonomy)
    taxonomy.write_text(taxonomy.read_text() + "\n# changed\n")

    with pytest.raises(TrainingError, match="taxonomy is not the one"):
        score.run(
            export_dir=scored["export"],
            selection_path=scored["selection"]["selection_path"],
            out_dir=tmp_path / "out",
            taxonomy_path=taxonomy,
        )


def test_a_changed_split_is_refused(scored: dict[str, Any], tmp_path: Path) -> None:
    data = json.loads(scored["selection"]["selection_path"].read_text())
    data["split"]["fit"]["rows"] += 1
    changed = tmp_path / "selection.json"
    changed.write_text(json.dumps(data))

    with pytest.raises(TrainingError, match="split differs"):
        score.run(
            export_dir=scored["export"],
            selection_path=changed,
            out_dir=tmp_path / "out",
            echo=lambda _line: None,
        )


@pytest.mark.parametrize("content", ["not json", json.dumps({"kind": "other"}), "[]"])
def test_a_bad_selection_file_is_refused(tmp_path: Path, content: str) -> None:
    path = tmp_path / "selection.json"
    path.write_text(content)

    with pytest.raises(TrainingError, match="selection"):
        score.run(export_dir=tmp_path, selection_path=path, out_dir=tmp_path / "out")


def test_an_unreadable_earlier_score_counts_as_a_score(tmp_path: Path) -> None:
    (tmp_path / "transaction-categoriser-x.final.json").write_text("{")
    (tmp_path / "transaction-categoriser-y.final.json").write_text(
        json.dumps({"export": {"manifest_sha256": "other"}})
    )

    assert score._earlier_scores(tmp_path, "abc") == ["transaction-categoriser-x.final.json"]


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

    code = score.main([str(export), "--selection", str(path), "--out", str(out)])

    assert code == 1
    assert "already scored" in capsys.readouterr().err
