"""The work done for one receipt: convert its photos, make thumbnails, read its QR code, crop it.

It runs in a pool process, so the task and the result are plain data. Each step is skipped when
the previous run's result is still valid, which keeps a second identical run from writing anything.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field
from importlib.metadata import version
from pathlib import Path

import cv2
import numpy as np
import pillow_heif
from PIL import Image

import receipt_ingest
from receipt_ingest import crop, imaging, qr
from receipt_ingest.fsutil import write_if_changed

IMAGES_DIR = "images"
THUMBS_DIR = "thumbs"


@dataclass
class Task:
    receipt_id: str
    out_dir: str
    parts: list[tuple[str, str]]  # (absolute raw path, relative raw name), in capture order
    # The previous run's images, thumbs, qr and crop when the parts are the same; None otherwise.
    previous: dict | None
    crop_enabled: bool
    redo_qr: bool
    redo_crop: bool


@dataclass
class Outcome:
    receipt_id: str
    images: list[dict] = field(default_factory=list)
    thumbs: list[dict] = field(default_factory=list)
    qr: dict | None = None
    crop: dict | None = None
    written_by: dict | None = None
    images_written: int = 0
    thumbs_written: int = 0
    crops_written: int = 0
    qr_decoded: bool = False
    hits: dict[str, int] = field(default_factory=dict)
    seconds: dict[str, float] = field(default_factory=dict)
    error: str | None = None  # exception class name
    error_file: str | None = None  # relative raw name of the part being processed


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


class _Receipt:
    """Holds the state of one task while it runs."""

    def __init__(self, task: Task) -> None:
        self.task = task
        self.out = Path(task.out_dir)
        self.outcome = Outcome(task.receipt_id)
        self.current: str | None = None
        self._jpegs: dict[int, bytes] = {}

    def jpeg(self, part: int) -> bytes:
        if part not in self._jpegs:
            self._jpegs[part] = (self.out / self.outcome.images[part - 1]["file"]).read_bytes()
        return self._jpegs[part]

    def write(self, relative: str, data: bytes) -> bool:
        # Comparing first keeps a file and its mtime when a redo produces the same bytes.
        return write_if_changed(self.out / relative, data)

    def convert(self) -> bool:
        """Write the full-size images that are new or missing; True when any image changed."""
        task, outcome = self.task, self.outcome
        previous_images = (task.previous or {}).get("images") or []
        changed = task.previous is None or len(previous_images) != len(task.parts)
        for part, (raw_path, raw_name) in enumerate(task.parts, start=1):
            self.current = raw_name
            relative = f"{IMAGES_DIR}/{task.receipt_id}_{part}.jpg"
            recorded = previous_images[part - 1] if part <= len(previous_images) else None
            if _reusable(self.out, recorded, relative):
                outcome.images.append(recorded)
                continue
            with open(raw_path, "rb") as handle:
                raw = handle.read()
            picture = imaging.decode_to_srgb(raw)
            data = imaging.encode_jpeg(picture)
            outcome.images_written += self.write(relative, data)
            self._jpegs[part] = data
            info = file_info(relative, data, picture.size)
            outcome.images.append(info)
            if recorded is None or recorded["sha256"] != info["sha256"]:
                changed = True
        if changed or outcome.images_written:
            outcome.written_by = library_versions()
        else:
            outcome.written_by = (task.previous or {}).get("written_by")
        return changed

    def thumbnails(self, changed: bool) -> None:
        previous = [] if changed else ((self.task.previous or {}).get("thumbs") or [])
        for part, (_, raw_name) in enumerate(self.task.parts, start=1):
            self.current = raw_name
            relative = f"{THUMBS_DIR}/{self.task.receipt_id}_{part}.jpg"
            recorded = previous[part - 1] if part <= len(previous) else None
            if _reusable(self.out, recorded, relative):
                self.outcome.thumbs.append(recorded)
                continue
            data = imaging.thumbnail(imaging.open_jpeg(self.jpeg(part)))
            self.outcome.thumbs_written += self.write(relative, data)
            self.outcome.thumbs.append(file_info(relative, data, _jpeg_size(data)))

    def decode_qr(self, changed: bool) -> None:
        previous = (self.task.previous or {}).get("qr")
        if previous is not None and not changed and not self.task.redo_qr:
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

    def crop(self, changed: bool) -> None:
        task = self.task
        previous = (task.previous or {}).get("crop")
        if not task.crop_enabled:
            # --no-crop keeps crops that still match the images and makes no new ones.
            self.outcome.crop = None if changed else previous
            return
        stale = previous is None or changed or task.redo_crop
        if not stale:
            files = [entry for entry in previous["parts"] if "file" in entry]
            if all(_on_disk(self.out, entry) for entry in files):
                self.outcome.crop = previous
                return
        parts = []
        for part, (_, raw_name) in enumerate(task.parts, start=1):
            self.current = raw_name
            data = self.jpeg(part)
            grey = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
            found = crop.find_quad(grey)
            if found.quad is None:
                parts.append({"part": part, "failed": found.reason})
                continue
            rgb = np.asarray(imaging.open_jpeg(data))
            flat = crop.warp(rgb, found.quad)
            relative = f"{IMAGES_DIR}/{task.receipt_id}_{part}_crop.jpg"
            encoded = imaging.encode_jpeg(Image.fromarray(flat))
            self.outcome.crops_written += self.write(relative, encoded)
            info = file_info(relative, encoded, (flat.shape[1], flat.shape[0]))
            parts.append({**info, "part": part, "quad": found.quad})
        self.outcome.crop = {"parts": parts}


def process(task: Task) -> Outcome:
    receipt = _Receipt(task)
    try:
        changed = receipt.convert()
        receipt.thumbnails(changed)
        receipt.decode_qr(changed)
        receipt.crop(changed)
    except Exception as error:  # reported as a processing failure of this receipt, never raised
        failed = Outcome(task.receipt_id, error=type(error).__name__, error_file=receipt.current)
        return failed
    return receipt.outcome
