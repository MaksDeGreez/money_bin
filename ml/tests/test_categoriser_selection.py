"""The selection command, end to end, on the synthetic export: it never reads the test set."""

from __future__ import annotations

import json
import random
import stat
from datetime import date
from pathlib import Path
from typing import Any

import pytest

from categoriser import selection
from categoriser.split import SealedTest, SealedTestError
from categoriser.systems import Config
from tests.categoriser_export import build_transactions, private_strings, write_export
from tests.categoriser_fakes import FakeEncoder

SMALL = {
    "c_grid": (0.5, 2.0),
    "half_lives": (90.0,),
    "class_weight_powers": (0.5,),
    "mix_grid": selection.MIX_GRID[:2],
    "switch_grid": selection.SWITCH_GRID[:2],
    "resamples": 30,
}
VALID_CATEGORIES = (10, 11, 12, 13, 14)


def _refuse(*_args: Any, **_kwargs: Any) -> Any:
    raise AssertionError("a selection run touched the test set")


def select(export: Path, out: Path, lines: list[str] | None = None) -> dict[str, Any]:
    """A selection run during which any access to the test rows fails the test."""
    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(SealedTest, "unseal", _refuse)
        patch.setattr(SealedTest, "rows", property(_refuse))
        return selection.run(
            export_dir=export,
            out_dir=out,
            encoders={"fake": FakeEncoder()},
            echo=(lines.append if lines is not None else lambda _line: None),
            **SMALL,
        )


@pytest.fixture(scope="module")
def selected(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    root = tmp_path_factory.mktemp("selection")
    lines: list[str] = []
    result = select(write_export(root / "export"), root / "models", lines)
    result["console"] = "\n".join(lines)
    result["root"] = root
    return result


def test_the_sealed_test_set_refuses_until_unsealed(selected: dict[str, Any]) -> None:
    test = selected["split"].test

    with pytest.raises(SealedTestError, match="sealed"):
        _ = test.rows
    with pytest.raises(SealedTestError, match="say what"):
        test.unseal(" ")
    assert test.size == selected["selection"]["split"]["test"]["rows"]


def test_the_selection_is_written_privately(selected: dict[str, Any]) -> None:
    path: Path = selected["selection_path"]

    assert path.parent == selected["root"] / "models"
    assert path.name.endswith(".selection.json")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(path.read_text()) == selected["selection"]


def _keys(value: Any, prefix: str = "") -> list[str]:
    if isinstance(value, dict):
        out = []
        for key, item in value.items():
            out += [f"{prefix}{key}", *_keys(item, f"{prefix}{key}.")]
        return out
    if isinstance(value, list):
        return [key for item in value for key in _keys(item, prefix)]
    return []


def test_the_selection_holds_no_test_metric(selected: dict[str, Any]) -> None:
    data = selected["selection"]
    keys = [key for key in _keys(data) if "test" in key.rsplit(".", 1)[-1]]

    assert sorted(set(keys)) == ["reproducibility.parameters.test_fraction", "split.test"]
    assert data["split"]["test"] == {
        "rows": data["split"]["test"]["rows"],
        "first_date": data["split"]["test"]["first_date"],
        "sealed": True,
    }
    assert "Test set" not in selected["console"]


def test_every_candidate_has_validation_metrics_with_intervals(selected: dict[str, Any]) -> None:
    data = selected["selection"]
    names = [row["name"] for row in data["candidates"]]

    for base in ("tfidf", "emb:fake", "tfidf+emb:fake"):
        for variant in ("", "+recency", "+classweight", "+recency+classweight"):
            for hybrid in ("", "+mix", "+switch"):
                assert f"{base}{variant}{hybrid}" in names
    assert len(names) == len(set(names)) == 36
    for row in data["candidates"]:
        for metric in ("macro_f1", "weighted_f1", "accuracy", "top3_accuracy"):
            assert 0 <= row[metric] <= 1
            low, high = row["ci95_days"][metric]
            assert low <= high
            assert row["ci95_rows"][metric][0] <= row["ci95_rows"][metric][1]
        assert len(row["coverage"]["at_coverage"]) == 6
        assert set(row["segments"]) == {
            "with_bank_fields",
            "without_bank_fields",
            "payee_seen_in_train",
            "payee_unseen_or_missing",
        }
        assert Config.from_dict(row["config"]).name == row["name"]
    first = [row for row in data["candidates"] if row["first_version"]]
    assert [row["name"] for row in first] == ["tfidf"] == [data["first_version"]["name"]]
    assert data["best_baseline"] == "payee_mcc"
    assert data["selection_rule"]["tie_margin"] == selection.TIE_MARGIN
    assert data["chosen"]["name"] == data["selection_trace"]["chosen"]
    assert data["reproducibility"]["encoders"] == {"fake": "fake-encoder@1"}


def test_the_console_shows_the_table_and_the_choice(selected: dict[str, Any]) -> None:
    console = selected["console"]

    assert "(sealed)" in console
    assert "Validation slice" in console
    assert f"chosen: {selected['selection']['chosen']['name']}" in console


def test_no_text_from_the_export_reaches_an_output(selected: dict[str, Any]) -> None:
    outputs = selected["selection_path"].read_text() + selected["console"]

    for text in private_strings():
        assert text.lower() not in outputs.lower()


def test_the_selection_does_not_depend_on_test_labels(
    selected: dict[str, Any], tmp_path: Path
) -> None:
    """Shuffle every label of the test period: the selection must not change at all."""
    cut = selected["selection"]["split"]["test"]["first_date"]
    rng = random.Random(3)
    transactions = build_transactions()
    changed = 0
    for row in transactions:
        if row["occurred_on"] < cut:
            continue
        for line in row["lines"]:
            if line["category_legacy_id"] in VALID_CATEGORIES:
                line["category_legacy_id"] = rng.choice(VALID_CATEGORIES)
                changed += 1
    assert changed > 50

    other = select(write_export(tmp_path / "export", transactions), tmp_path / "models")

    before, after = selected["selection"], other["selection"]
    assert before["export"]["manifest_sha256"] != after["export"]["manifest_sha256"]
    for key in ("split", "profile", "baselines", "candidates", "tuning", "chosen", "rows"):
        assert before[key] == after[key], key


def test_every_fit_sees_only_the_rows_before_the_validation_slice(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fitted: list[date] = []
    original = selection.fit_system

    def recording_fit(config: Config, rows: list, **options: Any) -> Any:
        fitted.append(max(row.occurred_on for row in rows))
        return original(config, rows, **options)

    def recording_baseline(original_fit: Any) -> Any:
        def fit(self: Any, rows: list) -> Any:
            fitted.append(max(row.occurred_on for row in rows))
            return original_fit(self, rows)

        return fit

    monkeypatch.setattr(selection, "fit_system", recording_fit)
    for baseline in (selection.MajorityBaseline, selection.PayeeMccBaseline):
        monkeypatch.setattr(baseline, "fit", recording_baseline(baseline.fit))

    result = select(write_export(tmp_path / "export"), tmp_path / "models")

    cut = date.fromisoformat(result["selection"]["split"]["validation"]["first_date"])
    assert len(fitted) > 10
    assert all(last < cut for last in fitted)


def _row(name: str, macro: float, top3: float, low: float, complexity: tuple[int, int]) -> dict:
    return {
        "name": name,
        "macro_f1": macro,
        "top3_accuracy": top3,
        "ci95_days": {"top3_accuracy": [low, 1.0]},
        "complexity": list(complexity),
    }


def test_the_rule_drops_candidates_with_a_poor_top3() -> None:
    table = [
        _row("best_top3", 0.50, 0.95, 0.93, (0, 1)),
        _row("best_f1_poor_top3", 0.60, 0.90, 0.88, (0, 0)),
        _row("runner_up", 0.55, 0.94, 0.92, (1, 1)),
    ]

    chosen, trace = selection.choose(table)

    assert trace["top3_floor"] == 0.93
    assert trace["eligible"] == ["best_top3", "runner_up"]
    assert chosen["name"] == "runner_up"


def test_the_rule_gives_ties_to_the_simpler_model() -> None:
    table = [
        _row("heavy", 0.600, 0.95, 0.90, (1, 2)),
        _row("light", 0.597, 0.95, 0.90, (0, 1)),
        _row("lighter_but_worse", 0.590, 0.95, 0.90, (0, 0)),
    ]

    chosen, trace = selection.choose(table)

    assert trace["within_tie_margin"] == ["heavy", "light"]
    assert chosen["name"] == "light"


@pytest.mark.parametrize(
    ("options", "message"),
    [
        ({"c_grid": ()}, "every C"),
        ({"c_grid": (0.0,)}, "every C"),
        ({"resamples": 0}, "resamples"),
        ({"seed": -1}, "seed"),
        ({"min_df": 0}, "min_df"),
    ],
)
def test_bad_options_are_refused(tmp_path: Path, options: dict[str, Any], message: str) -> None:
    with pytest.raises(selection.TrainingError, match=message):
        selection.run(export_dir=tmp_path, out_dir=tmp_path / "out", **options)


def test_an_output_folder_inside_a_git_repository_is_refused(tmp_path: Path) -> None:
    (tmp_path / "repo" / ".git").mkdir(parents=True)

    with pytest.raises(selection.TrainingError, match="inside a git repository"):
        selection.run(export_dir=tmp_path, out_dir=tmp_path / "repo" / "models")


def test_too_few_rows_are_refused(tmp_path: Path) -> None:
    export = write_export(tmp_path / "export", [])

    with pytest.raises(selection.TrainingError, match="labelled rows"):
        selection.run(export_dir=export, out_dir=tmp_path / "out", echo=lambda _line: None)


def test_main_selects_from_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    export = write_export(tmp_path / "export")

    out = str(tmp_path / "out")
    code = selection.main([str(export), "--out", out, "--c-grid", "1", "--encoders"])

    assert code == 0
    out = capsys.readouterr().out
    assert "Selection:" in out
    assert len(list((tmp_path / "out").glob("*.selection.json"))) == 1
    for text in private_strings():
        assert text not in out


def test_main_reports_a_bad_export_without_a_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = selection.main([str(tmp_path / "missing"), "--out", str(tmp_path / "o"), "--encoders"])

    assert code == 1
    assert "The selection stopped: the export folder does not exist" in capsys.readouterr().err
