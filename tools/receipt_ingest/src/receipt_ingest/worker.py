"""The work done for one receipt: convert its photos, make thumbnails, read its QR code, crop it.

It runs in a pool process, so the task and the result are plain data. Each step is skipped when
the previous run's result is still valid, which keeps a second identical run from writing anything.

The four stages fail separately. A failed stage falls back to what the previous run recorded when
the receipt's photos are the same, so a failure never costs images that were already good; the
receipt gets `processing_failed` and the failed stage runs again on the next run.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
from dataclasses import dataclass, field
from functools import cache
from importlib.metadata import version
from pathlib import Path

import cv2
import numpy as np
import pillow_heif
from PIL import Image

import receipt_ingest
from receipt_ingest import crop, imaging, qr
from receipt_ingest.fsutil import write_if_changed
from receipt_ingest.numbering import STAGES

IMAGES_DIR = "images"
THUMBS_DIR = "thumbs"


@dataclass
class Task:
    receipt_id: str
    out_dir: str
    parts: list[tuple[str, str]]  # (absolute raw path, relative raw name), in capture order
    # The previous run's record when the parts are the same; None otherwise.
    previous: dict | None
    crop_enabled: bool
    redo_qr: bool
    redo_crop: bool


@dataclass
class Failure:
    stage: str
    error: str  # exception class name
    file: str | None  # relative raw name of the part being processed


@dataclass
class Outcome:
    receipt_id: str
    images: list[dict] = field(default_factory=list)
    thumbs: list[dict] = field(default_factory=list)
    qr: dict | None = None
    crop: dict | None = None
    images_written: int = 0
    thumbs_written: int = 0
    crops_written: int = 0
    qr_decoded: bool = False
    hits: dict[str, int] = field(default_factory=dict)
    seconds: dict[str, float] = field(default_factory=dict)
    failures: list[Failure] = field(default_factory=list)
    # Stages that failed in an earlier run and did not get to run in this one.
    pending: list[str] = field(default_factory=list)

    @property
    def failed_stages(self) -> list[str]:
        stages = {failure.stage for failure in self.failures} | set(self.pending)
        return [stage for stage in STAGES if stage in stages]


@cache
def library_versions() -> dict[str, str]:
    return {
        "receipt_ingest": receipt_ingest.__version__,
        "pillow": version("pillow"),
        "pillow_heif": version("pillow-heif"),
        "libheif": str(pillow_heif.libheif_version()),
        "opencv": cv2.__version__,
        "zxing_cpp": version("zxing-cpp"),
        "numpy": np.__version__,
    }


def file_info(relative: str, data: bytes, size: tuple[int, int]) -> dict:
    return {
        "file": relative,
        "sha256": hashlib.sha256(data).hexdigest(),
        "width": size[0],
        "height": size[1],
        "bytes": len(data),
        # Recorded when the file is written; a reused file keeps the versions that wrote it.
        "written_by": dict(library_versions()),
    }


def _on_disk(out: Path, info: dict | None) -> bool:
    if info is None:
        return False
    path = out / info["file"]
    return path.is_file() and path.stat().st_size == info["bytes"]


def _reusable(out: Path, recorded: dict | None, relative: str) -> bool:
    return recorded is not None and recorded["file"] == relative and _on_disk(out, recorded)


def _jpeg_size(data: bytes) -> tuple[int, int]:
    with Image.open(io.BytesIO(data)) as image:
        return image.size


def _entry(entries: list[dict], part: int) -> dict | None:
    return entries[part - 1] if part <= len(entries) else None


class _Receipt:
    """Holds the state of one task while it runs."""

    def __init__(self, task: Task) -> None:
        self.task = task
        self.out = Path(task.out_dir)
        self.previous = task.previous or {}
        self.retry = set(self.previous.get("failed_stages") or [])
        self.outcome = Outcome(task.receipt_id)
        self.current: str | None = None
        self._jpegs: dict[int, bytes] = {}

    def jpeg(self, part: int) -> bytes:
        if part not in self._jpegs:
            self._jpegs[part] = (self.out / self.outcome.images[part - 1]["file"]).read_bytes()
        return self._jpegs[part]

    def write(self, relative: str, data: bytes) -> tuple[bool, bytes]:
        """Write a JPEG, then read it back from disk and check those bytes.

        Returns (written, the bytes on disk). A file that fails the check is removed.
        """
        path = self.out / relative
        # Comparing first keeps a file and its mtime when a redo produces the same bytes.
        written = write_if_changed(path, data)
        on_disk = path.read_bytes()
        try:
            imaging.verify_bare_jpeg(on_disk)
        except imaging.MetadataLeftError:
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            raise
        return written, on_disk

    def convert(self) -> bool:
        """Write the full-size images that are new or missing; True when any image changed."""
        task, outcome = self.task, self.outcome
        previous_images = self.previous.get("images") or []
        changed = task.previous is None or len(previous_images) != len(task.parts)
        for part, (raw_path, raw_name) in enumerate(task.parts, start=1):
            self.current = raw_name
            relative = f"{IMAGES_DIR}/{task.receipt_id}_{part}.jpg"
            recorded = _entry(previous_images, part)
            if _reusable(self.out, recorded, relative):
                outcome.images.append(recorded)
                continue
            with open(raw_path, "rb") as handle:
                raw = handle.read()
            picture = imaging.decode_to_srgb(raw)
            written, data = self.write(relative, imaging.encode_jpeg(picture))
            outcome.images_written += written
            self._jpegs[part] = data
            info = file_info(relative, data, picture.size)
            outcome.images.append(info)
            if recorded is None or recorded["sha256"] != info["sha256"]:
                changed = True
        return changed

    def thumbnails(self, changed: bool) -> None:
        redo = changed or "thumbs" in self.retry
        previous = [] if redo else (self.previous.get("thumbs") or [])
        for part, (_, raw_name) in enumerate(self.task.parts, start=1):
            self.current = raw_name
            relative = f"{THUMBS_DIR}/{self.task.receipt_id}_{part}.jpg"
            recorded = _entry(previous, part)
            if _reusable(self.out, recorded, relative):
                self.outcome.thumbs.append(recorded)
                continue
            data = imaging.thumbnail(imaging.open_jpeg(self.jpeg(part)))
            written, data = self.write(relative, data)
            self.outcome.thumbs_written += written
            self.outcome.thumbs.append(file_info(relative, data, _jpeg_size(data)))

    def decode_qr(self, changed: bool) -> None:
        previous = self.previous.get("qr")
        fresh = not changed and not self.task.redo_qr and "qr" not in self.retry
        if previous is not None and fresh:
            self.outcome.qr = previous
            return
        results = []
        for part, (_, raw_name) in enumerate(self.task.parts, start=1):
            self.current = raw_name
            result = qr.decode_jpeg(self.jpeg(part))
            for name, count in result.hits.items():
                self.outcome.hits[name] = self.outcome.hits.get(name, 0) + count
            for name, spent in result.seconds.items():
                self.outcome.seconds[name] = self.outcome.seconds.get(name, 0.0) + spent
            results.append(result)
        summary = qr.receipt_qr(results)
        summary["codes"] = [
            [{"payload": payload, "strategy": name} for payload, name in result.found]
            for result in results
        ]
        self.outcome.qr = summary
        self.outcome.qr_decoded = True

    def crop(self, changed: bool, done: list[dict]) -> None:
        """Crop every part; `done` collects the part entries as they are made."""
        task = self.task
        previous = self.previous.get("crop")
        if not task.crop_enabled:
            # --no-crop keeps crops that still match the images and makes no new ones.
            self.outcome.crop = None if changed else previous
            return
        stale = previous is None or changed or task.redo_crop or "crop" in self.retry
        if not stale:
            files = [entry for entry in previous["parts"] if "file" in entry]
            if all(_on_disk(self.out, entry) for entry in files):
                self.outcome.crop = previous
                return
        for part, (_, raw_name) in enumerate(task.parts, start=1):
            self.current = raw_name
            data = self.jpeg(part)
            grey = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
            found = crop.find_quad(grey)
            if found.quad is None:
                done.append({"part": part, "failed": found.reason})
                continue
            rgb = np.asarray(imaging.open_jpeg(data))
            flat = crop.warp(rgb, found.quad)
            relative = f"{IMAGES_DIR}/{task.receipt_id}_{part}_crop.jpg"
            written, encoded = self.write(relative, imaging.encode_jpeg(Image.fromarray(flat)))
            self.outcome.crops_written += written
            info = file_info(relative, encoded, (flat.shape[1], flat.shape[0]))
            done.append({**info, "part": part, "quad": found.quad})
        self.outcome.crop = {"parts": done}

    def fail(self, stage: str, error: Exception) -> None:
        self.outcome.failures.append(Failure(stage, type(error).__name__, self.current))
        self.current = None


def _fill(done: list[dict], recorded: list[dict], count: int) -> list[dict]:
    """The entries made this run, then the recorded ones for the parts that were not reached."""
    return done + recorded[len(done) : count]


def process(task: Task) -> Outcome:
    """Run the stages; an exception is recorded as a failure of its stage, never raised."""
    receipt = _Receipt(task)
    outcome = receipt.outcome
    # Recorded results may stand in for a failed stage only when the photos are the same ones.
    keep = receipt.previous if task.previous is not None else {}
    count = len(task.parts)

    try:
        changed = receipt.convert()
    except Exception as error:
        receipt.fail("convert", error)
        recorded = keep.get("images") or []
        if len(recorded) == count:
            outcome.images = _fill(outcome.images, recorded, count)
        else:
            # A receipt has all its images or none. Files converted this run belong to no
            # recorded receipt yet and are removed as orphans.
            outcome.images = []
        outcome.thumbs = keep.get("thumbs") or []
        outcome.qr = keep.get("qr")
        outcome.crop = keep.get("crop")
        outcome.pending = sorted(receipt.retry - {"convert"})
        return outcome

    try:
        receipt.thumbnails(changed)
    except Exception as error:
        receipt.fail("thumbs", error)
        outcome.thumbs = _fill(outcome.thumbs, keep.get("thumbs") or [], count)

    try:
        receipt.decode_qr(changed)
    except Exception as error:
        receipt.fail("qr", error)
        outcome.qr = keep.get("qr")

    done: list[dict] = []
    try:
        receipt.crop(changed, done)
    except Exception as error:
        receipt.fail("crop", error)
        reached = {entry["part"] for entry in done}
        recorded = [
            entry
            for entry in (keep.get("crop") or {}).get("parts", [])
            if entry["part"] not in reached
        ]
        parts = sorted(done + recorded, key=lambda entry: entry["part"])
        outcome.crop = {"parts": parts} if parts else None
    return outcome
