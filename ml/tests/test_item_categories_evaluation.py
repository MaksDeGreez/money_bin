"""The offline item-categoriser commands: the runner, the calibration fit, the sanity set."""

import io
import json
import stat
from pathlib import Path
from typing import Any

import pytest

from app.backends import BackendError
from app.categorise.base import Candidate, Categorisation
from app.categorise.calibration import load_calibration
from evaluation import item_categories_calibrate, item_categories_run, item_sanity
from evaluation.common import UsageError, read_categories
from tests.categorise_helpers import CATEGORIES

SANITY_SLUGS = {slug for receipt in item_sanity.read_sanity_set() for _, slug in receipt["items"]}


def item(name: str, slug: str | None, **extra: Any) -> dict[str, Any]:
    return {"name": name, "quantity": "1.000", "amount": "10.00", "category_slug": slug, **extra}


def gt_line(ingest_id: str, items: list[dict[str, Any]], **extra: Any) -> dict[str, Any]:
    line = {
        "receipt_id": 1,
        "ingest_id": ingest_id,
        "source": "manual",
        "items_known": True,
        "categories_known": True,
        "schema_version": 2,
        "document": {"merchant": "Магазин", "issued_at": None, "items": items},
    }
    line.update(extra)
    return line


@pytest.fixture
def files(tmp_path: Path) -> dict[str, Path]:
    ingest = tmp_path / "receipts"
    ingest.mkdir()
    ids = ["rcpt_000001", "rcpt_000002", "rcpt_000003", "rcpt_000004"]
    (ingest / "receipts.jsonl").write_text(
        "".join(json.dumps({"receipt_id": rid}) + "\n" for rid in ids)
    )
    lines = [
        gt_line(
            "rcpt_000002",
            [item("Мол900г", "groceries/groceries"), item("Хліб", None)],
            document={
                "merchant": "Магазин",
                "issued_at": "2026-01-02T10:00:00+02:00",
                "items": [item("Мол900г", "groceries/groceries"), item("Хліб", None)],
            },
        ),
        gt_line(
            "rcpt_000001",
            [
                item("МОЛ 900Г", "groceries/groceries"),
                item("Корм д/котів", "household-shopping/pets"),
            ],
            document={
                "merchant": "Магазин",
                "issued_at": "2026-01-01T10:00:00+02:00",
                "items": [
                    item("МОЛ 900Г", "groceries/groceries"),
                    item("Корм д/котів", "household-shopping/pets"),
                ],
            },
        ),
        # An imported record of the same receipt without categories: the record with them wins.
        gt_line(
            "rcpt_000001",
            [item("other", "other/other-spending")],
            source="dps_xml",
            categories_known=False,
        ),
        # No labels: left out unless asked for (a slug in a record without categories is no label).
        gt_line("rcpt_000003", [item("Гвинт", "other/other-spending")], categories_known=False),
        # Not in the receipt set.
        gt_line("rcpt_999999", [item("Мол900г", "groceries/groceries")]),
        # Items not known: never run.
        gt_line("rcpt_000004", [], items_known=False),
    ]
    ground_truth = tmp_path / "ground_truth.jsonl"
    ground_truth.write_text("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines))
    categories = tmp_path / "item_categories.json"
    categories.write_text(json.dumps({"categories": CATEGORIES}, ensure_ascii=False))
    return {
        "ingest": ingest,
        "ground_truth": ground_truth,
        "categories": categories,
        "out": tmp_path / "runs",
    }


def run_args(files: dict[str, Path], *extra: str) -> Any:
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
            "stub",
            *extra,
        ]
    )


def predictions(run_dir: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in (run_dir / "predictions.jsonl").read_text().splitlines()]


def test_a_run_writes_one_line_per_item_and_a_summary(files: dict[str, Path]) -> None:
    out = io.StringIO()

    summary = item_categories_run.run(run_args(files), out)

    run_dir = files["out"] / summary["run_id"]
    lines = predictions(run_dir)
    # In time order: rcpt_000001 (1 January), then rcpt_000002.
    assert [(line["receipt_id"], line["position"]) for line in lines] == [
        ("rcpt_000001", 1),
        ("rcpt_000001", 2),
        ("rcpt_000002", 1),
        ("rcpt_000002", 2),
    ]
    for line in lines:
        assert set(line) == {
            "receipt_id",
            "position",
            "candidates",
            "source",
            "seconds",
            "cost_usd",
            "error",
        }
        assert line["source"] == "model"
        assert 1 <= len(line["candidates"]) <= 3
        assert isinstance(line["seconds"], str)
        assert line["cost_usd"] is None
    run_json = json.loads((run_dir / "run.json").read_text())
    assert run_json["task"] == "item_categories"
    assert run_json["backend"] == "stub"
    assert run_json["calibrated"] is False
    assert run_json["prompt_version"] is None
    assert run_json["score_kinds"] == {"stub": 2}
    assert run_json["counts"]["items"] == 4
    assert run_json["counts"]["labelled_items"] == 3
    assert run_json["counts"]["labels_outside_categories"] == 0
    assert run_json["cost_usd"] is None
    assert stat.S_IMODE((run_dir / "predictions.jsonl").stat().st_mode) == 0o600
    assert "Мол" not in out.getvalue()


def test_the_memory_answers_from_earlier_receipts_only(files: dict[str, Path]) -> None:
    summary = item_categories_run.run(run_args(files, "--memory"), io.StringIO())

    lines = predictions(files["out"] / summary["run_id"])
    sources = {(line["receipt_id"], line["position"]): line for line in lines}
    # The first receipt has no earlier labels: the model answers.
    assert sources[("rcpt_000001", 1)]["source"] == "model"
    # The same name (another spelling) on the later receipt: the memory answers.
    remembered = sources[("rcpt_000002", 1)]
    assert remembered["source"] == "memory"
    assert remembered["candidates"] == [{"category_slug": "groceries/groceries", "score": 0.888889}]
    assert remembered["cost_usd"] == "0"
    assert summary["counts"]["memory_items"] == 1
    assert summary["memory"]["enabled"] is True


def test_all_receipts_and_filters(files: dict[str, Path], tmp_path: Path) -> None:
    ids = tmp_path / "ids.txt"
    ids.write_text("rcpt_000003\n")

    summary = item_categories_run.run(
        run_args(files, "--all-receipts", "--ids", str(ids)), io.StringIO()
    )

    assert summary["counts"]["receipts"] == 1
    assert summary["counts"]["labelled_items"] == 0
    limited = item_categories_run.run(run_args(files, "--limit", "1"), io.StringIO())
    assert limited["counts"]["receipts"] == 1


def test_a_failed_call_is_recorded_and_the_run_goes_on(
    files: dict[str, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.categorise.stub import StubCategoriser

    calls = {"n": 0}

    def flaky(self: StubCategoriser, request: Any) -> Categorisation:
        calls["n"] += 1
        if calls["n"] == 1:
            error = BackendError(502, "openrouter_upstream_error", "failed")
            error.diagnostics = {"model_calls": 1, "cost_usd": None}
            raise error
        if calls["n"] == 2:
            raise ValueError("a bug")
        return Categorisation([[Candidate("groceries/groceries", 0.4)]], "stub", None)

    monkeypatch.setattr(StubCategoriser, "categorise", flaky)

    summary = item_categories_run.run(run_args(files), io.StringIO())

    lines = predictions(files["out"] / summary["run_id"])
    assert [line["error"] for line in lines] == [
        "openrouter_upstream_error",
        "openrouter_upstream_error",
        "ValueError",
        "ValueError",
    ]
    assert all(line["candidates"] == [] for line in lines)
    assert summary["counts"]["receipts_failed"] == 2
    assert summary["counts"]["failed_items"] == 4


def test_a_hosted_cost_is_split_over_the_items(
    files: dict[str, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.categorise.stub import StubCategoriser

    def paid(self: StubCategoriser, request: Any) -> Categorisation:
        return Categorisation(
            [[Candidate("groceries/groceries", 0.5)] for _ in request.texts],
            "fixed",
            "p",
            {"model_calls": 1, "cost_usd": "0.0003"},
        )

    monkeypatch.setattr(StubCategoriser, "categorise", paid)

    summary = item_categories_run.run(run_args(files), io.StringIO())

    lines = predictions(files["out"] / summary["run_id"])
    assert [line["cost_usd"] for line in lines] == ["0.000150000000"] * 4
    assert summary["cost_usd"]["total_usd"] == "0.0006"
    assert summary["cost_usd"]["per_1000_items_usd"] == "0.150000000000"


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"out": Path(__file__).parent / "runs"}, "inside a git repository"),
        ({"ground_truth": Path("/nonexistent/ground_truth.jsonl")}, "not found"),
        ({"categories": Path("/nonexistent/categories.json")}, "not found"),
    ],
)
def test_bad_inputs_are_usage_errors(
    files: dict[str, Path], change: dict[str, Path], message: str
) -> None:
    with pytest.raises(UsageError, match=message):
        item_categories_run.run(run_args({**files, **change}), io.StringIO())


def test_no_labelled_receipt_is_a_usage_error(files: dict[str, Path], tmp_path: Path) -> None:
    ids = tmp_path / "ids.txt"
    ids.write_text("rcpt_000003\n")

    with pytest.raises(UsageError, match="no receipt"):
        item_categories_run.run(run_args(files, "--ids", str(ids)), io.StringIO())


@pytest.mark.parametrize(
    ("document", "message"),
    [
        ("[]", "no list"),
        ("not json", "not JSON"),
        (json.dumps({"categories": [{"slug": "a/b"}, {"slug": "c/d"}]}), "needs a slug"),
        (json.dumps({"categories": [CATEGORIES[0], CATEGORIES[0]]}), "twice"),
    ],
)
def test_a_bad_categories_file_is_refused(tmp_path: Path, document: str, message: str) -> None:
    path = tmp_path / "categories.json"
    path.write_text(document)

    with pytest.raises(UsageError, match=message):
        read_categories(path)


def test_main_prints_usage_errors(
    files: dict[str, Path], capsys: pytest.CaptureFixture[str]
) -> None:
    code = item_categories_run.main(
        [
            "--ground-truth",
            "/nonexistent",
            "--ingest",
            str(files["ingest"]),
            "--categories",
            str(files["categories"]),
            "--out",
            str(files["out"]),
            "--backend",
            "stub",
        ]
    )

    assert code == 2
    assert "not found" in capsys.readouterr().err


# The calibration fit ------------------------------------------------------------


def make_run(tmp_path: Path, rows: list[tuple[str, int, str, float]], **summary: Any) -> Path:
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "task": "item_categories",
                "run_id": "run-1",
                "backend": "mlx",
                "model_name": "example/model",
                "model_version": "rev",
                "prompt_version": "p1",
                "score_kinds": {"label_probability": 3},
                "calibrated": False,
                **summary,
            }
        )
    )
    (run_dir / "predictions.jsonl").write_text(
        "".join(
            json.dumps(
                {
                    "receipt_id": rid,
                    "position": position,
                    "candidates": [{"category_slug": slug, "score": score}],
                    "source": "model",
                }
            )
            + "\n"
            for rid, position, slug, score in rows
        )
        + json.dumps({"receipt_id": "x", "position": 1, "candidates": [], "source": "memory"})
        + "\n"
    )
    return run_dir


def labelled_truth(tmp_path: Path, count: int) -> Path:
    items = [item(f"item {n}", "groceries/groceries") for n in range(count)]
    path = tmp_path / "gt.jsonl"
    path.write_text(json.dumps(gt_line("rcpt_000001", items)) + "\n")
    return path


def calibrate_args(run_dir: Path, truth: Path, out: Path, *extra: str) -> Any:
    return item_categories_calibrate.parse_args(
        ["--run", str(run_dir), "--ground-truth", str(truth), "--out", str(out), *extra]
    )


def test_a_calibration_is_fitted_and_the_service_can_read_it(tmp_path: Path) -> None:
    rows = [
        (
            "rcpt_000001",
            n + 1,
            "groceries/groceries" if n % 4 else "other/other-spending",
            0.5 + n / 100,
        )
        for n in range(40)
    ]
    run_dir = make_run(tmp_path, rows)
    truth = labelled_truth(tmp_path, 40)
    out = io.StringIO()

    result = item_categories_calibrate.run(calibrate_args(run_dir, truth, tmp_path / "models"), out)

    assert result["items"] == 40
    assert result["accuracy"] == pytest.approx(0.75)
    calibration = load_calibration(Path(result["path"]))
    assert calibration.backend == "mlx"
    assert calibration.model_name == "example/model"
    assert calibration.prompt_version == "p1"
    assert calibration.score_kind == "label_probability"
    assert calibration.labelled_items == 40
    assert list(calibration.ys) == sorted(calibration.ys)
    assert stat.S_IMODE(Path(result["path"]).stat().st_mode) == 0o600
    assert "item 0" not in out.getvalue()  # counts only, never a name


@pytest.mark.parametrize(
    ("summary", "message"),
    [
        ({"task": "ocr"}, "not an item_categories run"),
        ({"calibrated": True}, "calibrated already"),
        ({"score_kinds": {"fixed": 1, "token_logprobs": 1}}, "more than one score kind"),
    ],
)
def test_a_run_that_cannot_be_fitted_is_refused(
    tmp_path: Path, summary: dict[str, Any], message: str
) -> None:
    run_dir = make_run(tmp_path, [("rcpt_000001", 1, "groceries/groceries", 0.9)], **summary)

    with pytest.raises(UsageError, match=message):
        item_categories_calibrate.run(
            calibrate_args(run_dir, labelled_truth(tmp_path, 1), tmp_path / "m"), io.StringIO()
        )


def test_too_few_labelled_items_are_refused(tmp_path: Path) -> None:
    run_dir = make_run(tmp_path, [("rcpt_000001", 1, "groceries/groceries", 0.9)])

    with pytest.raises(UsageError, match="only 1 labelled item"):
        item_categories_calibrate.run(
            calibrate_args(run_dir, labelled_truth(tmp_path, 1), tmp_path / "m"), io.StringIO()
        )
    with pytest.raises(UsageError, match="not a run folder"):
        item_categories_calibrate.run(
            calibrate_args(tmp_path, labelled_truth(tmp_path, 1), tmp_path / "m"), io.StringIO()
        )


def test_the_calibration_is_never_written_into_git(tmp_path: Path) -> None:
    run_dir = make_run(tmp_path, [("rcpt_000001", 1, "groceries/groceries", 0.9)])

    with pytest.raises(UsageError, match="inside a git repository"):
        item_categories_calibrate.run(
            calibrate_args(run_dir, labelled_truth(tmp_path, 1), Path(__file__).parent),
            io.StringIO(),
        )


# The sanity set ------------------------------------------------------------------


def test_the_sanity_set_is_invented_and_uses_the_apps_slugs() -> None:
    receipts = item_sanity.read_sanity_set()

    assert sum(len(receipt["items"]) for receipt in receipts) >= 40
    assert all("/" in slug for slug in SANITY_SLUGS)


def test_the_sanity_command_counts_with_the_stub(tmp_path: Path) -> None:
    rows = [
        {"slug": slug, "name": slug, "description": "", "group": slug.split("/")[0]}
        for slug in sorted(SANITY_SLUGS)
    ]
    path = tmp_path / "categories.json"
    path.write_text(json.dumps({"categories": rows}))
    out = io.StringIO()

    summary = item_sanity.run(
        item_sanity.parse_args(["--categories", str(path), "--backend", "stub", "--show-misses"]),
        out,
    )

    assert summary["items"] >= 40
    assert 0 <= summary["top1"] <= summary["top3"] <= summary["items"]
    assert summary["receipts"] == len(item_sanity.read_sanity_set())


def test_the_sanity_command_needs_every_slug(tmp_path: Path) -> None:
    path = tmp_path / "categories.json"
    path.write_text(json.dumps({"categories": CATEGORIES}))

    assert item_sanity.main(["--categories", str(path), "--backend", "stub"]) == 2
