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

**The pre-fill rule.** A record whose `prefilled_by` is the model a run evaluates is not ground
truth for that run: a person correcting a model's answer leans towards it. When the record chosen
for a purpose is such a record, the receipt has no ground truth for that purpose in that run and is
counted as left out (`excluded_prefilled`); the next source is not tried, since the person's record
is the receipt's last. The same holds for `categories_prefilled_by` and an item-category run. Only
`manual` records carry `prefilled_by` today, but the rule does not look at the source, so it cannot
be bypassed by one (categories on a `dps_xml` record would be a person's work too). The QR fields
are independent of every model and are never left out.

**Same model** (`same_model`): the names are compared without case and surrounding spaces, after
dropping a `backend:` prefix and a `:variant` suffix; a run is the same model as `prefilled_by` when
that equals the run's `model_name` or `model_version` (a hosted model's dated slug), or when their
last path segments are equal (`mlx-community/Qwen3-VL-8B-Instruct-4bit` and
`Qwen3-VL-8B-Instruct-4bit`). The prompt version, the image size and the crops do not matter: a
model with another prompt is still the model that wrote the pre-fill.
"""

from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

from evaluation.inputs import SOURCES, GroundTruthRecord, ReceiptInfo, Run

BACKEND_PREFIXES = ("mlx:", "openrouter:", "stub:", "local:", "hosted:")


def _model_key(name: str) -> str:
    key = name.strip().casefold()
    for prefix in BACKEND_PREFIXES:
        if key.startswith(prefix):
            key = key[len(prefix) :]
    last = key.rsplit("/", 1)[-1]
    if ":" in last:
        key = key[: len(key) - len(last)] + last.split(":", 1)[0]
    return key


def same_model(prefilled_by: str | None, run: Run) -> bool:
    if not prefilled_by:
        return False
    wanted = _model_key(prefilled_by)
    if not wanted:
        return False
    names = [_model_key(name) for name in (run.model_name, run.model_version) if name]
    tail = wanted.rsplit("/", 1)[-1]
    return any(wanted == name or tail == name.rsplit("/", 1)[-1] for name in names if name)


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
        return self._for_run(record, run, prefill=lambda r: r.prefilled_by)

    def field(self, receipt_id: str, run: Run, key: str) -> Chosen:
        record = self._first(receipt_id, False, lambda r: r.document.get(key) is not None)
        return self._for_run(record, run, prefill=lambda r: r.prefilled_by)

    def categories(self, receipt_id: str, run: Run) -> Chosen:
        record = self._first(receipt_id, False, lambda r: r.items_known and r.categories_known)
        return self._for_run(record, run, prefill=lambda r: r.categories_prefilled_by)

    @staticmethod
    def _for_run(record: GroundTruthRecord | None, run: Run, *, prefill: Any) -> Chosen:
        if record is None:
            return Chosen(None)
        if same_model(prefill(record), run):
            return Chosen(None, excluded_prefilled=True)
        return Chosen(record)
