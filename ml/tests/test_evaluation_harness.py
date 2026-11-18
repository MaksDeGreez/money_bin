"""The evaluation harness on synthetic inputs, with every number worked out by hand.

The standard set (`tests/evaluation_fixtures.py`):

- rcpt_000001: QR; a `dps_xml` record with three items (SentinelBread 40.00, Milk 60.00, Пакет
  2.00) and the merchant `ТОВ "SentinelShop"`. Predicted: Milk and SentinelBred (swapped, one
  typo), every QR field right, merchant SentinelShop, items summing to 100.00, not 102.00.
- rcpt_000002 (two photos): QR; a `manual` record pre-filled by Model-A. Predicted right.
- rcpt_000003: no QR; a `manual` card slip (no items, merchant Cafe, total 75.00). Predicted as
  `fiscal`, no items, merchant cafe.
- rcpt_000004: QR; a `dps_xml` record the QR contradicts. Parse failure.
"""

import io
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest

from evaluation import harness
from evaluation.common import UsageError
from evaluation.inputs import discover_runs, read_ground_truth, read_receipt_set, read_run
from evaluation.ocr_scoring import score_run
from evaluation.results import (
    OCR_RUN_RESULT,
    Context,
    Est,
    ResultsShapeError,
    ResultsWriter,
    check,
    check_cell,
)
from evaluation.truth import GroundTruth, same_model
from tests import evaluation_fixtures as fx

REPOSITORY = Path(__file__).resolve().parents[2]


@pytest.fixture
def inputs(tmp_path: Path) -> dict[str, Path]:
    receipts = fx.write_receipt_set(tmp_path / "receipts")
    truth = fx.write_truth(tmp_path / "ground_truth", fx.standard_truth())
    runs = tmp_path / "runs"
    fx.write_run(runs, "run-a", fx.standard_predictions())
    return {"receipts": receipts, "truth": truth, "runs": runs, "out": tmp_path / "results"}


def args_for(paths: dict[str, Path], *extra: str) -> Any:
    return harness.parse_args(
        [
            "--receipts",
            str(paths["receipts"]),
            "--runs",
            str(paths["runs"]),
            "--ground-truth",
            str(paths["truth"]),
            "--out",
            str(paths["out"]),
            "--resamples",
            "200",
            *extra,
        ]
    )


def run_harness(paths: dict[str, Path], *extra: str) -> tuple[dict[str, Any] | None, str]:
    console = io.StringIO()
    index = harness.run(args_for(paths, *extra), console)
    return index, console.getvalue()


def result(paths: dict[str, Path], run_id: str) -> dict[str, Any]:
    return json.loads((paths["out"] / "runs" / f"{run_id}.json").read_text(encoding="utf-8"))


def value(metric: dict[str, Any]) -> float | None:
    return metric["value"]


# --- OCR metrics ---------------------------------------------------------------------------


def test_ocr_metrics_worked_by_hand(inputs: dict[str, Path]) -> None:
    run_harness(inputs)
    all_ = result(inputs, "run-a")["segments"]["all"]

    assert all_["receipts"] == 4
    # QR fields over the three QR receipts; the parse failure is wrong.
    for name in ("date", "time", "total", "fiscal_number", "receipt_number"):
        assert all_["fields"][name]["numerator"] == 2
        assert all_["fields"][name]["denominator"] == 3
        assert value(all_["fields"][name]) == pytest.approx(2 / 3)
    # Merchant: r1 (legal form dropped) and r3 (case) right; r2 pre-filled; r4 excluded.
    assert (all_["merchant"]["numerator"], all_["merchant"]["denominator"]) == (2, 2)
    # Kind: r1 right, r2 right against its QR (its record is pre-filled), r3 wrong, r4 failed.
    assert value(all_["kind"]["accuracy"]) == 0.5
    assert all_["kind"]["confusion"] == {
        "fiscal": {"fiscal": 2, "card_slip": 0, "none": 1},
        "card_slip": {"fiscal": 1, "card_slip": 0, "none": 0},
    }
    items = all_["items"]
    # Items: r1 (3 reference, 2 predicted, 2 matched) and r3 (nothing on either side).
    assert (items["receipts"], items["reference_items"], items["predicted_items"]) == (2, 3, 2)
    main = items["main"]
    assert value(main["precision"]) == 1.0
    assert value(main["recall"]) == pytest.approx(2 / 3)
    assert value(main["f1_micro"]) == pytest.approx(0.8)
    assert value(main["f1_macro"]) == pytest.approx((0.8 + 1.0) / 2)
    assert value(items["strict"]["f1_micro"]) == pytest.approx(0.8)
    assert value(items["lenient"]["f1_micro"]) == pytest.approx(0.8)
    # CER: "sentinelbred"/"sentinelbread" 1 edit over 13 letters, "milk 2 5 900 g" 0 over 14.
    assert value(items["cer_normalised"]) == pytest.approx(1 / 27)
    # Plain: "," for ".", " г" for "g" (2 edits) and the missing "a": 4 over 14 + 13.
    assert value(items["cer_plain"]) == pytest.approx(4 / 27)
    # Sums: r2 only (r1 adds to 100.00, r3 has no items, r4 failed).
    assert (all_["items_sum_to_total"]["numerator"], all_["items_sum_to_total"]["denominator"]) == (
        1,
        4,
    )
    assert value(all_["parse_failed"]) == 0.25
    assert all_["seconds_per_receipt"] == {"count": 4, "mean": 25.0, "median": 25.0, "p90": 40.0}
    # Nothing is checked, so the checked-only variant has no receipt.
    assert all_["items_checked_only"]["receipts"] == 0
    assert value(all_["items_checked_only"]["main"]["f1_micro"]) is None


def test_intervals_bracket_the_value(inputs: dict[str, Path]) -> None:
    run_harness(inputs)
    total = result(inputs, "run-a")["segments"]["all"]["fields"]["total"]
    low, high = total["ci95"]
    assert 0.0 <= low <= total["value"] <= high <= 1.0


def test_segments(inputs: dict[str, Path]) -> None:
    run_harness(inputs)
    segments = result(inputs, "run-a")["segments"]
    assert segments["fiscal"]["receipts"] == 3
    assert segments["card_slip"]["receipts"] == 1
    assert segments["kind_unknown"]["receipts"] == 0
    assert segments["one_photo"]["receipts"] == 3
    assert segments["multi_photo"]["receipts"] == 1
    assert segments["crop_failed"] is None  # the run sent full photos
    # Card slips separately: no items on either side.
    assert segments["card_slip"]["items"]["receipts"] == 1
    assert value(segments["card_slip"]["items"]["main"]["f1_macro"]) == 1.0


def test_crop_failed_segment(inputs: dict[str, Path]) -> None:
    records = fx.standard_predictions()
    for record in records:
        record["images"] = ["crop"] * len(record["images"])
    records[1]["images"] = ["crop", "full"]
    fx.write_run(inputs["runs"], "run-crops", records, crops=True)
    run_harness(inputs)
    segment = result(inputs, "run-crops")["segments"]["crop_failed"]
    assert segment["receipts"] == 1


def test_prefill_rule_counts_what_it_leaves_out(inputs: dict[str, Path]) -> None:
    run_harness(inputs)
    counts = result(inputs, "run-a")["counts"]
    assert counts["excluded_prefilled_items"] == 1
    assert counts["excluded_prefilled_merchant"] == 1
    assert counts["excluded_prefilled_kind"] == 1


def test_prefill_rule_does_not_touch_another_model(inputs: dict[str, Path]) -> None:
    fx.write_run(inputs["runs"], "run-b", fx.standard_predictions(), model="vendor/model-b")
    run_harness(inputs)
    b = result(inputs, "run-b")
    assert b["counts"]["excluded_prefilled_items"] == 0
    items = b["segments"]["all"]["items"]
    # r2's record now counts: 1 more reference and 1 more matched item.
    assert (items["receipts"], items["reference_items"], items["predicted_items"]) == (3, 4, 3)


@pytest.mark.parametrize(
    ("prefilled_by", "expected"),
    [
        ("mlx-community/Model-A", True),
        ("  MLX-COMMUNITY/model-a ", True),
        ("Model-A", True),
        ("mlx:mlx-community/Model-A", True),
        ("other/Model-A:free", True),
        ("0123456789abcdef", True),  # the run's model_version (a dated slug for a hosted run)
        ("mlx-community/Model-B", False),
        ("", False),
        (None, False),
    ],
)
def test_same_model(prefilled_by: str | None, expected: bool, tmp_path: Path) -> None:
    folder = fx.write_run(tmp_path, "run", [], model="mlx-community/Model-A")
    assert same_model(prefilled_by, read_run(folder)) is expected


def test_prefill_applies_whatever_the_source(inputs: dict[str, Path]) -> None:
    lines = fx.standard_truth()
    lines[0]["prefilled_by"] = "mlx-community/Model-A"  # not allowed by the app, but not trusted
    fx.write_truth(inputs["truth"], lines)
    run_harness(inputs)
    assert result(inputs, "run-a")["counts"]["excluded_prefilled_items"] == 2


# --- ground truth ----------------------------------------------------------------------------


def truth_for(tmp_path: Path, lines: list[dict[str, Any]]) -> GroundTruth:
    receipts = read_receipt_set(fx.write_receipt_set(tmp_path / "r"))
    records, _ = read_ground_truth(fx.write_truth(tmp_path / "t", lines))
    return GroundTruth(records, receipts)


def a_run(tmp_path: Path, model: str = "vendor/other") -> Any:
    return read_run(fx.write_run(tmp_path / "runs", "x", [], model=model))


def test_dps_xml_comes_before_manual(tmp_path: Path) -> None:
    lines = [
        fx.truth_line("rcpt_000001", "manual", fx.document("fiscal", [fx.item("M", "1.00")])),
        fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", [fx.item("D", "1.00")])),
    ]
    truth = truth_for(tmp_path, lines)
    chosen = truth.items("rcpt_000001", a_run(tmp_path))
    assert chosen.record is not None and chosen.record.source == "dps_xml"


def test_manual_is_used_when_the_file_has_no_items(tmp_path: Path) -> None:
    lines = [
        fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", []), items_known=False),
        fx.truth_line("rcpt_000001", "manual", fx.document("fiscal", [fx.item("M", "1.00")])),
    ]
    chosen = truth_for(tmp_path, lines).items("rcpt_000001", a_run(tmp_path))
    assert chosen.record is not None and chosen.record.source == "manual"


def test_exclusions(tmp_path: Path) -> None:
    doc = fx.document("fiscal", [fx.item("A", "1.00")])
    lines = [
        fx.truth_line("rcpt_000001", "dps_xml", doc, qr_check="disagrees"),
        fx.truth_line("rcpt_000002", "dps_xml", doc, checked="differs"),
        fx.truth_line("rcpt_000003", "manual", doc, qr_check="disagrees"),  # kept
        fx.truth_line("rcpt_000004", "dps_xml", doc, checked="matches"),
        fx.truth_line("rcpt_000009", "dps_xml", doc),  # not in the receipt set
    ]
    truth = truth_for(tmp_path, lines)
    run = a_run(tmp_path)
    assert truth.items("rcpt_000001", run).record is None
    assert truth.items("rcpt_000002", run).record is None
    assert truth.items("rcpt_000003", run).record is not None
    assert truth.items("rcpt_000004", run, checked_only=True).record is not None
    assert truth.items("rcpt_000003", run, checked_only=True).record is None
    assert truth.summary() == {
        "source_dps_xml": 3,
        "source_manual": 1,
        "excluded_qr_disagrees": 1,
        "excluded_checked_differs": 1,
        "unchecked": 1,
        "not_in_receipt_set": 1,
    }


def test_a_checked_record_feeds_the_checked_only_numbers(inputs: dict[str, Path]) -> None:
    lines = fx.standard_truth()
    lines[0]["checked_at"] = "2026-11-02T10:00:00+02:00"
    lines[0]["check_outcome"] = "matches"
    fx.write_truth(inputs["truth"], lines)
    run_harness(inputs)
    checked = result(inputs, "run-a")["segments"]["all"]["items_checked_only"]
    assert checked["receipts"] == 1
    assert value(checked["main"]["f1_micro"]) == pytest.approx(0.8)


def test_without_ground_truth_the_item_metrics_are_empty(inputs: dict[str, Path]) -> None:
    (inputs["truth"] / "ground_truth.jsonl").unlink()
    _, console = run_harness(inputs)
    all_ = result(inputs, "run-a")["segments"]["all"]
    assert all_["items"]["receipts"] == 0
    assert value(all_["items"]["main"]["f1_micro"]) is None
    assert value(all_["fields"]["total"]) == pytest.approx(2 / 3)
    assert "no ground_truth.jsonl" in console


def test_both_schema_versions_are_read(tmp_path: Path) -> None:
    lines = [
        fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", [fx.item("A", "1.00")])),
        fx.truth_line(
            "rcpt_000002",
            "manual",
            fx.document("fiscal", [fx.item("B", "1.00", "groceries/groceries", v2=True)], v2=True),
            schema_version=2,
            categories_prefilled_by="cat-model",
            unknown_future_key=True,
        ),
        fx.truth_line(
            "rcpt_000003",
            "manual",
            fx.document("fiscal", [fx.item("C", "1.00", None, v2=True)], v2=True),
            schema_version=2,
            categories_known=False,
        ),
    ]
    records, counts = read_ground_truth(fx.write_truth(tmp_path, lines))
    assert counts == {"lines": 3, "without_ingest_id": 0}
    by_id = {record.ingest_id: record for record in records}
    assert not by_id["rcpt_000001"].categories_known
    assert by_id["rcpt_000002"].categories_known
    assert by_id["rcpt_000002"].categories_prefilled_by == "cat-model"
    assert not by_id["rcpt_000003"].categories_known


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"source": "typed"}, "unknown source"),
        ({"schema_version": None}, "schema_version"),
        ({"document": "text"}, "document"),
    ],
)
def test_bad_ground_truth_lines(tmp_path: Path, change: dict[str, Any], message: str) -> None:
    line = fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", []))
    line.update(change)
    with pytest.raises(UsageError, match=message):
        read_ground_truth(fx.write_truth(tmp_path, [line]))


def test_lines_without_an_ingest_id_are_counted(tmp_path: Path) -> None:
    line = fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", []))
    line["ingest_id"] = None
    records, counts = read_ground_truth(fx.write_truth(tmp_path, [line]))
    assert records == [] and counts["without_ingest_id"] == 1


def test_a_repeated_record_is_refused(tmp_path: Path) -> None:
    line = fx.truth_line("rcpt_000001", "dps_xml", fx.document("fiscal", []))
    with pytest.raises(UsageError, match="repeats"):
        read_ground_truth(fx.write_truth(tmp_path, [line, line]))


def test_no_ground_truth_folder(tmp_path: Path) -> None:
    assert read_ground_truth(None) == ([], {"lines": 0, "without_ingest_id": 0})


# --- runs --------------------------------------------------------------------------------------


def test_runs_with_and_without_task(tmp_path: Path) -> None:
    fx.write_run(tmp_path, "old", [])
    fx.write_run(tmp_path, "new", [], task="ocr")
    fx.write_run(tmp_path / "nested", "cats", [], task="item_categories")
    (tmp_path / "not-a-run").mkdir()
    runs = discover_runs(tmp_path)
    assert [(run.run_id, run.task) for run in runs] == [
        ("cats", "item_categories"),
        ("new", "ocr"),
        ("old", "ocr"),
    ]


@pytest.mark.parametrize(
    ("meta", "records", "message"),
    [
        ({"task": "speech"}, [], "unknown task"),
        ({}, [{"status": "ok"}], "no receipt_id"),
        ({}, [{"receipt_id": "r", "status": "great"}], "unknown status"),
        ({}, [{"receipt_id": "r", "status": "ok", "receipt": []}], "not an object"),
        (
            {},
            [{"receipt_id": "r", "status": "ok"}, {"receipt_id": "r", "status": "ok"}],
            "repeats",
        ),
    ],
)
def test_bad_runs(tmp_path: Path, meta: dict, records: list, message: str) -> None:
    fx.write_run(tmp_path, "bad", records, **meta)
    with pytest.raises(UsageError, match=message):
        discover_runs(tmp_path)


def test_two_runs_with_one_id(tmp_path: Path) -> None:
    fx.write_run(tmp_path / "a", "same", [])
    fx.write_run(tmp_path / "b", "same", [])
    with pytest.raises(UsageError, match="two run folders"):
        discover_runs(tmp_path)


def test_unreadable_run_json(tmp_path: Path) -> None:
    folder = fx.write_run(tmp_path, "broken", [])
    (folder / "run.json").write_text("{", encoding="utf-8")
    with pytest.raises(UsageError, match="not readable"):
        discover_runs(tmp_path)
    (folder / "run.json").write_text("[]", encoding="utf-8")
    with pytest.raises(UsageError, match="not a JSON object"):
        discover_runs(tmp_path)


def test_missing_inputs(tmp_path: Path) -> None:
    with pytest.raises(UsageError, match=r"receipts\.jsonl"):
        read_receipt_set(tmp_path)
    with pytest.raises(UsageError, match="does not exist"):
        discover_runs(tmp_path / "nowhere")


def test_skipped_and_unknown_receipts_are_counted(inputs: dict[str, Path]) -> None:
    records = fx.standard_predictions()
    records.append(fx.prediction("rcpt_000099"))
    records.append({**fx.prediction("rcpt_000005"), "status": "skipped", "receipt": None})
    fx.write_run(inputs["runs"], "run-a", records)
    run_harness(inputs)
    counts = result(inputs, "run-a")["counts"]
    assert counts["skipped"] == 1
    assert counts["not_in_receipt_set"] == 1
    assert result(inputs, "run-a")["segments"]["all"]["receipts"] == 4


def test_a_hosted_run_reports_its_cost(inputs: dict[str, Path]) -> None:
    records = fx.standard_predictions()
    for number, record in enumerate(records):
        record["diagnostics"] = {"model_calls": 1, "cost_usd": f"0.00{number + 1}"}
    fx.write_run(inputs["runs"], "run-h", records, backend="openrouter", model="vendor/model-h")
    run_harness(inputs)
    cost = result(inputs, "run-h")["cost_usd"]
    assert cost["total_usd"] == "0.010"
    assert cost["per_receipt_usd"] == "0.002500"
    assert cost["per_1000_receipts_usd"] == "2.5000"
    table = (inputs["out"] / "tables" / "local_vs_hosted.md").read_text(encoding="utf-8")
    assert "2.5000" in table


# --- comparisons -------------------------------------------------------------------------------


def test_automatic_comparisons(inputs: dict[str, Path]) -> None:
    worse = fx.standard_predictions()
    worse[0]["receipt"]["total"] = "1.00"
    worse[1]["receipt"]["total"] = "1.00"
    fx.write_run(inputs["runs"], "run-crops", worse, crops=True)
    fx.write_run(inputs["runs"], "run-model", fx.standard_predictions(), model="vendor/model-b")
    fx.write_run(
        inputs["runs"], "run-hosted", fx.standard_predictions(), backend="openrouter", model="v/h"
    )
    fx.write_run(inputs["runs"], "run-prompt", fx.standard_predictions(), prompt_version="other")
    index, _ = run_harness(inputs)
    assert index is not None
    pairs = {(c["a"], c["b"], c["dimension"]) for c in index["comparisons"]}
    assert ("run-crops", "run-a", "crops") in pairs
    assert ("run-a", "run-model", "model") in pairs
    assert ("run-a", "run-hosted", "backend") in pairs
    assert not any("run-prompt" in pair for pair in pairs)  # another prompt: not comparable
    crops = json.loads(
        (inputs["out"] / "comparisons" / "run-crops__vs__run-a.json").read_text(encoding="utf-8")
    )
    total = crops["differences"]["fields.total"]
    assert total["receipts"] == 3
    assert total["difference"] == pytest.approx(-2 / 3)
    assert total["ci95"][0] <= total["difference"] <= total["ci95"][1]
    assert crops["mcnemar"]["fields.total"]["a_only_correct"] == 0
    assert crops["mcnemar"]["fields.total"]["b_only_correct"] == 2
    assert crops["mcnemar"]["fields.total"]["exact_p_value"] == pytest.approx(0.5)


def test_declared_comparisons(inputs: dict[str, Path]) -> None:
    fx.write_run(inputs["runs"], "run-z", fx.standard_predictions(), prompt_version="other")
    (inputs["runs"] / "comparisons.txt").write_text("# A B\nrun-z run-a\n", encoding="utf-8")
    index, _ = run_harness(inputs, "--no-auto-compare")
    assert index is not None
    assert [(c["a"], c["b"], c["dimension"], c["declared"]) for c in index["comparisons"]] == [
        ("run-z", "run-a", "declared", True)
    ]


@pytest.mark.parametrize(
    ("pair", "message"),
    [
        (("run-a", "nope"), "unknown run"),
        (("run-a", "run-a"), "same run"),
        (("run-a", "cats"), "different tasks"),
    ],
)
def test_bad_declared_comparisons(inputs: dict[str, Path], pair: tuple, message: str) -> None:
    fx.write_run(inputs["runs"], "cats", [], task="item_categories")
    with pytest.raises(UsageError, match=message):
        run_harness(inputs, "--compare", *pair)


def test_a_comparison_file_needs_two_ids(inputs: dict[str, Path]) -> None:
    path = inputs["runs"] / "pairs.txt"
    path.write_text("run-a\n", encoding="utf-8")
    with pytest.raises(UsageError, match="two run ids"):
        run_harness(inputs, "--comparisons", str(path))
    with pytest.raises(UsageError, match="does not exist"):
        run_harness(inputs, "--comparisons", str(inputs["runs"] / "missing.txt"))


def test_runs_with_nothing_in_common(inputs: dict[str, Path]) -> None:
    fx.write_run(inputs["runs"], "run-crops", [fx.prediction("rcpt_000005")], crops=True)
    index, console = run_harness(inputs)
    assert index is not None and index["comparisons"] == []
    assert "nothing in common" in console


# --- item categories ---------------------------------------------------------------------------

G = "groceries/groceries"
H = "household-shopping/household-supplies"
C = "eating-out/cafes-bars-restaurants"


@pytest.fixture
def category_inputs(inputs: dict[str, Path]) -> dict[str, Path]:
    lines = [
        fx.truth_line(
            "rcpt_000001",
            "dps_xml",
            fx.document(
                "fiscal",
                [
                    fx.item("SentinelBread", "40.00", G, v2=True),
                    fx.item("Milk", "60.00", G, v2=True),
                    fx.item("Soap", "2.00", H, v2=True),
                    fx.item("Unknown", "1.00", None, v2=True),
                ],
                v2=True,
            ),
            schema_version=2,
        ),
        fx.truth_line(
            "rcpt_000002",
            "manual",
            fx.document("fiscal", [fx.item("Apple", "50.00", G, v2=True)], v2=True),
            schema_version=2,
            categories_prefilled_by="cat-model",
        ),
        fx.truth_line(
            "rcpt_000003",
            "manual",
            fx.document("card_slip", [], category_slug=C, v2=True),
            schema_version=2,
        ),
    ]
    fx.write_truth(inputs["truth"], lines)
    shutil.rmtree(inputs["runs"] / "run-a")
    fx.write_run(
        inputs["runs"],
        "cats",
        [
            fx.category_line("rcpt_000001", 1, [(G, 0.9)], source="memory"),
            fx.category_line("rcpt_000001", 2, [(H, 0.8), (G, 0.1)]),
            fx.category_line("rcpt_000001", 3, [(H, 0.7)]),
            fx.category_line("rcpt_000001", 9, [(H, 0.7)]),  # no such item
            fx.category_line("rcpt_000002", 1, [(G, 0.9)], ground_truth_source="manual"),
            fx.category_line("rcpt_000003", None, [(C, 0.6)], ground_truth_source="manual"),
        ],
        task="item_categories",
        model="cat-model",
        backend="local",
    )
    return inputs


def test_item_category_metrics_worked_by_hand(category_inputs: dict[str, Path]) -> None:
    run_harness(category_inputs)
    cats = result(category_inputs, "cats")
    assert cats["counts"] == {
        "receipts": 2,
        "receipts_not_in_receipt_set": 0,
        "receipts_excluded_prefilled": 1,
        "receipts_without_category_truth": 0,
        "unlabelled_items": 1,
        "unlabelled_card_slips": 0,
        "items_without_prediction": 0,
        "unmatched_lines": 1,
    }
    head = cats["headline"]
    # true G G H, predicted G H H: F1(G) = 2/3, F1(H) = 2/3.
    assert head["items"] == 3
    assert value(head["accuracy"]) == pytest.approx(2 / 3)
    assert value(head["top3_accuracy"]) == 1.0
    assert value(head["macro_f1"]) == pytest.approx(2 / 3)
    assert value(head["weighted_f1"]) == pytest.approx(2 / 3)
    assert {row["category_slug"]: row["f1"] for row in cats["per_class"]} == {
        G: pytest.approx(2 / 3),
        H: pytest.approx(2 / 3),
    }
    assert cats["confusion"] == {G: {G: 1, H: 1}, H: {H: 1}}
    # Confidences 0.9 (right), 0.8 (wrong), 0.7 (right): only the first is >= 95% precise.
    assert cats["auto_accept"]["coverage"] == pytest.approx(1 / 3)
    assert cats["auto_accept"]["min_confidence"] == 0.9
    assert cats["by_source"]["memory"]["items"] == 1
    assert value(cats["by_source"]["memory"]["accuracy"]) == 1.0
    assert value(cats["by_source"]["model"]["accuracy"]) == 0.5
    assert cats["card_slips"] == {"receipts": 1, "accuracy": 1.0, "top3_accuracy": 1.0}
    assert cats["seconds_per_item"]["count"] == 4
    assert cats["cost_usd"] is None


def test_category_prefill_only_for_its_model(category_inputs: dict[str, Path]) -> None:
    meta = json.loads((category_inputs["runs"] / "cats" / "run.json").read_text())
    meta["model_name"] = "another-model"
    (category_inputs["runs"] / "cats" / "run.json").write_text(json.dumps(meta))
    run_harness(category_inputs)
    cats = result(category_inputs, "cats")
    assert cats["counts"]["receipts_excluded_prefilled"] == 0
    assert cats["headline"]["items"] == 4


def test_a_missing_prediction_counts_as_wrong(category_inputs: dict[str, Path]) -> None:
    folder = category_inputs["runs"] / "cats"
    lines = [json.loads(line) for line in (folder / "predictions.jsonl").read_text().splitlines()]
    lines = [line for line in lines if line.get("position") != 3]
    lines[0]["candidates"][0]["category_slug"] = "Not A Slug"
    lines[0]["cost_usd"] = "0.0001"
    (folder / "predictions.jsonl").write_text("\n".join(json.dumps(line) for line in lines))
    run_harness(category_inputs)
    cats = result(category_inputs, "cats")
    assert cats["counts"]["items_without_prediction"] == 1
    assert value(cats["headline"]["accuracy"]) == 0.0
    assert cats["confusion"][H] == {"_none": 1}
    assert cats["confusion"][G]["_other"] == 1
    assert cats["cost_usd"]["items_with_cost"] == 1
    assert cats["cost_usd"]["complete"] is False


def test_category_comparisons(category_inputs: dict[str, Path]) -> None:
    fx.write_run(
        category_inputs["runs"],
        "cats-2",
        [
            fx.category_line("rcpt_000001", 1, [(G, 0.9)]),
            fx.category_line("rcpt_000001", 2, [(G, 0.9)]),
            fx.category_line("rcpt_000001", 3, [(H, 0.9)]),
        ],
        task="item_categories",
        model="cat-model-2",
        backend="local",
    )
    index, _ = run_harness(category_inputs)
    assert index is not None
    (comparison,) = index["comparisons"]
    assert comparison["dimension"] == "model"
    body = json.loads((category_inputs["out"] / comparison["file"]).read_text())
    assert body["items"] == 3
    assert body["differences"]["accuracy"]["difference"] == pytest.approx(
        body["differences"]["accuracy"]["a"] - body["differences"]["accuracy"]["b"]
    )
    test = body["mcnemar"]["top1"]
    assert test["a_only_correct"] + test["b_only_correct"] == 1
    tables = (category_inputs["out"] / "tables" / "item_category_comparisons.md").read_text()
    assert "cats-2" in tables


@pytest.mark.parametrize(
    ("line", "message"),
    [
        ({"position": 0}, "position"),
        ({"position": True}, "position"),
        ({"candidates": "x"}, "candidates"),
        ({"candidates": [{"score": 1}]}, "category_slug"),
        ({"candidates": [{"category_slug": G, "score": "high"}]}, "score"),
        ({"source": "guess"}, "unknown source"),
        ({"ground_truth_source": "paper"}, "ground_truth_source"),
        ({"receipt_id": None}, "receipt_id"),
    ],
)
def test_bad_category_lines(tmp_path: Path, line: dict, message: str) -> None:
    record = {**fx.category_line("rcpt_000001", 1, [(G, 0.5)]), **line}
    fx.write_run(tmp_path, "cats", [record], task="item_categories")
    with pytest.raises(UsageError, match=message):
        discover_runs(tmp_path)


# --- outputs -----------------------------------------------------------------------------------


def all_text(folder: Path) -> str:
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(folder.rglob("*")) if path.is_file()
    )


def test_the_results_hold_no_receipt_content(
    category_inputs: dict[str, Path], inputs: dict[str, Path]
) -> None:
    fx.write_run(inputs["runs"], "run-a", fx.standard_predictions())
    fx.write_truth(inputs["truth"], fx.standard_truth())
    run_harness(inputs)
    text = all_text(inputs["out"])
    for forbidden in (
        "Sentinel",
        "Milk",
        "Пакет",
        "Cafe",
        "rcpt_",
        "4321.17",
        "102.00",
        "2026-01-15",
        "/somewhere/private",
        str(inputs["receipts"]),
    ):
        assert forbidden not in text


def test_the_console_holds_no_receipt_content(inputs: dict[str, Path]) -> None:
    _, console = run_harness(inputs)
    for forbidden in ("Sentinel", "Milk", "rcpt_", "4321.17", "/somewhere/private"):
        assert forbidden not in console
    _, console = run_harness(inputs, "--check")
    assert "rcpt_" not in console and "Sentinel" not in console


def test_check_writes_nothing(inputs: dict[str, Path]) -> None:
    index, console = run_harness(inputs, "--check")
    assert index is None
    assert not inputs["out"].exists()
    assert "run-a: ocr, 4 lines, 4 scored, 3 with QR, 2 with item truth" in console
    assert "1 left out (pre-fill)" in console


def test_check_reports_category_runs(category_inputs: dict[str, Path]) -> None:
    _, console = run_harness(category_inputs, "--check")
    assert "cats: item_categories, 6 lines, 2 receipts with category truth" in console


def test_outputs_are_deterministic(inputs: dict[str, Path], tmp_path: Path) -> None:
    fx.write_run(inputs["runs"], "run-crops", fx.standard_predictions(), crops=True)
    run_harness(inputs)
    first = {p.relative_to(inputs["out"]): p.read_bytes() for p in inputs["out"].rglob("*.*")}
    second_out = tmp_path / "second"
    run_harness({**inputs, "out": second_out})
    second = {p.relative_to(second_out): p.read_bytes() for p in second_out.rglob("*.*")}
    assert first == second
    assert len(first) == 1 + 2 + 1 + 18  # index, two runs, one comparison, nine tables


def test_stale_files_are_removed(inputs: dict[str, Path]) -> None:
    fx.write_run(inputs["runs"], "run-old", fx.standard_predictions(), model="v/old")
    run_harness(inputs)
    assert (inputs["out"] / "runs" / "run-old.json").exists()
    shutil.rmtree(inputs["runs"] / "run-old")
    (inputs["out"] / "README.md").write_text("kept", encoding="utf-8")
    _, console = run_harness(inputs)
    assert not (inputs["out"] / "runs" / "run-old.json").exists()
    assert not list((inputs["out"] / "comparisons").glob("*.json"))
    assert (inputs["out"] / "README.md").read_text() == "kept"
    assert "removed 2 stale file(s)" in console


def test_tables(inputs: dict[str, Path]) -> None:
    fx.write_run(inputs["runs"], "run-crops", fx.standard_predictions(), crops=True)
    run_harness(inputs)
    tables = inputs["out"] / "tables"
    fields = (tables / "ocr_fields.md").read_text(encoding="utf-8")
    assert fields.startswith("# OCR fields by run\n")
    assert "| run-a | mlx-community/Model-A | mlx | full | 4 | 3 | 66.7 [" in fields
    items_csv = (tables / "ocr_items.csv").read_text(encoding="utf-8").splitlines()
    assert items_csv[0].startswith("Run,Model,Photos,Receipts,Left out (pre-fill),Precision %,")
    assert "Precision % low" in items_csv[0]
    row = items_csv[2] if items_csv[1].startswith("run-crops") else items_csv[1]
    assert row.startswith("run-a,mlx-community/Model-A,full,2,1,100.0,100.0,100.0,66.7,")
    cropped = (tables / "full_vs_cropped.md").read_text(encoding="utf-8")
    assert "| crops | run-crops | run-a | 4 | 0.0 [0.0, 0.0]" in cropped


def test_diagnostics_go_outside_git(inputs: dict[str, Path], tmp_path: Path) -> None:
    diagnostics = tmp_path / "diag"
    run_harness(inputs, "--diagnostics", str(diagnostics))
    detail = json.loads((diagnostics / "run-a.json").read_text(encoding="utf-8"))
    assert detail[0]["receipt_id"] == "rcpt_000001"
    assert oct((diagnostics / "run-a.json").stat().st_mode & 0o777) == "0o600"
    with pytest.raises(UsageError, match="git repository"):
        run_harness(inputs, "--diagnostics", str(REPOSITORY / "tmp" / "diag"))


def test_category_diagnostics(category_inputs: dict[str, Path], tmp_path: Path) -> None:
    run_harness(category_inputs, "--diagnostics", str(tmp_path / "diag"))
    detail = json.loads((tmp_path / "diag" / "cats.json").read_text(encoding="utf-8"))
    assert {row["label"] for row in detail} == {G, H, C}


def test_main_exit_codes(inputs: dict[str, Path], capsys: pytest.CaptureFixture[str]) -> None:
    argv = ["--receipts", str(inputs["receipts"]), "--runs", str(inputs["runs"])]
    assert harness.main([*argv, "--ground-truth", str(inputs["truth"]), "--check"]) == 0
    assert harness.main(["--receipts", str(inputs["runs"]), "--runs", str(inputs["runs"])]) == 2
    assert "receipts.jsonl" in capsys.readouterr().err
    with pytest.raises(SystemExit):
        harness.parse_args(["--resamples", "0"])


def test_main_reports_a_shape_error(
    inputs: dict[str, Path], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(harness, "run_section", lambda run: {"model_name": "Хліб"})
    argv = ["--receipts", str(inputs["receipts"]), "--runs", str(inputs["runs"])]
    assert harness.main([*argv, "--out", str(inputs["out"])]) == 1
    error = capsys.readouterr().err
    assert "results:" in error and "Хліб" not in error


# --- the writer's whitelist ------------------------------------------------------------------


@pytest.fixture
def scored(inputs: dict[str, Path]) -> tuple[dict[str, Any], set[str]]:
    run_harness(inputs)
    payload = result(inputs, "run-a")
    run = read_run(inputs["runs"] / "run-a")
    return payload, harness.run_values([run])


def test_the_writer_accepts_the_harness_output(scored: tuple[dict, set], tmp_path: Path) -> None:
    payload, values = scored
    check(payload, OCR_RUN_RESULT, Context(frozenset(values)))


@pytest.mark.parametrize(
    "smuggle",
    [
        lambda p: p["run"].update(model_name="SentinelBread"),
        lambda p: p["run"].update(started_at="SentinelBread"),
        lambda p: p["segments"]["all"].update(item_name="SentinelBread"),
        lambda p: p["segments"]["all"]["fields"]["total"].update(value="SentinelBread"),
        lambda p: p["segments"]["all"]["fields"]["total"].update(ci95=[0.1, 0.2, 0.3]),
        lambda p: p["segments"]["all"]["kind"]["confusion"].update(SentinelBread={}),
        lambda p: p["counts"].update({"Sentinel Bread": 1}),
        lambda p: p["counts"].update(receipts=["rcpt_000001"]),
        lambda p: p["segments"]["all"].update(receipts=[4, 5, 6]),
        lambda p: p["segments"]["all"]["fields"]["total"].update(value=float("nan")),
        lambda p: p["segments"]["all"]["fields"]["total"].update(value=True),
        lambda p: p["run"].update(git_sha="/Users/someone/receipts"),
        lambda p: p["run"].update(stopped="Bought SentinelBread"),
        lambda p: p.update(segments="SentinelBread"),
        lambda p: p["cost_usd"] is None and p.update(cost_usd={"total_usd": "1"}),
    ],
)
def test_the_writer_refuses_anything_else(
    scored: tuple[dict, set], tmp_path: Path, smuggle: Any
) -> None:
    payload, values = scored
    smuggle(payload)
    writer = ResultsWriter(tmp_path / "gate", values)
    with pytest.raises(ResultsShapeError) as error:
        writer.write_json("runs/run-a.json", payload, OCR_RUN_RESULT)
    assert "SentinelBread" not in str(error.value)
    assert not (tmp_path / "gate" / "runs" / "run-a.json").exists()


def test_the_writer_refuses_bad_file_names(scored: tuple[dict, set], tmp_path: Path) -> None:
    payload, values = scored
    writer = ResultsWriter(tmp_path / "gate", values)
    for name in ("../escape.json", "runs/../../x.json", "notes.txt", "runs/rcpt 1.json"):
        with pytest.raises(ResultsShapeError):
            writer.write_json(name, payload, OCR_RUN_RESULT)


def test_table_cells_are_gated(tmp_path: Path) -> None:
    ctx = Context(frozenset({"vendor/model"}))
    for cell in (None, 3, 0.5, "66.7 [50.0, 80.0]", "n/a", "<0.001", "vendor/model", G, "_none"):
        check_cell(cell, ctx)
    check_cell(Est(0.5, 0.1, 0.9), ctx)
    for cell in ("SentinelBread", "Хліб", "vendor/other model", Est(float("nan"), None, None)):
        with pytest.raises(ResultsShapeError):
            check_cell(cell, ctx)
    writer = ResultsWriter(tmp_path, ["vendor/model"])
    with pytest.raises(ResultsShapeError):
        writer.write_table("t", "Title", ["A"], [["Хліб"]], "")
    with pytest.raises(ResultsShapeError):
        writer.write_table("t", "Title", ["Хліб"], [[1]], "")
    with pytest.raises(ResultsShapeError):
        writer.write_table("t", "Title", ["A"], [[1, 2]], "")
    with pytest.raises(ResultsShapeError):
        writer.write_table("T!", "Title", ["A"], [[1]], "")
    with pytest.raises(ResultsShapeError):
        writer.write_table("t", "Title", ["A"], [[1]], "Bought Хліб")


def test_estimates_never_print_a_negative_zero() -> None:
    assert Est(-0.00001, -0.04, 0.0).text() == "0.0 [0.0, 0.0]"
    assert Est(None, None, None).text() == "n/a"
    assert Est(1.0, None, None).parts() == ["1.0", "", ""]


# --- make eval ---------------------------------------------------------------------------------


@pytest.mark.skipif(
    shutil.which("make") is None or shutil.which("uv") is None, reason="needs make and uv"
)
def test_make_eval_end_to_end(inputs: dict[str, Path], tmp_path: Path) -> None:
    fx.write_run(inputs["runs"], "run-crops", fx.standard_predictions(), crops=True)
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("VIRTUAL_ENV", "UV_"))
    }
    env.update(UV_OFFLINE="1", UV_FROZEN="1", UV_NO_SYNC="1")
    variables = [
        f"RECEIPTS_DIR={inputs['receipts']}",
        f"RUNS_DIR={inputs['runs']}",
        f"GROUND_TRUTH_DIR={inputs['truth']}",
        f"RESULTS_DIR={inputs['out']}",
        "EVAL_ARGS=--resamples 50",
    ]
    checked = subprocess.run(
        ["make", "-s", "-C", str(REPOSITORY), "eval-check", *variables],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
    )
    assert checked.returncode == 0, checked.stderr
    assert "run-a: ocr" in checked.stdout
    assert not inputs["out"].exists()
    done = subprocess.run(
        ["make", "-s", "-C", str(REPOSITORY), "eval", *variables],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
    )
    assert done.returncode == 0, done.stderr
    index = json.loads((inputs["out"] / "index.json").read_text(encoding="utf-8"))
    assert [run["run_id"] for run in index["runs"]] == ["run-a", "run-crops"]
    assert (inputs["out"] / "tables" / "full_vs_cropped.csv").is_file()
    assert "rcpt_" not in done.stdout


def test_scoring_directly(inputs: dict[str, Path]) -> None:
    receipts = read_receipt_set(inputs["receipts"])
    records, _ = read_ground_truth(inputs["truth"])
    run = read_run(inputs["runs"] / "run-a")
    scores = score_run(run, receipts, GroundTruth(records, receipts), seed=1, resamples=10)
    assert len(scores.outcomes) == 4
