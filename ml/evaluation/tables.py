"""Tables generated from the results JSON, one per question, in Markdown and CSV.

Rows are in a fixed order (runs by model name, backend, photos, run id; comparisons by dimension
and run ids) and numbers have fixed rounding: shares as percentages with one decimal, differences
in percentage points with one decimal, CER as a percentage with one decimal, F1 and accuracy of
categories as percentages with one decimal, seconds with two decimals, dollars as `run.json` and
the harness rounded them, p-values with three decimals (`<0.001` below that). The same results give
byte-identical tables.
"""

from typing import Any

from evaluation.results import Est, ResultsWriter

PERCENT = 100.0


def _pct(metric: dict[str, Any] | None) -> Est:
    if not metric or metric.get("value") is None:
        return Est(None, None, None)
    ci = metric.get("ci95") or [None, None]
    return Est(
        metric["value"] * PERCENT,
        None if ci[0] is None else ci[0] * PERCENT,
        None if ci[1] is None else ci[1] * PERCENT,
    )


def _diff(entry: dict[str, Any] | None) -> Est:
    if not entry or entry.get("difference") is None:
        return Est(None, None, None)
    ci = entry.get("ci95") or [None, None]
    return Est(
        entry["difference"] * PERCENT,
        None if ci[0] is None else ci[0] * PERCENT,
        None if ci[1] is None else ci[1] * PERCENT,
    )


def _seconds(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def _p(test: dict[str, Any] | None) -> str:
    if not test or not test.get("receipts", test.get("items")):
        return "n/a"
    value = test["exact_p_value"]
    return "<0.001" if value < 0.001 else f"{value:.3f}"


def _photos(run: dict[str, Any]) -> str:
    return "crops" if run["crops"] else "full"


def _run_order(result: dict[str, Any]) -> tuple[Any, ...]:
    run = result["run"]
    return (run["model_name"], run["backend"], run["crops"], run["run_id"])


NOTES = {
    "ocr_fields": (
        "Share of exact matches in percent with a 95% bootstrap interval over receipts. "
        "Date, time, total and the two numbers against the receipt's QR code; merchant "
        "(normalised) and kind against the ground truth (kind falls back to fiscal for a "
        "receipt with a tax QR code). A failed receipt counts as wrong."
    ),
    "ocr_fields_by_segment": (
        "Per segment: total and date against the QR code, item F1 (micro, main matching) "
        "against the ground truth; percent with a 95% bootstrap interval over receipts."
    ),
    "ocr_items": (
        "Items against the ground truth, one-to-one matching (Hungarian method): main = "
        "name and amount score >= 0.8, strict = name similarity >= 0.6 and exact amount, "
        "lenient = name similarity >= 0.6. Micro over items, macro = mean per receipt. CER: "
        "character error rate of the names of matched items. Percent with 95% intervals. "
        "Receipts whose ground truth was pre-filled by the run's model are left out."
    ),
    "local_vs_hosted": (
        "Accuracy in percent with 95% intervals; seconds per receipt over answered receipts; "
        "dollars as reported by the hosted service (n/a for a local backend)."
    ),
    "full_vs_cropped": (
        "Cropped run minus full-photo run, in percentage points, on the receipts both runs "
        "cover, with a paired 95% bootstrap interval; p = McNemar's exact test on "
        "per-receipt correctness of the total."
    ),
    "ocr_comparisons": (
        "Run A minus run B, in percentage points, on the receipts both runs cover, with a "
        "paired 95% bootstrap interval; p = McNemar's exact test on per-receipt correctness "
        "of the total."
    ),
    "item_categories": (
        "Item categories against the ground truth; percent with 95% intervals from resampling "
        "receipts. Card slips are scored apart (receipt-level category). Items whose "
        "categories were pre-filled by the run's model (or, for a combined run, by any model it "
        "combines) are left out. ECE and Brier: see the calibration table. Scores calibrated: "
        "what the run says about its scores (n/a when it does not say)."
    ),
    "item_categories_by_source": (
        "The same metrics split by the source of each prediction (memory, model, decision, "
        "combined, or none for an item without a prediction); percent with 95% intervals from "
        "resampling receipts."
    ),
    "calibration": (
        "Reliability table: the top category's score in ten equal-width bins over 0 to 1 (the "
        "last bin includes 1), with the mean score and the share correct per bin. ECE in the "
        "runs table is the bins' gaps weighted by their share of items; Brier is the mean of "
        "the squared difference of score and correctness (1 or 0) for the top category. "
        "Items without a score are left out."
    ),
    "auto_accept": (
        "Precision (percent) of the top category when only the most confident items are "
        "kept, at each coverage; the last columns give the largest coverage at which the "
        "precision stays at or above 95%, and the confidence threshold that reaches it."
    ),
    "item_category_comparisons": (
        "Run A minus run B in percentage points on the items both runs scored, 95% interval "
        "from resampling receipts; p = McNemar's exact test on per-item top-1 correctness."
    ),
}


def ocr_fields(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Model",
        "Backend",
        "Photos",
        "Receipts",
        "With QR",
        "Date %",
        "Time %",
        "Total %",
        "Register no. %",
        "Receipt no. %",
        "Merchant %",
        "Kind %",
        "Parse failures %",
    ]
    rows = []
    for result in sorted(results, key=_run_order):
        run, seg = result["run"], result["segments"]["all"]
        fields = seg["fields"]
        rows.append(
            [
                run["run_id"],
                run["model_name"],
                run["backend"],
                _photos(run),
                seg["receipts"],
                int(fields["total"]["denominator"]),
                _pct(fields["date"]),
                _pct(fields["time"]),
                _pct(fields["total"]),
                _pct(fields["fiscal_number"]),
                _pct(fields["receipt_number"]),
                _pct(seg["merchant"]),
                _pct(seg["kind"]["accuracy"]),
                _pct(seg["parse_failed"]),
            ]
        )
    return headers, rows


SEGMENT_ROWS = ("fiscal", "card_slip", "kind_unknown", "one_photo", "multi_photo", "crop_failed")


def ocr_fields_by_segment(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = ["Run", "Model", "Photos", "Segment", "Receipts", "Total %", "Date %", "Item F1 %"]
    rows = []
    for result in sorted(results, key=_run_order):
        run = result["run"]
        for segment in SEGMENT_ROWS:
            seg = result["segments"].get(segment)
            if not seg or not seg["receipts"]:
                continue
            rows.append(
                [
                    run["run_id"],
                    run["model_name"],
                    _photos(run),
                    segment,
                    seg["receipts"],
                    _pct(seg["fields"]["total"]),
                    _pct(seg["fields"]["date"]),
                    _pct(seg["items"]["main"]["f1_micro"]),
                ]
            )
    return headers, rows


def ocr_items(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Model",
        "Photos",
        "Receipts",
        "Left out (pre-fill)",
        "Precision %",
        "Recall %",
        "F1 micro %",
        "F1 macro %",
        "F1 strict %",
        "F1 lenient %",
        "CER %",
        "CER plain %",
        "Items sum to total %",
        "F1 micro, checked only %",
    ]
    rows = []
    for result in sorted(results, key=_run_order):
        run, seg = result["run"], result["segments"]["all"]
        items = seg["items"]
        rows.append(
            [
                run["run_id"],
                run["model_name"],
                _photos(run),
                items["receipts"],
                result["counts"].get("excluded_prefilled_items", 0),
                _pct(items["main"]["precision"]),
                _pct(items["main"]["recall"]),
                _pct(items["main"]["f1_micro"]),
                _pct(items["main"]["f1_macro"]),
                _pct(items["strict"]["f1_micro"]),
                _pct(items["lenient"]["f1_micro"]),
                _pct(items["cer_normalised"]),
                _pct(items["cer_plain"]),
                _pct(seg["items_sum_to_total"]),
                _pct(seg["items_checked_only"]["main"]["f1_micro"]),
            ]
        )
    return headers, rows


def local_vs_hosted(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Backend",
        "Model",
        "Photos",
        "Receipts",
        "Total %",
        "Item F1 %",
        "Seconds mean",
        "Seconds median",
        "Seconds p90",
        "$ per receipt",
        "$ per 1,000",
    ]
    rows = []
    for result in sorted(results, key=lambda r: (r["run"]["backend"], *_run_order(r))):
        run, seg = result["run"], result["segments"]["all"]
        timing = seg["seconds_per_receipt"] or {}
        cost = result.get("cost_usd") or {}
        rows.append(
            [
                run["run_id"],
                run["backend"],
                run["model_name"],
                _photos(run),
                seg["receipts"],
                _pct(seg["fields"]["total"]),
                _pct(seg["items"]["main"]["f1_micro"]),
                _seconds(timing.get("mean")),
                _seconds(timing.get("median")),
                _seconds(timing.get("p90")),
                cost.get("per_receipt_usd") or "n/a",
                cost.get("per_1000_receipts_usd") or "n/a",
            ]
        )
    return headers, rows


def _comparison_rows(comparisons: list[dict[str, Any]]) -> list[list[Any]]:
    rows = []
    for comparison in sorted(comparisons, key=lambda c: (c["dimension"], c["a"], c["b"])):
        differences = comparison["differences"]
        rows.append(
            [
                comparison["dimension"],
                comparison["a"],
                comparison["b"],
                comparison["receipts"],
                _diff(differences.get("fields.total")),
                _diff(differences.get("fields.date")),
                _diff(differences.get("fields.receipt_number")),
                _diff(differences.get("items.main.f1_micro")),
                _diff(differences.get("parse_failed")),
                _p(comparison["mcnemar"].get("fields.total")),
            ]
        )
    return rows


COMPARISON_HEADERS = [
    "Dimension",
    "Run A",
    "Run B",
    "Receipts",
    "Total pp",
    "Date pp",
    "Receipt no. pp",
    "Item F1 pp",
    "Parse failures pp",
    "p (total)",
]


def item_categories(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Model",
        "Backend",
        "Items",
        "Receipts",
        "Left out (pre-fill)",
        "Macro F1 %",
        "Weighted F1 %",
        "Accuracy %",
        "Top-3 %",
        "ECE %",
        "Brier",
        "Scores calibrated",
        "Card slips",
        "Card slip accuracy %",
        "Seconds per item",
        "$ per 1,000 items",
    ]
    rows = []
    for result in sorted(results, key=_run_order):
        run, head, counts = result["run"], result["headline"], result["counts"]
        calib = result["calibration"]
        slips = result["card_slips"]
        timing = result["seconds_per_item"] or {}
        cost = result.get("cost_usd") or {}
        rows.append(
            [
                run["run_id"],
                run["model_name"],
                run["backend"],
                head["items"],
                counts.get("receipts", 0),
                counts.get("receipts_excluded_prefilled", 0),
                _pct(head["macro_f1"]),
                _pct(head["weighted_f1"]),
                _pct(head["accuracy"]),
                _pct(head["top3_accuracy"]),
                _pct(calib["ece"]),
                _brier(calib["brier"]),
                _yes_no(calib["scores_calibrated"]),
                slips["receipts"],
                _pct({"value": slips["accuracy"]}),
                _seconds(timing.get("mean")),
                cost.get("per_1000_items_usd") or "n/a",
            ]
        )
    return headers, rows


def _brier(estimate: dict[str, Any]) -> Est:
    if estimate.get("value") is None:
        return Est(None, None, None)
    ci = estimate.get("ci95") or [None, None]
    return Est(estimate["value"], ci[0], ci[1], places=3)


def _yes_no(value: bool | None) -> str:
    return "n/a" if value is None else ("yes" if value else "no")


def item_categories_by_source(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Model",
        "Source",
        "Items",
        "Macro F1 %",
        "Accuracy %",
        "Top-3 %",
        "ECE %",
        "Brier",
    ]
    rows = []
    for result in sorted(results, key=_run_order):
        run = result["run"]
        for source, block in sorted(result["by_source"].items()):
            rows.append(
                [
                    run["run_id"],
                    run["model_name"],
                    source,
                    block["items"],
                    _pct(block["macro_f1"]),
                    _pct(block["accuracy"]),
                    _pct(block["top3_accuracy"]),
                    _pct(block["calibration"]["ece"]),
                    _brier(block["calibration"]["brier"]),
                ]
            )
    return headers, rows


def calibration(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = ["Run", "Model", "Score from", "Score to", "Items", "Mean score %", "Correct %"]
    rows = []
    for result in sorted(results, key=_run_order):
        run = result["run"]
        for bin_ in result["calibration"]["bins"]:
            rows.append(
                [
                    run["run_id"],
                    run["model_name"],
                    f"{bin_['low']:.1f}",
                    f"{bin_['high']:.1f}",
                    bin_["rows"],
                    _pct({"value": bin_["mean_score"]}),
                    _pct({"value": bin_["share_correct"]}),
                ]
            )
    return headers, rows


COVERAGE_LEVELS = (0.1, 0.25, 0.5, 0.75, 0.9, 1.0)


def auto_accept(results: list[dict[str, Any]]) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Run",
        "Model",
        "Items",
        *(f"P at {int(level * 100)}% %" for level in COVERAGE_LEVELS),
        "Coverage at P >= 95% %",
        "Min confidence",
    ]
    rows = []
    for result in sorted(results, key=_run_order):
        run = result["run"]
        coverage = result.get("coverage") or {}
        at = {
            round(entry["target_coverage"], 4): entry for entry in coverage.get("at_coverage", [])
        }
        accept = result["auto_accept"]
        rows.append(
            [
                run["run_id"],
                run["model_name"],
                result["headline"]["items"],
                *(
                    _pct({"value": (at.get(level) or {}).get("precision")})
                    for level in COVERAGE_LEVELS
                ),
                _pct({"value": accept["coverage"]}),
                "n/a" if accept["min_confidence"] is None else f"{accept['min_confidence']:.3f}",
            ]
        )
    return headers, rows


def item_category_comparisons(
    comparisons: list[dict[str, Any]],
) -> tuple[list[str], list[list[Any]]]:
    headers = [
        "Dimension",
        "Run A",
        "Run B",
        "Items",
        "Macro F1 pp",
        "Accuracy pp",
        "Top-3 pp",
        "p (top-1)",
    ]
    rows = []
    for comparison in sorted(comparisons, key=lambda c: (c["dimension"], c["a"], c["b"])):
        differences = comparison["differences"]
        rows.append(
            [
                comparison["dimension"],
                comparison["a"],
                comparison["b"],
                comparison["items"],
                _diff(differences["macro_f1"]),
                _diff(differences["accuracy"]),
                _diff(differences["top3_accuracy"]),
                _p(comparison["mcnemar"]["top1"]),
            ]
        )
    return headers, rows


TITLES = {
    "ocr_fields": "OCR fields by run",
    "ocr_fields_by_segment": "OCR by segment",
    "ocr_items": "OCR items by run",
    "local_vs_hosted": "Local against hosted",
    "full_vs_cropped": "Full against cropped photos",
    "ocr_comparisons": "OCR comparisons",
    "item_categories": "Item categories by run",
    "item_categories_by_source": "Item categories by source",
    "calibration": "Calibration of the top category score",
    "auto_accept": "Auto-accept: precision at coverage",
    "item_category_comparisons": "Item category comparisons",
}


def write_tables(
    writer: ResultsWriter,
    run_results: list[dict[str, Any]],
    comparison_results: list[dict[str, Any]],
) -> list[str]:
    """Write every table; returns their names in order."""
    ocr = [result for result in run_results if result["run"]["task"] == "ocr"]
    categories = [result for result in run_results if result["run"]["task"] == "item_categories"]
    ocr_comparisons = [c for c in comparison_results if c["task"] == "ocr"]
    category_comparisons = [c for c in comparison_results if c["task"] == "item_categories"]
    tables: dict[str, tuple[list[str], list[list[Any]]]] = {
        "ocr_fields": ocr_fields(ocr),
        "ocr_fields_by_segment": ocr_fields_by_segment(ocr),
        "ocr_items": ocr_items(ocr),
        "local_vs_hosted": local_vs_hosted(ocr),
        "full_vs_cropped": (
            COMPARISON_HEADERS,
            _comparison_rows([c for c in ocr_comparisons if c["dimension"] == "crops"]),
        ),
        "ocr_comparisons": (
            COMPARISON_HEADERS,
            _comparison_rows([c for c in ocr_comparisons if c["dimension"] != "crops"]),
        ),
        "item_categories": item_categories(categories),
        "item_categories_by_source": item_categories_by_source(categories),
        "calibration": calibration(categories),
        "auto_accept": auto_accept(categories),
        "item_category_comparisons": item_category_comparisons(category_comparisons),
    }
    for name, (headers, rows) in tables.items():
        writer.write_table(name, TITLES[name], headers, rows, NOTES[name])
    return list(tables)
