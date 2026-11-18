"""Which ground truth counts for a receipt, and for which run.

**Exclusions** (for every run):

- a `dps_xml` record whose `qr_check` is `disagrees`: the saved file contradicts the receipt's own
  QR code, so it is most likely another receipt's file. A `manual` record is kept whatever its
  `qr_check`: a person read this very receipt, and a disagreement there is a slip in a header field;
- a record a person checked against the print with the outcome `differs`.

An unchecked record counts (an imported file is exact by construction, and a manual record is a
person's reading); the item metrics are also reported over records checked as `matches` only
(`items_checked_only`), so a reader can see whether the unchecked ones move the numbers.

**Precedence.** When a receipt has both sources, the `dps_xml` record comes first (the register's
own record, which no model helped make), then the `manual` one. Each purpose takes the first
record, in that order, that has what it needs: items (`items_known`), a merchant, a kind, a total,
or item categories.

**The pre-fill rule.** A record whose `prefilled_by` (with `prefilled_model_version`) is the model a
run evaluates is not ground truth for that run: a person correcting a model's answer leans towards
it. When the record chosen for a purpose is such a record, the receipt has no ground truth for that
purpose in that run and is counted as left out (`excluded_prefilled_*`, with the reason); the next
source is not tried, since the person's record is the receipt's last. `source:hand` and
`source:dps_xml` count for every model; `source:unknown-model`, an unknown `source:` value or a name
that cannot be identified leaves the record out of every run. Categories: `categories_prefilled_by`
against an item-category run, `source:unknown` left out of every one. Which names are the same
model is decided in one place, `evaluation.models`. The rule does not look at the record's source,
so no source can slip past it. The QR fields are independent of every model and are never left out.
"""

from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

from evaluation.inputs import SOURCES, GroundTruthRecord, ReceiptInfo, Run
from evaluation.models import prefill_exclusion


def prefill_reason(record: GroundTruthRecord, run: Run, *, categories: bool) -> str | None:
    """Why `record` is left out of `run` by the pre-fill rule (`same_model`, `unknown`), or None."""
    if categories:
        # A combined run is every categoriser it combines: left out when any of them pre-filled.
        reasons = [
            prefill_exclusion(
                record.categories_prefilled_by, None, names, unknown_marker="source:unknown"
            )
            for names in run.categoriser_names()
        ]
        if "same_model" in reasons:
            return "same_model"
        return "unknown" if "unknown" in reasons else None
    names = (run.model_name, run.model_version)
    return prefill_exclusion(record.prefilled_by, record.prefilled_model_version, names)


def exclusion_reason(record: GroundTruthRecord) -> str | None:
    if record.source == "dps_xml" and record.qr_check == "disagrees":
        return "qr_disagrees"
    if record.check_outcome == "differs":
        return "checked_differs"
    return None


@dataclass(frozen=True)
class Chosen:
    """The record a purpose uses for one receipt and run, or why there is none."""

    record: GroundTruthRecord | None
    excluded_prefilled: bool = False
    reason: str | None = None


class GroundTruth:
    """The ground-truth records of the receipts in the receipt set, by ingest id."""

    def __init__(
        self, records: Iterable[GroundTruthRecord], receipts: dict[str, ReceiptInfo]
    ) -> None:
        self.by_receipt: dict[str, list[GroundTruthRecord]] = {}
        self.counts: Counter[str] = Counter()
        for record in records:
            if record.ingest_id not in receipts:
                self.counts["not_in_receipt_set"] += 1
                continue
            self.counts[f"source_{record.source}"] += 1
            reason = exclusion_reason(record)
            if reason:
                self.counts[f"excluded_{reason}"] += 1
            elif not record.checked:
                self.counts["unchecked"] += 1
            self.by_receipt.setdefault(record.ingest_id, []).append(record)
        for listed in self.by_receipt.values():
            listed.sort(key=lambda record: SOURCES.index(record.source))

    def category_slugs(self) -> frozenset[str]:
        """Every category slug the receipt set's records use: the labels a prediction may have."""
        slugs: set[str] = set()
        for records in self.by_receipt.values():
            for record in records:
                slug = record.document.get("category_slug")
                if isinstance(slug, str):
                    slugs.add(slug)
                for item in record.items:
                    if isinstance(item, dict) and isinstance(item.get("category_slug"), str):
                        slugs.add(item["category_slug"])
        return frozenset(slugs)

    def summary(self) -> dict[str, int]:
        keys = (
            "source_dps_xml",
            "source_manual",
            "excluded_qr_disagrees",
            "excluded_checked_differs",
            "unchecked",
            "not_in_receipt_set",
        )
        return {key: int(self.counts.get(key, 0)) for key in keys}

    def eligible(self, receipt_id: str, *, checked_only: bool = False) -> list[GroundTruthRecord]:
        return [
            record
            for record in self.by_receipt.get(receipt_id, [])
            if exclusion_reason(record) is None
            and (not checked_only or record.check_outcome == "matches")
        ]

    def _first(self, receipt_id: str, checked_only: bool, wanted: Any) -> GroundTruthRecord | None:
        for record in self.eligible(receipt_id, checked_only=checked_only):
            if wanted(record):
                return record
        return None

    def reference_kind(self, receipt: ReceiptInfo) -> str:
        """The receipt's kind for segmenting runs, the same for every run: the ground truth's
        kind (pre-fill ignored: it is not a score), else `fiscal` for a receipt with a tax QR code
        (only fiscal receipts carry one), else `unknown`."""
        record = self._first(receipt.receipt_id, False, lambda r: r.document.get("kind"))
        if record is not None:
            return str(record.document["kind"])
        return "fiscal" if receipt.qr_fields else "unknown"

    def items(self, receipt_id: str, run: Run, *, checked_only: bool = False) -> Chosen:
        record = self._first(receipt_id, checked_only, lambda r: r.items_known)
        return self._for_run(record, run, categories=False)

    def field(
        self, receipt_id: str, run: Run, key: str, *, usable: Any = lambda value: True
    ) -> Chosen:
        """The first record with a usable (not null, and `usable`) value for `key`."""

        def wanted(record: GroundTruthRecord) -> bool:
            value = record.document.get(key)
            return value is not None and usable(value)

        record = self._first(receipt_id, False, wanted)
        return self._for_run(record, run, categories=False)

    def categories(self, receipt_id: str, run: Run) -> Chosen:
        record = self._first(receipt_id, False, lambda r: r.items_known and r.categories_known)
        return self._for_run(record, run, categories=True)

    @staticmethod
    def _for_run(record: GroundTruthRecord | None, run: Run, *, categories: bool) -> Chosen:
        if record is None:
            return Chosen(None)
        reason = prefill_reason(record, run, categories=categories)
        if reason is not None:
            return Chosen(None, excluded_prefilled=True, reason=reason)
        return Chosen(record)
