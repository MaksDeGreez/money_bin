"""The evaluation scripts on a synthetic receipt set, with the stub backend.

The stub always answers with its example receipt, so the QR fields below are
set to match it (or not) on purpose.
"""

import io
import json
import stat
from pathlib import Path
from typing import Any

import pytest

from app.ocr.parsing import OcrParseError
from evaluation import ocr_fields, ocr_run
from evaluation.common import (
    UsageError,
    inside_git_repository,
    percentile,
    read_jsonl,
    timing_summary,
)
from tests.conftest import encoded_image

STUB_QR = {
    "issued_at": "2026-01-15T12:34:00+02:00",
    "total": "123.45",
    "fiscal_number": "0000000000",
    "receipt_number": "000123",
}


def line(number: int, parts: int = 1, qr: dict[str, Any] | None = None, crops: bool = False):
    receipt_id = f"rcpt_{number:06d}"
    images = [{"file": f"images/{receipt_id}_{part}.jpg"} for part in range(1, parts + 1)]
    entry: dict[str, Any] = {"receipt_id": receipt_id, "images": images, "qr_fields": qr}
    if crops:
        entry["crop"] = [{"file": f"images/{receipt_id}_1_crop.jpg", "part": 1}]
    return entry


@pytest.fixture
def ingest(tmp_path: Path) -> Path:
    folder = tmp_path / "receipts"
    (folder / "images").mkdir(parents=True)
    lines = [
        line(1, qr=STUB_QR, crops=True),
        line(2, parts=2, qr={**STUB_QR, "total": "99.99", "receipt_number": "777"}),
        line(3),
        line(4, parts=4, qr=STUB_QR),
        line(5, qr={**STUB_QR, "fiscal_number": None}),
    ]
    for entry in lines:
        for image in entry["images"] + entry.get("crop", []):
            (folder / image["file"]).write_bytes(encoded_image())
    with (folder / "receipts.jsonl").open("w") as file:
        for entry in lines:
            file.write(json.dumps(entry) + "\n")
    return folder


def run_args(ingest: Path, out: Path, *extra: str) -> list[str]:
    return ["--ingest", str(ingest), "--out", str(out), "--backend", "stub", *extra]


def the_run(out: Path) -> Path:
    (run_dir,) = out.iterdir()
    return run_dir


def test_a_run_writes_predictions_and_a_summary(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"
    console = io.StringIO()

    summary = ocr_run.run(ocr_run.parse_args(run_args(ingest, out)), console)

    run_dir = the_run(out)
    assert run_dir.name == summary["run_id"]
    assert run_dir.name.endswith("-stub-stub-ocr")
    records = list(read_jsonl(run_dir / "predictions.jsonl"))
    assert [r["receipt_id"] for r in records] == [f"rcpt_{n:06d}" for n in range(1, 6)]
    assert [r["status"] for r in records] == ["ok", "ok", "ok", "skipped", "ok"]
    assert records[0]["receipt"]["total"] == "123.45"
    assert records[1]["images"] == ["full", "full"]
    assert records[3]["error"] == "image_count"
    assert summary["counts"] == {"receipts": 5, "repaired": 0, "ok": 4, "skipped": 1}
    assert summary["seconds_per_receipt"]["count"] == 4
    assert summary["prompt_version"] is None
    assert summary["settings"]["crops"] is False
    assert json.loads((run_dir / "run.json").read_text()) == summary
    output = console.getvalue()
    assert "receipts 5: ok 4, parse_failed 0, error 0, skipped 1, repaired 0" in output


def test_run_files_are_private(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"

    ocr_run.run(ocr_run.parse_args(run_args(ingest, out, "--limit", "1")), io.StringIO())

    run_dir = the_run(out)
    assert stat.S_IMODE(run_dir.stat().st_mode) == 0o700
    for name in ("predictions.jsonl", "run.json"):
        assert stat.S_IMODE((run_dir / name).stat().st_mode) == 0o600


def test_filters_only_tax_qr_and_limit(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"
    args = run_args(ingest, out, "--only-tax-qr", "--limit", "2")

    summary = ocr_run.run(ocr_run.parse_args(args), io.StringIO())

    records = list(read_jsonl(the_run(out) / "predictions.jsonl"))
    assert [r["receipt_id"] for r in records] == ["rcpt_000001", "rcpt_000002"]
    assert summary["filters"] == {"only_tax_qr": True, "ids_file": False, "limit": 2}


def test_ids_file_selects_in_its_order(ingest: Path, tmp_path: Path) -> None:
    ids = tmp_path / "ids.txt"
    ids.write_text("# chosen\nrcpt_000003\n\nrcpt_000001  # first one\nrcpt_000003\n")
    out = tmp_path / "runs"

    ocr_run.run(ocr_run.parse_args(run_args(ingest, out, "--ids", str(ids))), io.StringIO())

    records = list(read_jsonl(the_run(out) / "predictions.jsonl"))
    assert [r["receipt_id"] for r in records] == ["rcpt_000003", "rcpt_000001"]


def test_crops_are_used_where_they_exist(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"

    ocr_run.run(ocr_run.parse_args(run_args(ingest, out, "--crops")), io.StringIO())

    records = list(read_jsonl(the_run(out) / "predictions.jsonl"))
    assert records[0]["images"] == ["crop"]
    assert records[1]["images"] == ["full", "full"]


def test_unknown_ids_are_a_usage_error(ingest: Path, tmp_path: Path) -> None:
    ids = tmp_path / "ids.txt"
    ids.write_text("rcpt_999999\n")

    with pytest.raises(UsageError, match="1 id"):
        ocr_run.run(
            ocr_run.parse_args(run_args(ingest, tmp_path / "runs", "--ids", str(ids))),
            io.StringIO(),
        )


def test_a_missing_ids_file_is_a_usage_error(ingest: Path, tmp_path: Path) -> None:
    with pytest.raises(UsageError, match="--ids file not found"):
        ocr_run.read_ids(tmp_path / "missing.txt")


def test_no_matching_receipt_is_a_usage_error(tmp_path: Path) -> None:
    folder = tmp_path / "empty"
    folder.mkdir()
    (folder / "receipts.jsonl").write_text(json.dumps(line(1)) + "\n")

    with pytest.raises(UsageError, match="no receipt matches"):
        ocr_run.run(
            ocr_run.parse_args(run_args(folder, tmp_path / "runs", "--only-tax-qr")),
            io.StringIO(),
        )


def test_an_output_folder_inside_a_git_repository_is_refused(ingest: Path, tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    (repository / ".git").mkdir(parents=True)

    assert inside_git_repository(repository / "runs" / "new")
    with pytest.raises(UsageError, match="inside a git repository"):
        ocr_run.run(ocr_run.parse_args(run_args(ingest, repository / "runs")), io.StringIO())
    assert not (repository / "runs").exists()


def test_main_returns_2_on_a_usage_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = ocr_run.main(run_args(tmp_path / "missing", tmp_path / "runs"))

    assert code == 2
    assert "no receipts.jsonl" in capsys.readouterr().err


def test_main_returns_0_on_success(ingest: Path, tmp_path: Path) -> None:
    assert ocr_run.main(run_args(ingest, tmp_path / "runs", "--limit", "1")) == 0


def test_limit_must_be_positive(ingest: Path, tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        ocr_run.parse_args(run_args(ingest, tmp_path, "--limit", "0"))


def test_settings_overrides_reach_the_backend(ingest: Path, tmp_path: Path) -> None:
    args = run_args(
        ingest, tmp_path / "runs", "--limit", "1", "--image-max-side", "1024", "--max-tokens", "99"
    )
    args += ["--model", "example/other-model"]

    summary = ocr_run.run(ocr_run.parse_args(args), io.StringIO())

    assert summary["settings"]["image_max_side"] == 1024
    assert summary["settings"]["max_tokens"] == 99


class Failing:
    """A backend whose reading fails in a chosen way."""

    name = "stub"
    model_name = "stub-ocr"
    model_version = "0"

    def __init__(self, error: Exception) -> None:
        self.error = error

    def extract_receipt(self, images: Any) -> Any:
        raise self.error


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (OcrParseError("bad"), "parse_failed", "ocr_parse_failed"),
        (RuntimeError("boom"), "error", "RuntimeError"),
    ],
)
def test_a_failing_receipt_is_recorded_and_the_run_goes_on(
    ingest: Path, error: Exception, status: str, code: str
) -> None:
    if isinstance(error, OcrParseError):
        error.diagnostics["model_calls"] = 2

    record = ocr_run.run_one(Failing(error), ingest, line(1), crops=False)  # type: ignore[arg-type]

    assert record["status"] == status
    assert record["error"] == code
    assert record["receipt"] is None
    assert record["seconds"] is not None
    if status == "parse_failed":
        assert record["diagnostics"] == {"model_calls": 2}


def test_an_undecodable_image_is_recorded(ingest: Path) -> None:
    (ingest / "images" / "rcpt_000003_1.jpg").write_bytes(b"\xff\xd8\xff\xe0broken")
    from app.backends.mlx import MlxBackend
    from app.config import Settings

    class NoModel:
        model_name = "none"
        model_version = "0"

    backend = MlxBackend(Settings(ocr_backend="mlx"), loader=lambda settings: NoModel())  # type: ignore[arg-type, return-value]
    record = ocr_run.run_one(backend, ingest, line(3), crops=False)
    backend.stop()

    assert (record["status"], record["error"]) == ("error", "image_unreadable")


def test_a_missing_image_is_an_error_record_and_the_run_goes_on(
    ingest: Path, tmp_path: Path
) -> None:
    (ingest / "images" / "rcpt_000001_1.jpg").unlink()
    out = tmp_path / "runs"

    summary = ocr_run.run(ocr_run.parse_args(run_args(ingest, out)), io.StringIO())

    records = list(read_jsonl(the_run(out) / "predictions.jsonl"))
    assert (records[0]["status"], records[0]["error"]) == ("error", "FileNotFoundError")
    assert [r["status"] for r in records[1:]] == ["ok", "ok", "skipped", "ok"]
    assert summary["counts"]["error"] == 1
    assert (the_run(out) / "run.json").is_file()


def test_the_run_id_names_the_backend_and_the_model() -> None:
    from datetime import UTC, datetime

    moment = datetime(2026, 1, 15, 12, 34, 56, tzinfo=UTC)

    assert ocr_run.run_id_for("mlx", "example/Model-7B", moment) == "20260115T123456Z-mlx-model-7b"


def test_the_git_commit_is_recorded() -> None:
    commit = ocr_run.git_commit()

    assert set(commit) == {"sha", "dirty"}


def test_the_git_commit_is_unknown_without_git(monkeypatch: pytest.MonkeyPatch) -> None:
    def no_git(*args: Any, **kwargs: Any) -> Any:
        raise OSError("git not found")

    monkeypatch.setattr(ocr_run.subprocess, "run", no_git)

    assert ocr_run.git_commit() == {"sha": None, "dirty": None}


def test_scores_against_the_qr_fields(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"
    ocr_run.run(ocr_run.parse_args(run_args(ingest, out)), io.StringIO())
    run_dir = the_run(out)
    console = io.StringIO()

    scores = ocr_fields.run(ocr_fields.parse_args(["--run", str(run_dir)]), console)

    # Scored: 1 (all match), 2 (total and receipt number differ), 5 (no fiscal number in
    # the QR). 3 has no QR; 4 was skipped.
    assert scores["scored_with_qr"] == 3
    fields = scores["fields"]
    assert fields["date"] == {"hits": 3, "of": 3, "share": 1.0}
    assert fields["time"] == {"hits": 3, "of": 3, "share": 1.0}
    assert fields["total"] == {"hits": 2, "of": 3, "share": 0.6667}
    assert fields["fiscal_number"] == {"hits": 2, "of": 2, "share": 1.0}
    assert fields["receipt_number"] == {"hits": 2, "of": 3, "share": 0.6667}
    assert scores["items_sum_to_qr_total"] == {"hits": 2, "of": 3, "share": 0.6667}
    assert scores["kind_fiscal"] == {"hits": 3, "of": 3, "share": 1.0}
    assert scores["parse_failed"] == {"hits": 0, "of": 4, "share": 0.0}
    assert scores["seconds_per_receipt"]["count"] == 4
    assert json.loads((run_dir / "scores.json").read_text()) == scores
    output = console.getvalue()
    assert "total" in output
    assert "66.7%  (2/3)" in output


def test_a_failed_receipt_is_wrong_for_every_field() -> None:
    predictions = [
        {"receipt_id": "rcpt_000001", "status": "parse_failed", "seconds": 2.0, "receipt": None}
    ]

    scores = ocr_fields.score(predictions, [line(1, qr=STUB_QR)])

    assert all(share["hits"] == 0 for share in scores["fields"].values())
    assert scores["parse_failed"] == {"hits": 1, "of": 1, "share": 1.0}
    assert scores["seconds_per_receipt"]["count"] == 1


def test_times_are_compared_in_kyiv_time_to_the_minute() -> None:
    receipt = {"issued_at": "2026-01-15T10:34:59+00:00", "total": None, "items": []}
    predictions = [
        {"receipt_id": "rcpt_000001", "status": "ok", "seconds": 1.0, "receipt": receipt}
    ]

    scores = ocr_fields.score(predictions, [line(1, qr=STUB_QR)])

    assert scores["fields"]["date"]["hits"] == 1
    assert scores["fields"]["time"]["hits"] == 1
    assert scores["fields"]["total"]["hits"] == 0


@pytest.mark.parametrize(
    "receipt",
    [
        {"issued_at": "not a date", "items": []},
        {"issued_at": "2026-01-15T12:34:00", "items": []},
        {"total": 123.45, "items": [{"amount": None}]},
        {"total": "x", "items": [{"amount": "123.45"}, {"amount": "oops"}]},
    ],
)
def test_odd_predicted_values_never_match(receipt: dict[str, Any]) -> None:
    predictions = [
        {"receipt_id": "rcpt_000001", "status": "ok", "seconds": 1.0, "receipt": receipt}
    ]

    scores = ocr_fields.score(predictions, [line(1, qr=STUB_QR)])

    assert scores["fields"]["date"]["hits"] == 0
    assert scores["fields"]["total"]["hits"] == 0
    assert scores["items_sum_to_qr_total"]["hits"] == 0


def test_a_receipt_set_without_qr_has_no_shares() -> None:
    predictions = [{"receipt_id": "rcpt_000001", "status": "ok", "seconds": 1.0, "receipt": {}}]

    scores = ocr_fields.score(predictions, [line(1)])

    assert scores["fields"]["date"] == {"hits": 0, "of": 0, "share": None}
    out = io.StringIO()
    ocr_fields.print_scores(scores, out)
    assert "n/a" in out.getvalue()


def test_ocr_fields_takes_the_ingest_folder_from_the_option(ingest: Path, tmp_path: Path) -> None:
    out = tmp_path / "runs"
    ocr_run.run(ocr_run.parse_args(run_args(ingest, out, "--limit", "1")), io.StringIO())
    run_dir = the_run(out)
    (run_dir / "run.json").unlink()

    with pytest.raises(UsageError, match="pass --ingest"):
        ocr_fields.run(ocr_fields.parse_args(["--run", str(run_dir)]), io.StringIO())
    scores = ocr_fields.run(
        ocr_fields.parse_args(["--run", str(run_dir), "--ingest", str(ingest)]), io.StringIO()
    )
    assert scores["receipts"] == 1


def test_ocr_fields_main(ingest: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert ocr_fields.main(["--run", str(tmp_path / "nothing")]) == 2
    assert "no predictions.jsonl" in capsys.readouterr().err

    out = tmp_path / "runs"
    ocr_run.run(ocr_run.parse_args(run_args(ingest, out, "--limit", "1")), io.StringIO())
    assert ocr_fields.main(["--run", str(the_run(out))]) == 0


def test_read_jsonl_rejects_bad_lines(tmp_path: Path) -> None:
    path = tmp_path / "x.jsonl"
    path.write_text('{"a": 1}\n\nnot json\n')
    with pytest.raises(UsageError, match="line 3 is not JSON"):
        list(read_jsonl(path))

    path.write_text("[1, 2]\n")
    with pytest.raises(UsageError, match="line 1 is not a JSON object"):
        list(read_jsonl(path))


@pytest.mark.parametrize(
    ("values", "expected"),
    [([], None), ([5.0], 5.0), ([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0], 9.0)],
)
def test_percentile_is_nearest_rank(values: list[float], expected: float | None) -> None:
    assert percentile(values, 0.9) == expected


def test_timing_summary() -> None:
    assert timing_summary([1.0, 2.0, 6.0]) == {"count": 3, "mean": 3.0, "median": 2.0, "p90": 6.0}
    assert timing_summary([]) == {"count": 0, "mean": None, "median": None, "p90": None}


def test_two_runs_in_the_same_second_get_two_folders(tmp_path: Path) -> None:
    first = ocr_run.make_run_dir(tmp_path / "runs", "20260115T123456Z-stub-x")
    second = ocr_run.make_run_dir(tmp_path / "runs", "20260115T123456Z-stub-x")

    assert first.name == "20260115T123456Z-stub-x"
    assert second.name == "20260115T123456Z-stub-x-2"


def test_too_many_run_folders_with_one_name_is_a_usage_error(tmp_path: Path) -> None:
    runs = tmp_path / "runs"
    for _ in range(99):
        ocr_run.make_run_dir(runs, "same")

    with pytest.raises(UsageError, match="too many run folders"):
        ocr_run.make_run_dir(runs, "same")


@pytest.mark.parametrize(
    ("option", "value"),
    [("--image-max-side", "0"), ("--image-max-side", "99999"), ("--max-tokens", "0")],
)
def test_an_invalid_setting_is_a_usage_error(
    ingest: Path, tmp_path: Path, option: str, value: str
) -> None:
    args = ocr_run.parse_args(run_args(ingest, tmp_path / "runs", option, value))

    with pytest.raises(UsageError, match="invalid setting"):
        ocr_run.run(args, io.StringIO())
    assert not (tmp_path / "runs").exists()
