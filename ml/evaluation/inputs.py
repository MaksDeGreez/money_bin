"""Reading the harness's three inputs: the receipt set, the run folders and the ground truth.

Every input is a file outside the repository; nothing here reads the app's database. A shape the
harness does not understand stops it with a `UsageError` naming the file and the line, never a
value from it.
"""

import hashlib
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from evaluation.common import UsageError, read_jsonl

TASKS = ("ocr", "item_categories")
OCR_STATUSES = ("ok", "parse_failed", "error", "skipped")
GROUND_TRUTH_FILE = "ground_truth.jsonl"
SOURCES = ("dps_xml", "manual")
# `source` of an item-category line: an open set (`memory`, `model`, `decision`, `combined`, ...),
# any short lower-case word.
CATEGORY_SOURCE = re.compile(r"\A[a-z][a-z_]{0,29}\Z")
# The `source` values every run may use; others must be declared in `run.json`'s `sources`.
KNOWN_CATEGORY_SOURCES = frozenset({"memory", "model", "decision", "combined"})
# Text in `combined_from`: a run id, a backend or a model name; no spaces or control characters.
COMBINED_TEXT = re.compile(r"\A[^\s\x00-\x1f]{1,200}\Z")


@dataclass(frozen=True)
class ReceiptInfo:
    """What the harness needs of a line of `receipts.jsonl`: never an image or a QR payload."""

    receipt_id: str
    parts: int
    qr_fields: dict[str, Any] | None
    flags: frozenset[str]


@dataclass
class Run:
    """A run folder: its `run.json` and its prediction lines."""

    run_id: str
    task: str
    meta: dict[str, Any]
    records: list[dict[str, Any]]
    folder: Path = field(repr=False)

    @property
    def model_name(self) -> str:
        return str(self.meta.get("model_name") or "")

    @property
    def model_version(self) -> str | None:
        value = self.meta.get("model_version")
        return value if isinstance(value, str) else None

    @property
    def backend(self) -> str:
        return str(self.meta.get("backend") or "")

    @property
    def crops(self) -> bool:
        return bool((self.meta.get("settings") or {}).get("crops"))

    @property
    def combined_from(self) -> list[dict[str, Any]]:
        """The runs a combined item-category run was made from (`run.json`'s `combined_from`)."""
        value = self.meta.get("combined_from")
        return (
            [entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []
        )

    @property
    def is_combined(self) -> bool:
        """A run says it combines others by `combined_from` in `run.json`, or by a line whose
        `source` is `combined`."""
        return "combined_from" in self.meta or any(
            record.get("source") == "combined" for record in self.records
        )

    def categoriser_names(self) -> list[tuple[str | None, ...]]:
        """The (name, version) of every categoriser behind this run: its own, and for a combined
        run each one it combines. An entry without a usable `model_name`, or a combined run that
        names no part, gives an empty name, which the pre-fill rule treats as unknown."""
        names: list[tuple[str | None, ...]] = [(self.model_name, self.model_version)]
        for entry in self.combined_from:
            name = entry.get("model_name")
            version = entry.get("model_version")
            names.append(
                (
                    name if isinstance(name, str) else "",
                    version if isinstance(version, str) else None,
                )
            )
        if self.is_combined and not self.combined_from:
            names.append(("", None))
        return names

    @property
    def declared_sources(self) -> frozenset[str]:
        """The `source` values `run.json` declares (`sources`), besides the known ones."""
        value = self.meta.get("sources")
        if not isinstance(value, list):
            return frozenset()
        return frozenset(
            item for item in value if isinstance(item, str) and CATEGORY_SOURCE.match(item)
        )


@dataclass(frozen=True)
class GroundTruthRecord:
    ingest_id: str
    source: str
    prefilled_by: str | None
    prefilled_model_version: str | None
    categories_prefilled_by: str | None
    checked: bool
    check_outcome: str | None
    qr_check: str | None
    items_known: bool
    categories_known: bool
    schema_version: int
    document: dict[str, Any]

    @property
    def items(self) -> list[dict[str, Any]]:
        return list(self.document.get("items") or [])


def file_sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_receipt_set(folder: Path) -> dict[str, ReceiptInfo]:
    path = folder / "receipts.jsonl"
    if not path.is_file():
        raise UsageError(f"no receipts.jsonl in the receipt set folder {folder.name}")
    receipts: dict[str, ReceiptInfo] = {}
    for number, line in enumerate(read_jsonl(path), start=1):
        receipt_id = line.get("receipt_id")
        if not isinstance(receipt_id, str) or not receipt_id:
            raise UsageError(f"receipts.jsonl: line {number} has no receipt_id")
        if receipt_id in receipts:
            raise UsageError(f"receipts.jsonl: line {number} repeats a receipt id")
        qr_fields = line.get("qr_fields")
        receipts[receipt_id] = ReceiptInfo(
            receipt_id=receipt_id,
            parts=len(line.get("images") or []),
            qr_fields=qr_fields if isinstance(qr_fields, dict) else None,
            flags=frozenset(flag for flag in line.get("flags") or [] if isinstance(flag, str)),
        )
    return receipts


def _finite_or_none(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, bool) or not isinstance(value, int | float):
        return False
    if isinstance(value, int):
        return abs(value) < 10**15
    return math.isfinite(value)


def _check_ocr_record(record: dict[str, Any], name: str, number: int) -> None:
    if not isinstance(record.get("receipt_id"), str):
        raise UsageError(f"{name}: line {number} has no receipt_id")
    if record.get("status") not in OCR_STATUSES:
        raise UsageError(f"{name}: line {number} has an unknown status")
    receipt = record.get("receipt")
    if receipt is not None and not isinstance(receipt, dict):
        raise UsageError(f"{name}: line {number} has a receipt that is not an object")
    if isinstance(receipt, dict) and not isinstance(receipt.get("items") or [], list):
        raise UsageError(f"{name}: line {number} has items that are not a list")
    if not _finite_or_none(record.get("seconds")):
        raise UsageError(f"{name}: line {number} has seconds that are not a finite number")


def _check_category_record(record: dict[str, Any], name: str, number: int) -> None:
    if not isinstance(record.get("receipt_id"), str):
        raise UsageError(f"{name}: line {number} has no receipt_id")
    position = record.get("position")
    if position is not None and (
        not isinstance(position, int) or isinstance(position, bool) or position < 1
    ):
        raise UsageError(f"{name}: line {number} has a position that is not a whole number >= 1")
    candidates = record.get("candidates")
    if not isinstance(candidates, list) or len(candidates) > 3:
        raise UsageError(f"{name}: line {number} needs a list of at most 3 candidates")
    for candidate in candidates:
        if not isinstance(candidate, dict) or not isinstance(candidate.get("category_slug"), str):
            raise UsageError(f"{name}: line {number} has a candidate without a category_slug")
        score = candidate.get("score")
        if not _finite_or_none(score) or (score is not None and not 0 <= score <= 1):
            raise UsageError(
                f"{name}: line {number} has a candidate score that is not between 0 and 1"
            )
    if not _finite_or_none(record.get("seconds")):
        raise UsageError(f"{name}: line {number} has seconds that are not a finite number")
    source_value = record.get("source")
    if source_value is not None and (
        not isinstance(source_value, str) or not CATEGORY_SOURCE.match(source_value)
    ):
        raise UsageError(f"{name}: line {number} has a source that is not a short lower-case word")
    source = record.get("ground_truth_source")
    if source is not None and source not in SOURCES:
        raise UsageError(f"{name}: line {number} has an unknown ground_truth_source")


def read_run(folder: Path) -> Run:
    meta_path = folder / "run.json"
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise UsageError(f"{folder.name}: run.json is not readable JSON") from None
    if not isinstance(meta, dict):
        raise UsageError(f"{folder.name}: run.json is not a JSON object")
    task = meta.get("task") or "ocr"  # runs written before `task` existed are OCR runs
    if task not in TASKS:
        raise UsageError(f"{folder.name}: run.json has an unknown task")
    run_id = meta.get("run_id") or folder.name
    if not isinstance(run_id, str):
        raise UsageError(f"{folder.name}: run.json has a run_id that is not text")
    for key in ("backend", "model_name"):
        if not isinstance(meta.get(key), str) or not meta[key].strip():
            raise UsageError(f"{run_id}: run.json has no {key}")
    combined = meta.get("combined_from")
    if combined is not None and (
        not isinstance(combined, list) or not all(isinstance(entry, dict) for entry in combined)
    ):
        raise UsageError(f"{run_id}: run.json's combined_from is not a list of objects")
    for entry in combined or []:
        for key in ("run_id", "backend", "model_name", "model_version"):
            value = entry.get(key)
            if value is not None and (
                not isinstance(value, str) or len(value) > 200 or not COMBINED_TEXT.match(value)
            ):
                raise UsageError(f"{run_id}: run.json's combined_from has a bad {key}")
    name = f"{run_id}/predictions.jsonl"
    records = list(read_jsonl(folder / "predictions.jsonl"))
    seen: set[tuple[str, Any]] = set()
    for number, record in enumerate(records, start=1):
        if task == "ocr":
            _check_ocr_record(record, name, number)
            key: tuple[str, Any] = (record["receipt_id"], None)
        else:
            _check_category_record(record, name, number)
            key = (
                record["receipt_id"],
                (record.get("ground_truth_source"), record.get("position")),
            )
        if key in seen:
            raise UsageError(f"{name}: line {number} repeats a receipt (or item) of the run")
        seen.add(key)
    return Run(run_id=run_id, task=task, meta=meta, records=records, folder=folder)


def discover_runs(runs_dir: Path) -> list[Run]:
    """Every folder under `runs_dir` (at any depth) with both `run.json` and `predictions.jsonl`,
    ordered by run id."""
    if not runs_dir.is_dir():
        raise UsageError(f"the runs folder {runs_dir.name} does not exist")
    runs = [
        read_run(meta.parent)
        for meta in sorted(runs_dir.rglob("run.json"))
        if (meta.parent / "predictions.jsonl").is_file()
    ]
    seen: set[str] = set()
    for run in runs:
        if run.run_id in seen:
            raise UsageError(f"two run folders have the run id {run.run_id}")
        seen.add(run.run_id)
    return sorted(runs, key=lambda run: run.run_id)


def _optional_text(value: Any) -> str | None:
    return value.strip() or None if isinstance(value, str) else None


def _categories_known(line: dict[str, Any]) -> bool:
    """The export's `categories_known` (true only when every category is given). A line without
    the key (an older export) has categories when its document carries any non-null slug."""
    if "categories_known" in line:
        return line["categories_known"] is True
    document = line.get("document") or {}
    items = document.get("items") or []
    return document.get("category_slug") is not None or any(
        isinstance(item, dict) and item.get("category_slug") is not None for item in items
    )


def read_ground_truth(folder: Path | None) -> tuple[list[GroundTruthRecord], dict[str, int]]:
    """The records of `ground_truth.jsonl` (schema versions 1 and 2), and counts of lines left
    out for having no ingest id. A missing folder or file gives no records."""
    counts = {"lines": 0, "without_ingest_id": 0}
    if folder is None:
        return [], counts
    path = folder / GROUND_TRUTH_FILE
    if not path.is_file():
        return [], counts
    records: list[GroundTruthRecord] = []
    seen: set[tuple[str, str]] = set()
    for number, line in enumerate(read_jsonl(path), start=1):
        counts["lines"] += 1
        ingest_id = line.get("ingest_id")
        if not isinstance(ingest_id, str) or not ingest_id:
            counts["without_ingest_id"] += 1
            continue
        source = line.get("source")
        if source not in SOURCES:
            raise UsageError(f"{GROUND_TRUTH_FILE}: line {number} has an unknown source")
        version = line.get("schema_version")
        if not isinstance(version, int) or isinstance(version, bool) or version < 1:
            raise UsageError(f"{GROUND_TRUTH_FILE}: line {number} has no schema_version")
        document = line.get("document")
        if not isinstance(document, dict) or not isinstance(document.get("items") or [], list):
            raise UsageError(f"{GROUND_TRUTH_FILE}: line {number} has no document object")
        if (ingest_id, source) in seen:
            raise UsageError(f"{GROUND_TRUTH_FILE}: line {number} repeats a receipt and source")
        seen.add((ingest_id, source))
        records.append(
            GroundTruthRecord(
                ingest_id=ingest_id,
                source=source,
                prefilled_by=_optional_text(line.get("prefilled_by")),
                prefilled_model_version=_optional_text(line.get("prefilled_model_version")),
                categories_prefilled_by=_optional_text(line.get("categories_prefilled_by")),
                checked=bool(line.get("checked_at")),
                check_outcome=_optional_text(line.get("check_outcome")),
                qr_check=_optional_text(line.get("qr_check")),
                items_known=line.get("items_known") is True,
                categories_known=_categories_known(line),
                schema_version=version,
                document=document,
            )
        )
    return records, counts
