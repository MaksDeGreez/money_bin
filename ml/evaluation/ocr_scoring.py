"""OCR metrics of one run: per receipt first, then aggregated per segment with bootstrap intervals.

Per receipt (a prediction line whose status is not `skipped`; a receipt the backend failed on,
`parse_failed` or `error`, has no answer and counts as wrong everywhere):

- **QR fields** (`date`, `time` to the minute in Kyiv time, `total`, `fiscal_number`,
  `receipt_number`): exact match with the receipt's QR fields (`evaluation.ocr_fields`), over the
  receipts whose QR code has the field.
- **merchant**: `text.normalise_merchant` of both sides equal, over receipts whose ground truth has
  a merchant that does not normalise to nothing (pre-fill rule applies).
- **kind**: the predicted `kind` (`fiscal`, `card_slip`, or `none` for a missing or failed answer)
  against the ground truth's kind, else `fiscal` for a receipt with a tax QR code and no
  ground-truth kind; a receipt whose kind record is pre-filled by the run's model is left out,
  not given the QR stand-in. Accuracy and the confusion counts.
- **items**: `matching.match_items` against the ground-truth items. With `tp` matched pairs, `pred`
  predicted and `ref` reference items: precision `tp / pred`, recall `tp / ref`, F1
  `2 tp / (pred + ref)`. Micro values sum `tp`, `pred` and `ref` over receipts; macro F1 is the mean
  of per-receipt F1 over receipts with item ground truth (a receipt with no item on either side has
  F1 1 when the backend answered, such as a card slip read right, and 0 when it failed). For each
  of the variants `main`, `strict`, `lenient`.
- **character error rate** of the names of `main`-matched items: the sum of edit distances over the
  sum of reference name lengths, on normalised names (`cer_normalised`) and on names with only
  Unicode NFC and collapsed spaces (`cer_plain`, where case and look-alike letters count).
- **items sum to the total**: the predicted item amounts add up exactly (as decimals) to the QR
  total, else to the ground truth's total; over receipts with such a total, card slips (by
  `GroundTruth.reference_kind`) left out: they have no items.
- **parse failures** over attempted receipts; errors and repairs as counts; seconds per receipt
  over answered and unparsable receipts (mean, median, 90th percentile).

Segments: `all`; `fiscal`, `card_slip`, `kind_unknown` (by `GroundTruth.reference_kind`, the same
for every run); `one_photo`, `multi_photo`; and, for a run with crops, `crop_failed` (a receipt
for which the run sent at least one full photo because there was no crop).
"""

from collections import Counter
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

from evaluation.bootstrap import Ratio, draws_for, estimate, rng_for
from evaluation.common import cost_summary, timing_summary
from evaluation.inputs import ReceiptInfo, Run
from evaluation.matching import VARIANTS, decimal_or_none, match_items
from evaluation.ocr_fields import FIELDS, items_sum_to, predicted_of, truth_of
from evaluation.text import levenshtein, normalise_merchant, normalise_name, plain
from evaluation.truth import GroundTruth

KINDS = ("fiscal", "card_slip")
PREDICTED_KINDS = (*KINDS, "none")
SEGMENTS = (
    "all",
    "fiscal",
    "card_slip",
    "kind_unknown",
    "one_photo",
    "multi_photo",
    "crop_failed",
)
ITEM_STATS = ("precision", "recall", "f1_micro", "f1_macro")


@dataclass
class ReceiptOutcome:
    receipt_id: str
    status: str
    seconds: float | None
    repaired: bool
    kind_segment: str
    parts: int
    crop_failed: bool
    record: dict[str, Any] = field(repr=False)
    ratios: dict[str, tuple[float, float]] = field(default_factory=dict)
    kind_pair: tuple[str, str] | None = None
    excluded_prefilled: dict[str, str | None] = field(default_factory=dict)


def _item_ratios(
    prefix: str,
    predicted: list[dict[str, Any]],
    reference: list[dict[str, Any]],
    *,
    answered: bool,
) -> dict[str, tuple[float, float]]:
    matching = match_items(predicted, reference)
    n_pred, n_ref = len(predicted), len(reference)
    ratios: dict[str, tuple[float, float]] = {}
    for variant in VARIANTS:
        tp = len(matching.matched(variant))
        # Nothing to find: right when the backend answered (and found nothing), wrong if it failed.
        empty = 1.0 if answered else 0.0
        f1 = empty if n_pred + n_ref == 0 else 2 * tp / (n_pred + n_ref)
        ratios[f"{prefix}.{variant}.precision"] = (tp, n_pred)
        ratios[f"{prefix}.{variant}.recall"] = (tp, n_ref)
        ratios[f"{prefix}.{variant}.f1_micro"] = (2 * tp, n_pred + n_ref)
        ratios[f"{prefix}.{variant}.f1_macro"] = (f1, 1)
    edits_norm = length_norm = edits_plain = length_plain = 0
    for pair in matching.matched("main"):
        p_item, r_item = predicted[pair.predicted], reference[pair.reference]
        ref_norm = normalise_name(r_item.get("name"))
        ref_plain = plain(r_item.get("name"))
        edits_norm += levenshtein(normalise_name(p_item.get("name")), ref_norm)
        length_norm += len(ref_norm)
        edits_plain += levenshtein(plain(p_item.get("name")), ref_plain)
        length_plain += len(ref_plain)
    ratios[f"{prefix}.cer_normalised"] = (edits_norm, length_norm)
    ratios[f"{prefix}.cer_plain"] = (edits_plain, length_plain)
    ratios[f"{prefix}.receipts"] = (1, 1)
    ratios[f"{prefix}.reference_items"] = (n_ref, 1)
    ratios[f"{prefix}.predicted_items"] = (n_pred, 1)
    return ratios


def _items_of(receipt: dict[str, Any] | None) -> list[dict[str, Any]]:
    if receipt is None:
        return []
    return [item for item in receipt.get("items") or [] if isinstance(item, dict)]


def score_receipt(
    record: dict[str, Any], info: ReceiptInfo, run: Run, truth: GroundTruth
) -> ReceiptOutcome:
    receipt = record.get("receipt") if record["status"] == "ok" else None
    if not isinstance(receipt, dict):
        receipt = None
    images = record.get("images") or []
    outcome = ReceiptOutcome(
        receipt_id=info.receipt_id,
        status=record["status"],
        seconds=record.get("seconds") if isinstance(record.get("seconds"), int | float) else None,
        repaired=bool(record.get("repaired")),
        kind_segment=truth.reference_kind(info),
        parts=info.parts,
        crop_failed=run.crops and "full" in images,
        record=record,
    )
    ratios = outcome.ratios
    ratios["parse_failed"] = (float(record["status"] == "parse_failed"), 1)

    qr = truth_of(info.qr_fields) if info.qr_fields else dict.fromkeys(FIELDS)
    predicted = predicted_of(receipt)
    for name in FIELDS:
        present = qr[name] is not None
        ratios[f"fields.{name}"] = (float(present and predicted[name] == qr[name]), float(present))

    merchant = truth.field(
        info.receipt_id, run, "merchant", usable=lambda value: bool(normalise_merchant(value))
    )
    outcome.excluded_prefilled["merchant"] = merchant.reason
    reference_merchant = (
        normalise_merchant(merchant.record.document["merchant"]) if merchant.record else ""
    )
    if reference_merchant:  # a name of legal-form words only says nothing
        hit = receipt is not None and normalise_merchant(receipt.get("merchant")) == (
            reference_merchant
        )
        ratios["merchant"] = (float(hit), 1)
    else:
        ratios["merchant"] = (0, 0)

    kind = truth.field(info.receipt_id, run, "kind")
    outcome.excluded_prefilled["kind"] = kind.reason
    if kind.record is not None:
        kind_truth: str | None = str(kind.record.document["kind"])
    elif kind.excluded_prefilled:
        kind_truth = None  # left out, not replaced: the QR stand-in is for receipts without one
    else:
        kind_truth = "fiscal" if info.qr_fields else None
    predicted_kind = receipt.get("kind") if receipt is not None else None
    predicted_kind = predicted_kind if predicted_kind in KINDS else "none"
    if kind_truth in KINDS:
        outcome.kind_pair = (kind_truth, predicted_kind)
        ratios["kind"] = (float(kind_truth == predicted_kind), 1)
    else:
        ratios["kind"] = (0, 0)

    predicted_items = _items_of(receipt)
    for prefix, checked_only in (("items", False), ("items_checked_only", True)):
        chosen = truth.items(info.receipt_id, run, checked_only=checked_only)
        if prefix == "items":
            outcome.excluded_prefilled["items"] = chosen.reason
        if chosen.record is not None:
            ratios.update(
                _item_ratios(
                    prefix,
                    predicted_items,
                    chosen.record.items,
                    answered=receipt is not None,
                )
            )

    total = qr["total"]
    if outcome.kind_segment == "card_slip":
        total = None  # a card slip has no items to add up
    elif total is None:
        total_truth = truth.field(info.receipt_id, run, "total")
        if total_truth.record is not None:
            total = decimal_or_none(total_truth.record.document["total"])
    if total is not None:
        ratios["items_sum_to_total"] = (float(items_sum_to(receipt, Decimal(total))), 1)
    else:
        ratios["items_sum_to_total"] = (0, 0)
    return outcome


def segment_of(outcome: ReceiptOutcome, segment: str, run: Run) -> bool:
    if segment == "all":
        return True
    if segment in KINDS:
        return outcome.kind_segment == segment
    if segment == "kind_unknown":
        return outcome.kind_segment not in KINDS
    if segment == "one_photo":
        return outcome.parts == 1
    if segment == "multi_photo":
        return outcome.parts > 1
    if segment == "crop_failed":
        return run.crops and outcome.crop_failed
    raise ValueError(segment)


def ratio_of(outcomes: list[ReceiptOutcome], key: str) -> Ratio:
    return Ratio.of([outcome.ratios.get(key, (0.0, 0.0)) for outcome in outcomes])


def _metric(outcomes: list[ReceiptOutcome], key: str, draws: Any) -> dict[str, Any]:
    ratio = ratio_of(outcomes, key)
    return {
        **estimate(ratio, draws),
        "numerator": float(ratio.num.sum()),
        "denominator": float(ratio.den.sum()),
    }


def _items_block(outcomes: list[ReceiptOutcome], prefix: str, draws: Any) -> dict[str, Any]:
    with_truth = [o for o in outcomes if f"{prefix}.receipts" in o.ratios]
    block: dict[str, Any] = {
        "receipts": len(with_truth),
        "reference_items": int(ratio_of(outcomes, f"{prefix}.reference_items").num.sum()),
        "predicted_items": int(ratio_of(outcomes, f"{prefix}.predicted_items").num.sum()),
    }
    for variant in VARIANTS:
        block[variant] = {
            stat: _metric(outcomes, f"{prefix}.{variant}.{stat}", draws) for stat in ITEM_STATS
        }
    block["cer_normalised"] = _metric(outcomes, f"{prefix}.cer_normalised", draws)
    block["cer_plain"] = _metric(outcomes, f"{prefix}.cer_plain", draws)
    return block


def aggregate(
    outcomes: list[ReceiptOutcome], *, seed: int, resamples: int, labels: tuple[str, ...]
) -> dict[str, Any]:
    draws = draws_for(len(outcomes), resamples, rng_for(seed, *labels))
    confusion: dict[str, dict[str, int]] = {
        kind: dict.fromkeys(PREDICTED_KINDS, 0) for kind in KINDS
    }
    for outcome in outcomes:
        if outcome.kind_pair is not None:
            truth_kind, predicted_kind = outcome.kind_pair
            confusion[truth_kind][predicted_kind] += 1
    answered = [
        o.seconds for o in outcomes if o.status in ("ok", "parse_failed") and o.seconds is not None
    ]
    return {
        "receipts": len(outcomes),
        "fields": {name: _metric(outcomes, f"fields.{name}", draws) for name in FIELDS},
        "merchant": _metric(outcomes, "merchant", draws),
        "kind": {"accuracy": _metric(outcomes, "kind", draws), "confusion": confusion},
        "items": _items_block(outcomes, "items", draws),
        "items_checked_only": _items_block(outcomes, "items_checked_only", draws),
        "items_sum_to_total": _metric(outcomes, "items_sum_to_total", draws),
        "parse_failed": _metric(outcomes, "parse_failed", draws),
        "errors": sum(o.status == "error" for o in outcomes),
        "repaired": sum(o.repaired for o in outcomes),
        "seconds_per_receipt": timing_summary(answered),
    }


@dataclass
class OcrRunScores:
    run: Run
    outcomes: list[ReceiptOutcome]
    counts: dict[str, int]
    segments: dict[str, dict[str, Any]]
    cost_usd: dict[str, Any] | None


def score_run(
    run: Run,
    receipts: dict[str, ReceiptInfo],
    truth: GroundTruth,
    *,
    seed: int,
    resamples: int,
) -> OcrRunScores:
    outcomes: list[ReceiptOutcome] = []
    counts: Counter[str] = Counter()
    for record in run.records:
        counts["lines"] += 1
        if record["status"] == "skipped":
            counts["skipped"] += 1
            continue
        info = receipts.get(record["receipt_id"])
        if info is None:
            counts["not_in_receipt_set"] += 1
            continue
        outcomes.append(score_receipt(record, info, run, truth))
    for key in ("items", "merchant", "kind"):
        reasons = [o.excluded_prefilled.get(key) for o in outcomes]
        counts[f"excluded_prefilled_{key}"] = sum(reason is not None for reason in reasons)
        counts[f"excluded_prefilled_{key}_unknown"] = sum(reason == "unknown" for reason in reasons)
    segments = {}
    for segment in SEGMENTS:
        if segment == "crop_failed" and not run.crops:
            segments[segment] = None
            continue
        members = [o for o in outcomes if segment_of(o, segment, run)]
        segments[segment] = aggregate(
            members, seed=seed, resamples=resamples, labels=(run.run_id, segment)
        )
    known = (
        "lines",
        "skipped",
        "not_in_receipt_set",
        "excluded_prefilled_items",
        "excluded_prefilled_items_unknown",
        "excluded_prefilled_merchant",
        "excluded_prefilled_merchant_unknown",
        "excluded_prefilled_kind",
        "excluded_prefilled_kind_unknown",
    )
    return OcrRunScores(
        run=run,
        outcomes=outcomes,
        counts={key: int(counts.get(key, 0)) for key in known},
        segments=segments,
        cost_usd=cost_summary(run.records),
    )


def diagnostics(scores: OcrRunScores) -> list[dict[str, Any]]:
    """Per-receipt detail for the private diagnostics folder (never for `eval/results/`)."""
    rows = []
    for outcome in scores.outcomes:
        rows.append(
            {
                "receipt_id": outcome.receipt_id,
                "status": outcome.status,
                "kind_segment": outcome.kind_segment,
                "parts": outcome.parts,
                "crop_failed": outcome.crop_failed,
                "excluded_prefilled": outcome.excluded_prefilled,
                "ratios": {key: list(value) for key, value in sorted(outcome.ratios.items())},
            }
        )
    return rows
