"""The offline decision-model runs, the sanity command's new figures, and the run combiner."""

import io
import json
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from app.categorise.decisions import DecisionsCategoriser
from evaluation import item_categories_combine as combine
from evaluation import item_categories_run, item_sanity
from evaluation.common import UsageError
from evaluation.item_scores import Scored, accepted_at_precision, reliability, summary
from evaluation.label_memory import LabelMemory
from tests.categorise_helpers import CATEGORIES
from tests.decisions_helpers import DECIDER, FakeDecisions, decision_settings
from tests.test_item_categories_evaluation import files, gt_line, item, predictions  # noqa: F401
from tests.test_openrouter_backend import Clock


def decisions_args(files: dict[str, Path], *extra: str) -> Any:  # noqa: F811
    return item_categories_run.parse_args(
        [
            "--ground-truth",
            str(files["ground_truth"]),
            "--ingest",
            str(files["ingest"]),
            "--categories",
            str(files["categories"]),
            "--out",
            str(files["out"]),
            "--backend",
            "decisions",
            *extra,
        ]
    )


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch) -> FakeDecisions:
    transport = FakeDecisions()

    real = item_categories_run.create_categoriser

    def create(name: str, settings: Any, worker: Any = None) -> Any:
        if name != "decisions":
            return real(name, settings)
        values = settings.model_dump()
        values.update(openrouter_api_key=decision_settings().openrouter_api_key)
        values["decisions_model"] = values["decisions_model"] or DECIDER
        merged = decision_settings(
            **{k: values[k] for k in values if k.startswith("decisions_")},
        )
        return DecisionsCategoriser(merged, transport=transport, clock=Clock())

    monkeypatch.setattr(item_categories_run, "create_categoriser", create)
    monkeypatch.setattr(item_sanity, "create_categoriser", create)
    return transport


# The runner -----------------------------------------------------------------------------------


def test_a_request_built_from_a_ground_truth_record_holds_item_names_only(
    files: dict[str, Path],  # noqa: F811
    fake: FakeDecisions,
) -> None:
    summary = item_categories_run.run(decisions_args(files), io.StringIO())

    first = fake.posts[0]["body"]
    assert set(first) == {"model", "state", "questions", "provider"}
    # The earliest receipt, rcpt_000001: its two item names and nothing else of the record.
    assert first["state"] == {"line_1": "МОЛ 900Г", "line_2": "Корм д/котів"}
    assert set(first["questions"]) == {"line_1", "line_2"}
    sent = json.dumps([post["body"] for post in fake.posts], ensure_ascii=False)
    for private in ("Магазин", "10.00", "1.000", "rcpt_", "2026-01", "receipt_id", "merchant"):
        assert private not in sent
    assert summary["backend"] == "decisions"
    assert summary["model_name"] == DECIDER
    assert summary["score_kinds"] == {"decision_probability": 2}
    decisions = summary["decisions"]
    assert decisions["strategy"] == "flat"
    assert decisions["receipt_context"] is True
    assert decisions["zdr_endpoints"] == ["decider"]
    assert summary["prompt_version"] == DecisionsCategoriser(decision_settings()).prompt_version
    assert summary["cost_usd"]["total_usd"] == "0.000036"


def test_examples_come_from_earlier_receipts_only(
    files: dict[str, Path],  # noqa: F811
    fake: FakeDecisions,
) -> None:
    item_categories_run.run(decisions_args(files, "--examples", "2"), io.StringIO())

    first, second = (post["body"]["state"] for post in fake.posts)
    # The first receipt (in time order) has no earlier labels; the second is shown the earlier
    # receipt's milk, labelled, and nothing of its own labels.
    assert "examples" not in first
    assert second["examples"] == [{"item": "МОЛ 900Г", "category": "Groceries"}]
    assert "`examples`" in fake.posts[1]["body"]["questions"]["line_1"]["instructions"]
    assert "`examples`" not in fake.posts[1]["body"]["questions"]["line_2"]["instructions"]


def test_the_runner_verifies_another_runs_candidates(
    files: dict[str, Path],  # noqa: F811
    fake: FakeDecisions,
) -> None:
    proposer = item_categories_run.run(
        item_categories_run.parse_args(
            [
                "--ground-truth",
                str(files["ground_truth"]),
                "--ingest",
                str(files["ingest"]),
                "--categories",
                str(files["categories"]),
                "--out",
                str(files["out"]),
                "--backend",
                "stub",
            ]
        ),
        io.StringIO(),
    )
    proposer_dir = files["out"] / proposer["run_id"]

    summary = item_categories_run.run(
        decisions_args(files, "--verify", str(proposer_dir)), io.StringIO()
    )

    assert summary["decisions"]["strategy"] == "verify"
    assert summary["decisions"]["verified_run"] == proposer["run_id"]
    questions = [q for post in fake.posts for q in post["body"]["questions"].values()]
    assert questions and all(q["type"] == "noul" for q in questions)
    lines = predictions(files["out"] / summary["run_id"])
    assert all(c["score"] == 0.8 for line in lines for c in line["candidates"])


def test_a_verify_folder_must_be_a_run(files: dict[str, Path], tmp_path: Path) -> None:  # noqa: F811
    with pytest.raises(UsageError, match="no predictions"):
        item_categories_run.read_proposals(tmp_path)
    (tmp_path / "predictions.jsonl").write_text('{"receipt_id": "x"}\n')
    with pytest.raises(UsageError, match="not an item-category run"):
        item_categories_run.read_proposals(tmp_path)


@pytest.mark.parametrize(
    "extra",
    [["--strategy", "two-stage"], ["--examples", "2"], ["--no-receipt-context"]],
)
def test_decision_options_need_the_decisions_backend(
    files: dict[str, Path],  # noqa: F811
    extra: list[str],
) -> None:
    with pytest.raises(SystemExit):
        item_categories_run.parse_args(
            ["--ground-truth", "g", "--ingest", "i", "--categories", "c", "--out", "o", *extra]
        )


def test_decision_settings_reach_the_categoriser(
    files: dict[str, Path],  # noqa: F811
    fake: FakeDecisions,
) -> None:
    summary = item_categories_run.run(
        decisions_args(
            files, "--strategy", "two-stage", "--no-receipt-context", "--max-questions", "3"
        ),
        io.StringIO(),
    )
    assert summary["decisions"]["categorise_strategy"] == "two-stage"
    assert summary["decisions"]["receipt_context"] is False
    assert summary["decisions"]["max_questions"] == 3
    assert all(set(post["body"]["state"]) == {"item"} for post in fake.posts)


# The label memory's similar items -------------------------------------------------------------


def test_similar_items_are_other_labelled_names_with_a_majority() -> None:
    memory = LabelMemory()
    memory.add("Молоко 2,5% 900г", "groceries/groceries")
    memory.add("Молоко 3,2% 900г", "groceries/groceries")
    memory.add("Корм д/котів 85г", "household-shopping/pets")
    memory.add("Корм д/котів 400г", "household-shopping/pets")
    memory.add("Корм д/котів 400г", "groceries/groceries")

    similar = memory.similar("Молоко 1% 900г", 3)

    assert similar[0][1] == "groceries/groceries"
    assert {name for name, _ in similar} <= {"Молоко 2,5% 900г", "Молоко 3,2% 900г"}
    # No strict majority for the 400 g cat food: never an example.
    assert all(name != "Корм д/котів 400г" for name, _ in memory.similar("Корм д/котів 100г", 5))
    assert memory.similar("Молоко 2,5% 900г", 1) == [("Молоко 2,5% 900г", "groceries/groceries")]
    assert memory.similar("Цвях", 3) == []
    assert memory.similar("", 3) == [] and memory.similar("Молоко", 0) == []


# Scores ---------------------------------------------------------------------------------------


def test_the_auto_accept_share_keeps_ties_together() -> None:
    items = [
        Scored(("a",), 0.99, "a"),
        Scored(("a",), 0.9, "a"),
        Scored(("b",), 0.9, "a"),
        Scored(("a",), 0.5, "a"),
    ]
    assert accepted_at_precision(items) == {"share": 0.25, "items": 1, "threshold": 0.99}
    assert accepted_at_precision(items, 0.6) == {"share": 1.0, "items": 4, "threshold": 0.5}
    assert accepted_at_precision([Scored((), 0.0, "a")])["threshold"] is None


def test_reliability_bins_and_summary() -> None:
    items = [Scored(("a",), 1.0, "a"), Scored(("b", "a"), 0.6, "a"), Scored((), 0.0, "a")]
    table = reliability(items)
    assert [row["items"] for row in table] == [1, 1, 0, 0, 0, 1]
    assert table[-1]["accuracy"] == 1.0
    result = summary(items)
    assert (result["top1"], result["top3"], result["without_candidates"]) == (1, 2, 1)
    assert summary([]) == {"items": 0}


# The sanity command ---------------------------------------------------------------------------


def test_the_sanity_command_reports_scores_cost_and_verification(
    tmp_path: Path, fake: FakeDecisions
) -> None:
    slugs = sorted({slug for r in item_sanity.read_sanity_set() for _, slug in r["items"]})
    rows = [
        {"slug": slug, "name": slug.split("/")[1], "description": "", "group": slug.split("/")[0]}
        for slug in slugs
    ]
    path = tmp_path / "categories.json"
    path.write_text(json.dumps({"categories": rows}))

    report = item_sanity.run(
        item_sanity.parse_args(
            ["--categories", str(path), "--backend", "decisions", "--verify", "--model", DECIDER]
        ),
        io.StringIO(),
    )

    assert report["by_set"]["base"]["items"] == 43
    assert report["by_set"]["extension"]["items"] == report["items"] - 43
    assert report["hosted"]["requests"] >= report["receipts"] * 2
    assert report["hosted"]["cost_complete"] is True
    assert report["verified"]["items"] == report["items"]
    assert "reliability" in report["scores"]
    with pytest.raises(SystemExit):
        item_sanity.parse_args(["--categories", str(path), "--backend", "stub", "--verify"])


# The combiner ---------------------------------------------------------------------------------

SLUGS = [row["slug"] for row in CATEGORIES]


def write_run(folder: Path, name: str, lines: list[dict[str, Any]], **summary: Any) -> Path:
    path = folder / name
    path.mkdir(parents=True)
    (path / "run.json").write_text(
        json.dumps({"task": "item_categories", "run_id": name, **summary})
    )
    (path / "predictions.jsonl").write_text(
        "".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines)
    )
    return path


def line(
    receipt: str, position: int, *candidates: tuple[str, float], **extra: Any
) -> dict[str, Any]:
    return {
        "receipt_id": receipt,
        "position": position,
        "candidates": [{"category_slug": s, "score": p} for s, p in candidates],
        "source": "model",
        "seconds": "0.100",
        "cost_usd": "0.00001",
        "error": None,
        **extra,
    }


@pytest.fixture
def combo(tmp_path: Path) -> dict[str, Any]:
    """Two invented runs over 30 items of 10 receipts: run A is right on even items, B on all but
    every fifth; the last receipt's labels were chosen with B's suggestions on screen."""
    rng = np.random.default_rng(1)
    truth: dict[tuple[str, int], str] = {}
    a_lines, b_lines, gt = [], [], []
    for r in range(10):
        receipt = f"rcpt_{r:06d}"
        items = []
        for p in range(1, 4):
            index = r * 3 + p
            label = SLUGS[int(rng.integers(0, len(SLUGS)))]
            wrong = SLUGS[(SLUGS.index(label) + 1) % len(SLUGS)]
            truth[(receipt, p)] = label
            a_lines.append(line(receipt, p, (label if index % 2 == 0 else wrong, 0.9)))
            other = SLUGS[(SLUGS.index(label) + 2) % len(SLUGS)]
            b_choice = other if index % 5 == 0 else label
            b_lines.append(
                line(receipt, p, (b_choice, 0.7), (label if b_choice == other else other, 0.2))
            )
            items.append(item(f"invented {index}", label))
        extra = {"categories_prefilled_by": "model-b"} if r == 9 else {}
        gt.append(gt_line(receipt, items, **extra))
    # An item only one run has: left out.
    a_lines.append(line("rcpt_999999", 1, (SLUGS[0], 0.5)))
    runs = tmp_path / "inputs"
    a = write_run(runs, "run-a", a_lines, model_name="model-a", memory={"enabled": True})
    b = write_run(runs, "run-b", b_lines, model_name="model-b", prompt_version="p1")
    ground_truth = tmp_path / "ground_truth.jsonl"
    ground_truth.write_text("".join(json.dumps(g, ensure_ascii=False) + "\n" for g in gt))
    return {"a": a, "b": b, "gt": ground_truth, "out": tmp_path / "runs", "truth": truth}


def combine_args(combo: dict[str, Any], *extra: str) -> Any:
    return combine.parse_args(
        [
            "--run",
            str(combo["a"]),
            "--run",
            str(combo["b"]),
            "--ground-truth",
            str(combo["gt"]),
            "--out",
            str(combo["out"]),
            *extra,
        ]
    )


def test_a_cascade_takes_the_first_confident_run(combo: dict[str, Any]) -> None:
    summary = combine.run(
        combine_args(combo, "--method", "cascade", "--thresholds", "0.95"), io.StringIO()
    )

    assert summary["method_info"]["decided_by"] == {"run-a": 0, "run-b": 30}
    assert summary["counts"]["items"] == 30
    assert summary["counts"]["items_not_in_every_run"] == 1
    assert summary["counts"]["excluded_by_prefill"] == 3
    assert summary["counts"]["scored_items"] == 27
    assert summary["categorisers"] == ["label-memory", "model-a", "model-b"]
    lines = predictions(combo["out"] / summary["run_id"])
    assert all(line["source"] == "combined" for line in lines)
    assert lines[0]["seconds"] == "0.200" and lines[0]["cost_usd"] == "0.00002"
    loose = combine.run(
        combine_args(combo, "--method", "cascade", "--thresholds", "0.5"), io.StringIO()
    )
    assert loose["method_info"]["decided_by"] == {"run-a": 30, "run-b": 0}


def test_an_average_and_the_agreement_figures(combo: dict[str, Any]) -> None:
    summary = combine.run(
        combine_args(combo, "--method", "average", "--weights", "1,3"), io.StringIO()
    )

    agreement = summary["agreement"]
    assert agreement["items"] == 27
    assert agreement["all_agree_precision"] == 1.0
    assert 0 < agreement["all_agree_share"] < 1
    assert set(agreement["pairwise_agreement"]) == {"run-a|run-b"}
    assert summary["calibrated"] is False
    # B weighs three times A: the average follows B.
    assert agreement["combined_accuracy"] == agreement["run_accuracy"]["run-b"]


def test_a_learned_combination_is_cross_validated_by_receipt(
    combo: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: list[tuple[set[str], set[str]]] = []
    real = combine._fit_predict

    def spy(x_train: Any, y_train: Any, x_test: Any, n: int, c: float) -> Any:
        return real(x_train, y_train, x_test, n, c)

    monkeypatch.setattr(combine, "_fit_predict", spy)
    from sklearn.model_selection import GroupKFold

    original = GroupKFold.split

    def split(self: Any, x: Any, y: Any = None, groups: Any = None) -> Any:
        for train, test in original(self, x, y, groups):
            seen.append(({groups[i] for i in train}, {groups[i] for i in test}))
            yield train, test

    monkeypatch.setattr(GroupKFold, "split", split)

    summary = combine.run(combine_args(combo, "--method", "learned", "--folds", "3"), io.StringIO())

    assert len(seen) == 3
    assert all(not (train & test) for train, test in seen)
    # The receipt whose labels B pre-filled is in no fold.
    assert all("rcpt_000009" not in train | test for train, test in seen)
    info = summary["method_info"]
    assert info["fitted_items"] == 27 and info["fitted_receipts"] == 9
    assert info["full_fit_items"] == 3
    assert set(info["weight_share"]) == {"run-a", "run-b"}
    assert summary["calibrated"] is True
    scores = summary["scores_on_usable_items"]
    assert scores["items"] == 27


def test_the_combiner_refuses_bad_inputs(combo: dict[str, Any], tmp_path: Path) -> None:
    with pytest.raises(UsageError, match="needs --thresholds"):
        combine.run(combine_args(combo, "--method", "cascade"), io.StringIO())
    with pytest.raises(UsageError, match="one threshold per run"):
        combine.run(
            combine_args(combo, "--method", "cascade", "--thresholds", "0.1,0.2"), io.StringIO()
        )
    with pytest.raises(UsageError, match="weight"):
        combine.run(combine_args(combo, "--method", "average", "--weights", "1"), io.StringIO())
    with pytest.raises(UsageError, match="numbers"):
        combine.run(combine_args(combo, "--method", "average", "--weights", "x"), io.StringIO())
    with pytest.raises(SystemExit):
        combine.parse_args(
            ["--run", "a", "--ground-truth", "g", "--out", "o", "--method", "average"]
        )
    with pytest.raises(UsageError, match="not a run folder"):
        combine.read_input(tmp_path)
    bad = write_run(tmp_path / "bad", "x", [{"receipt_id": "r"}])
    with pytest.raises(UsageError, match="line 1"):
        combine.read_input(bad)
    other = write_run(tmp_path / "other", "y", [], task="ocr")
    (other / "run.json").write_text(json.dumps({"task": "ocr"}))
    with pytest.raises(UsageError, match="not an item_categories run"):
        combine.read_input(other)
    inside = combine.parse_args(
        [
            "--run",
            str(combo["a"]),
            "--run",
            str(combo["a"]),
            "--ground-truth",
            str(combo["gt"]),
            "--out",
            str(Path(__file__).parent / "runs"),
            "--method",
            "average",
        ]
    )
    with pytest.raises(UsageError, match="git"):
        combine.run(inside, io.StringIO())
    inside.out = combo["out"]
    with pytest.raises(UsageError, match="twice"):
        combine.run(inside, io.StringIO())


def test_too_few_labels_for_a_learned_combination(combo: dict[str, Any], tmp_path: Path) -> None:
    empty = tmp_path / "empty.jsonl"
    empty.write_text("")
    args = combine_args(combo, "--method", "learned")
    args.ground_truth = empty
    with pytest.raises(UsageError, match="at least 20"):
        combine.run(args, io.StringIO())
    assert (
        combine.main(
            [
                "--run",
                str(combo["a"]),
                "--run",
                str(combo["b"]),
                "--ground-truth",
                str(empty),
                "--out",
                str(combo["out"]),
                "--method",
                "learned",
            ]
        )
        == 2
    )


def test_one_label_in_a_fold_predicts_that_label() -> None:
    out, model = combine._fit_predict(np.zeros((2, 2)), np.array([1, 1]), np.zeros((1, 2)), 3, 1.0)
    assert model is None and out.tolist() == [[0.0, 1.0, 0.0]]
