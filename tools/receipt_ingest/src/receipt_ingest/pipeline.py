"""One run: scan, group, number, process, write the metadata files, print the summary."""

from __future__ import annotations

import hashlib
import json
import multiprocessing
import os
import re
from collections import Counter
from collections.abc import Callable, Iterable
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import TextIO

from receipt_ingest import grouping, numbering, qr, review, scan, taxurl, worker
from receipt_ingest.fsutil import (
    RefusedError,
    check_output_location,
    ensure_dir,
    remove_leftover_temps,
    write_if_changed,
)

STATE_FILE = "state.json"
RECEIPTS_FILE = "receipts.jsonl"
REVIEW_FILE = "groups_review.html"
# Output files the tool owns. Anything else in images/ and thumbs/ is left alone.
OWN_FILE = re.compile(r"rcpt_\d{6,}_\d+(_crop)?\.jpg")
FLAG_ORDER = (
    "no_capture_time",
    "too_many_parts",
    "raw_missing",
    "processing_failed",
    "no_qr",
    "qr_not_tax_url",
    "qr_conflict",
    "qr_fields_partial",
    "crop_failed",
)

EXIT_OK, EXIT_FAILED, EXIT_USAGE = 0, 1, 2


@dataclass
class Options:
    raw_dir: Path
    out_dir: Path
    gap: float = 8.0
    crop: bool = True
    redo_qr: bool = False
    redo_crop: bool = False
    jobs: int = 1


@dataclass
class Counts:
    status: Counter = field(default_factory=Counter)
    images_written: int = 0
    thumbs_written: int = 0
    crops_written: int = 0
    files_deleted: int = 0
    metadata_written: int = 0
    retired: int = 0
    hits: Counter = field(default_factory=Counter)
    seconds: dict[str, float] = field(default_factory=dict)
    failures: int = 0


def default_jobs() -> int:
    # Leave two cores for the rest of the machine; more than eight workers gains little and each
    # holds a few full-size images in memory.
    return max(1, min(8, (os.cpu_count() or 2) - 2))


def _map(function: Callable, items: list, jobs: int) -> Iterable:
    if jobs <= 1 or len(items) <= 1:
        return map(function, items)
    # "spawn" behaves the same on macOS and Linux and avoids forking a process that has threads.
    context = multiprocessing.get_context("spawn")
    executor = ProcessPoolExecutor(max_workers=min(jobs, len(items)), mp_context=context)
    return _drain(executor, function, items)


def _drain(executor: ProcessPoolExecutor, function: Callable, items: list) -> Iterable:
    with executor:
        yield from executor.map(function, items, chunksize=1)


def _probe(item: tuple[str, str]) -> scan.Probe:
    path, name = item
    return scan.probe(Path(path), name)


def fingerprint(images: list[dict]) -> str | None:
    """The Rails app's Receipt.fingerprint: one image's SHA-256, or that of the sorted digests."""
    digests = [image["sha256"] for image in images]
    if not digests:
        return None
    if len(digests) == 1:
        return digests[0]
    return hashlib.sha256("".join(sorted(digests)).encode("ascii")).hexdigest()


def receipt_flags(record: dict) -> list[str]:
    flags = set(record.get("group_flags") or [])
    if record.get("raw_missing"):
        flags.add("raw_missing")
    if record.get("failed"):
        flags.add("processing_failed")
    qr_result = record.get("qr")
    if qr_result is not None:
        flags.update(qr_result.get("flags") or [])
        _, _, partial = taxurl.parse(qr_result.get("payload"))
        if partial:
            flags.add("qr_fields_partial")
    crop_result = record.get("crop")
    if crop_result is not None and any("failed" in part for part in crop_result["parts"]):
        flags.add("crop_failed")
    return [flag for flag in FLAG_ORDER if flag in flags]


def jsonl_line(record: dict) -> str:
    payload = (record.get("qr") or {}).get("payload")
    qr_values, qr_fields, _ = taxurl.parse(payload)
    line = {
        "receipt_id": record["receipt_id"],
        "batch": record["batch"],
        "seq_in_batch": record["seq_in_batch"],
        "raw_files": record["raw_files"],
        "captured_at": record["captured_at"],
        "images": record.get("images") or [],
        "fingerprint": fingerprint(record.get("images") or []),
        "qr_payload": payload,
        "qr": qr_values,
        "qr_fields": qr_fields,
    }
    crops = [
        {key: part[key] for key in ("file", "sha256", "width", "height", "bytes", "part", "quad")}
        for part in (record.get("crop") or {}).get("parts", [])
        if "file" in part
    ]
    if crops:
        line["crop"] = crops
    line["flags"] = receipt_flags(record)
    return json.dumps(line, ensure_ascii=False, separators=(", ", ": "))


class Run:
    def __init__(self, options: Options, out: TextIO, err: TextIO) -> None:
        self.options = options
        self.out = out
        self.err = err
        self.counts = Counts()

    def say(self, text: str = "") -> None:
        print(text, file=self.out)

    def complain(self, text: str) -> None:
        print(text, file=self.err)

    def execute(self) -> int:
        options = self.options
        raw_dir = options.raw_dir.expanduser().resolve()
        out_dir = options.out_dir.expanduser().resolve()
        if not raw_dir.is_dir():
            self.complain("error: the raw folder does not exist or is not a folder")
            return EXIT_USAGE
        try:
            check_output_location(raw_dir, out_dir)
        except RefusedError as error:
            self.complain(f"refused: {error}")
            return EXIT_USAGE

        state_path = out_dir / STATE_FILE
        try:
            state = numbering.load_state(
                state_path.read_text(encoding="utf-8") if state_path.exists() else None
            )
        except numbering.StateError as error:
            self.complain(f"error: {error}")
            return EXIT_USAGE
        except (OSError, UnicodeDecodeError) as error:
            self.complain(f"error: state.json cannot be read ({type(error).__name__})")
            return EXIT_USAGE

        scanned = self.scan(raw_dir)
        canonical, duplicates = self.deduplicate(scanned.files, state)
        known = {item.name: item for item in canonical}
        groups = grouping.group_by_gap(canonical, options.gap)
        try:
            overrides = grouping.load_overrides(out_dir / grouping.OVERRIDE_FILE)
            groups, excluded = grouping.apply_overrides(groups, overrides, known)
        except grouping.OverrideError as error:
            self.complain(f"error: {grouping.OVERRIDE_FILE}: {error}")
            return EXIT_USAGE

        ensure_dir(out_dir)
        ensure_dir(out_dir / worker.IMAGES_DIR)
        ensure_dir(out_dir / worker.THUMBS_DIR)
        remove_leftover_temps([out_dir, out_dir / worker.IMAGES_DIR, out_dir / worker.THUMBS_DIR])

        all_shas = {item.sha256 for item in scanned.files}
        excluded_shas = {item.sha256 for item in excluded}
        plan = numbering.plan(groups, state, all_shas, excluded_shas)
        records = self.process(plan, out_dir)
        records += [{**record, "raw_missing": True} for record in plan.raw_missing]
        self.counts.status["raw_missing"] = len(plan.raw_missing)
        records.sort(key=lambda record: record["receipt_id"])

        restored = {planned.group[0].sha256 for planned in plan.planned}
        newly_retired = {entry["key"]: entry for entry in plan.retired}
        retired = [
            entry
            for entry in state["retired"]
            if entry["key"] not in restored and entry["key"] not in newly_retired
        ]
        retired += plan.retired
        retired.sort(key=lambda entry: entry["receipt_id"])
        self.counts.retired = len(plan.retired)

        self.counts.files_deleted = self.remove_orphans(out_dir, records)
        new_state = {
            "format": numbering.STATE_FORMAT,
            "next_id": plan.next_id,
            "receipts": records,
            "retired": retired,
        }
        excluded_by_batch: dict[str, list[str]] = {}
        for item in excluded:
            excluded_by_batch.setdefault(item.batch, []).append(item.name)
        flags = {record["receipt_id"]: receipt_flags(record) for record in records}
        jsonl = "".join(jsonl_line(record) + "\n" for record in records)
        html = review.render(records, flags, excluded_by_batch)
        for name, data in (
            (RECEIPTS_FILE, jsonl.encode("utf-8")),
            (REVIEW_FILE, html.encode("utf-8")),
            (STATE_FILE, numbering.dump_state(new_state)),
        ):
            if write_if_changed(out_dir / name, data):
                self.counts.metadata_written += 1

        self.summary(scanned, duplicates, records, flags)
        return EXIT_FAILED if self.counts.failures else EXIT_OK

    def scan(self, raw_dir: Path) -> scan.ScanResult:
        batches, candidates, non_images = scan.list_candidates(raw_dir)
        items = [(str(path), name) for _, name, path in candidates]
        batch_of = {name: batch for batch, name, _ in candidates}
        path_of = {name: path for _, name, path in candidates}
        result = scan.ScanResult(batches=batches, files=[], non_images=non_images)
        files = []
        for probed in _map(_probe, items, self.options.jobs):
            if probed.error is not None:
                result.unreadable.append(probed.name)
                self.complain(f"skipped unreadable: {probed.name} ({probed.error})")
                continue
            assert probed.sha256 is not None
            files.append(
                scan.RawFile(
                    probed.name,
                    batch_of[probed.name],
                    path_of[probed.name],
                    probed.sha256,
                    probed.captured_at,
                    probed.captured_text,
                )
            )
        result.files = scan.order_files(files)
        return result

    @staticmethod
    def deduplicate(files: list[scan.RawFile], state: dict) -> tuple[list[scan.RawFile], int]:
        recorded = numbering.recorded_names(state)
        present = {item.name for item in files}
        chosen: dict[str, str] = {}
        for item in files:
            if item.sha256 in chosen:
                continue
            name = recorded.get(item.sha256)
            chosen[item.sha256] = name if name in present else item.name
        canonical = [item for item in files if chosen[item.sha256] == item.name]
        return canonical, len(files) - len(canonical)

    def process(self, plan: numbering.Plan, out_dir: Path) -> list[dict]:
        options = self.options
        seq: dict[str, int] = {}
        per_batch: Counter = Counter()
        for planned in sorted(plan.planned, key=lambda planned: planned.group[0].order):
            per_batch[planned.group[0].batch] += 1
            seq[planned.receipt_id] = per_batch[planned.group[0].batch]
        tasks = []
        for planned in plan.planned:
            previous = planned.previous if planned.status == "unchanged" else None
            tasks.append(
                worker.Task(
                    receipt_id=planned.receipt_id,
                    out_dir=str(out_dir),
                    parts=[(str(item.path), item.name) for item in planned.group],
                    previous=previous,
                    crop_enabled=options.crop,
                    redo_qr=options.redo_qr,
                    redo_crop=options.redo_crop,
                )
            )
        records = []
        for planned, outcome in zip(
            plan.planned, _map(worker.process, tasks, options.jobs), strict=True
        ):
            records.append(self.record(planned, outcome, seq[planned.receipt_id]))
        return records

    def record(self, planned: numbering.Planned, outcome: worker.Outcome, seq: int) -> dict:
        counts = self.counts
        group = planned.group
        group_flags = []
        if any(item.captured_at is None for item in group):
            group_flags.append("no_capture_time")
        if len(group) > grouping.MAX_PARTS:
            group_flags.append("too_many_parts")
        record = {
            "receipt_id": planned.receipt_id,
            "key": group[0].sha256,
            "batch": group[0].batch,
            "seq_in_batch": seq,
            "raw_files": [item.name for item in group],
            "parts": [item.sha256 for item in group],
            "captured_at": group[0].captured_text,
            "group_flags": group_flags,
        }
        if outcome.error is not None:
            counts.failures += 1
            counts.status["failed"] += 1
            self.complain(f"error: {outcome.error_file or planned.receipt_id}: {outcome.error}")
            # `failed` makes the next run try this receipt again from the raw photos.
            record.update(images=[], thumbs=[], qr=None, crop=None, failed=True)
            return record
        wrote = outcome.images_written or outcome.thumbs_written or outcome.crops_written
        if planned.status == "unchanged":
            counts.status["rewritten" if wrote or outcome.qr_decoded else "unchanged"] += 1
        elif planned.status == "changed":
            counts.status["rewritten"] += 1
        else:
            counts.status[planned.status] += 1
        counts.images_written += outcome.images_written
        counts.thumbs_written += outcome.thumbs_written
        counts.crops_written += outcome.crops_written
        counts.hits.update(outcome.hits)
        for name, spent in outcome.seconds.items():
            counts.seconds[name] = counts.seconds.get(name, 0.0) + spent
        record.update(
            images=outcome.images,
            thumbs=outcome.thumbs,
            qr=outcome.qr,
            crop=outcome.crop,
            written_by=outcome.written_by,
        )
        return record

    @staticmethod
    def remove_orphans(out_dir: Path, records: list[dict]) -> int:
        """Delete tool-owned images that no receipt refers to: retired receipts, surplus parts."""
        wanted = set()
        for record in records:
            for key in ("images", "thumbs"):
                wanted.update(entry["file"] for entry in record.get(key) or [])
            for part in (record.get("crop") or {}).get("parts", []):
                if "file" in part:
                    wanted.add(part["file"])
        removed = 0
        for folder in (worker.IMAGES_DIR, worker.THUMBS_DIR):
            for path in sorted((out_dir / folder).iterdir()):
                relative = f"{folder}/{path.name}"
                if OWN_FILE.fullmatch(path.name) and path.is_file() and relative not in wanted:
                    path.unlink()
                    removed += 1
        return removed

    def summary(
        self,
        scanned: scan.ScanResult,
        duplicates: int,
        records: list[dict],
        flags: dict[str, list[str]],
    ) -> None:
        counts = self.counts
        batches = sorted({record["batch"] for record in records} | set(scanned.batches))
        self.say("Receipts")
        for batch in batches:
            in_batch = [record for record in records if record["batch"] == batch]
            self.say(self._batch_line(batch, in_batch, flags))
        self.say(self._batch_line("total", records, flags))

        self.say("QR strategies (this run): found / seconds")
        for name, _ in qr.CASCADE:
            spent = counts.seconds.get(name, 0.0)
            self.say(f"  {name}: {counts.hits.get(name, 0)} / {spent:.1f} s")

        made = sum(
            1
            for record in records
            if any("file" in part for part in (record.get("crop") or {}).get("parts", []))
        )
        failed = sum(1 for record in records if "crop_failed" in flags[record["receipt_id"]])
        crop_files = sum(
            1
            for record in records
            for part in (record.get("crop") or {}).get("parts", [])
            if "file" in part
        )
        self.say(f"Crops: {made} receipts with crops ({crop_files} files), {failed} crop_failed")
        self.say(
            f"Skipped files: {duplicates} duplicates, {scanned.non_images} non-images, "
            f"{len(scanned.unreadable)} unreadable"
        )
        status = counts.status
        self.say(
            "This run: "
            f"{status['new']} new, {status['unchanged']} unchanged, "
            f"{status['rewritten']} rewritten, "
            f"{status['restored']} restored, {counts.retired} retired, "
            f"{status['raw_missing']} raw missing, {status['failed']} failed"
        )
        self.say(
            "Written: "
            f"{counts.images_written} images, {counts.crops_written} crops, "
            f"{counts.thumbs_written} thumbnails, {counts.metadata_written} metadata files; "
            f"{counts.files_deleted} files deleted"
        )

    @staticmethod
    def _batch_line(label: str, records: list[dict], flags: dict[str, list[str]]) -> str:
        receipts = len(records)
        images = sum(len(record.get("images") or []) for record in records)
        decoded = sum(1 for record in records if (record.get("qr") or {}).get("payload"))
        tax = sum(
            1 for record in records if taxurl.is_tax_url((record.get("qr") or {}).get("payload"))
        )
        share = f"{100 * decoded / receipts:.1f}%" if receipts else "-"
        kinds = Counter(flag for record in records for flag in flags[record["receipt_id"]])
        flag_text = ", ".join(f"{flag} {kinds[flag]}" for flag in FLAG_ORDER if kinds[flag])
        return (
            f"  {label}: {receipts} receipts, {images} images, QR {decoded} ({share}), "
            f"tax QR {tax}; flags: {flag_text or 'none'}"
        )


def run(options: Options, out: TextIO, err: TextIO) -> int:
    return Run(options, out, err).execute()
