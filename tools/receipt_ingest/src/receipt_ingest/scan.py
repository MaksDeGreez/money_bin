"""Finding raw photos, hashing them and reading their capture time."""

from __future__ import annotations

import hashlib
import io
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image

from receipt_ingest import imaging  # noqa: F401  (registers the HEIF opener)

IMAGE_EXTENSIONS = frozenset({".heic", ".heif", ".jpg", ".jpeg"})
KYIV = ZoneInfo("Europe/Kyiv")

_EXIF_IFD = 0x8769
_DATE_TIME_ORIGINAL = 36867
_OFFSET_TIME_ORIGINAL = 36881
_SUBSEC_TIME_ORIGINAL = 37521
_OFFSET = re.compile(r"([+-])(\d{2}):(\d{2})")


@dataclass(frozen=True)
class RawFile:
    name: str  # POSIX path relative to the raw folder, for example "batch_02/IMG_0001.HEIC"
    batch: str
    path: Path
    sha256: str
    captured_at: datetime | None  # aware
    captured_text: str | None  # ISO 8601 with offset and the sub-seconds as recorded
    order: int = 0  # position in scan order over all batches


@dataclass
class ScanResult:
    batches: list[str]
    files: list[RawFile]  # every readable image in scan order, duplicates included
    non_images: int = 0
    unreadable: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Probe:
    name: str
    sha256: str | None
    captured_at: datetime | None
    captured_text: str | None
    error: str | None  # exception class name when the file could not be read or decoded


def _text(value: object) -> str | None:
    if isinstance(value, bytes):
        value = value.decode("ascii", "replace")
    if not isinstance(value, str):
        return None
    return value.strip("\x00 ").strip() or None


def capture_time(exif: Image.Exif) -> tuple[datetime | None, str | None]:
    """When a photo was taken: EXIF DateTimeOriginal, SubSecTimeOriginal and OffsetTimeOriginal.

    With no offset tag the time is taken as Kyiv local time, where the photos are made.
    """
    tags = exif.get_ifd(_EXIF_IFD)
    stamp = _text(tags.get(_DATE_TIME_ORIGINAL))
    if stamp is None:
        return None, None
    try:
        naive = datetime.strptime(stamp, "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None, None
    subsec = re.sub(r"\D", "", _text(tags.get(_SUBSEC_TIME_ORIGINAL)) or "")
    microsecond = int((subsec + "000000")[:6]) if subsec else 0
    offset_text = _text(tags.get(_OFFSET_TIME_ORIGINAL))
    match = _OFFSET.fullmatch(offset_text or "")
    if match:
        sign = -1 if match.group(1) == "-" else 1
        delta = timedelta(hours=int(match.group(2)), minutes=int(match.group(3)))
        aware = naive.replace(microsecond=microsecond, tzinfo=timezone(sign * delta))
    else:
        aware = naive.replace(microsecond=microsecond, tzinfo=KYIV)
    offset = aware.isoformat()[-6:]
    text = naive.strftime("%Y-%m-%dT%H:%M:%S") + (f".{subsec}" if subsec else "") + offset
    return aware, text


def probe(path: Path, name: str) -> Probe:
    """Hash a raw file and read its capture time. The file is opened read-only and never changed."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
        digest = hashlib.sha256(data).hexdigest()
        with Image.open(io.BytesIO(data)) as image:
            captured_at, text = capture_time(image.getexif())
    except Exception as error:  # a damaged or unsupported file is reported, never fatal
        return Probe(name, None, None, None, type(error).__name__)
    return Probe(name, digest, captured_at, text, None)


def _is_hidden(relative: Path) -> bool:
    return any(part.startswith(".") for part in relative.parts)


def list_candidates(raw_dir: Path) -> tuple[list[str], list[tuple[str, str, Path]], int]:
    """Return (batches, [(batch, name, path)], non_images) without opening any file."""
    batches: list[str] = []
    candidates: list[tuple[str, str, Path]] = []
    non_images = 0
    for entry in sorted(raw_dir.iterdir(), key=lambda item: item.name):
        if entry.is_symlink() or not entry.is_dir() or entry.name.startswith("."):
            non_images += 1
            continue
        batches.append(entry.name)
        for folder, dirnames, filenames in os.walk(entry, followlinks=False):
            folder_path = Path(folder)
            for dirname in dirnames:
                if (folder_path / dirname).is_symlink():
                    non_images += 1
            for filename in filenames:
                path = folder_path / filename
                relative = path.relative_to(raw_dir)
                if (
                    path.is_symlink()
                    or _is_hidden(relative)
                    or path.suffix.lower() not in IMAGE_EXTENSIONS
                ):
                    non_images += 1
                    continue
                candidates.append((entry.name, relative.as_posix(), path))
    return batches, candidates, non_images


def order_files(files: list[RawFile]) -> list[RawFile]:
    """Batches by name; inside a batch timed files by time and name, then untimed ones by name."""

    def key(item: RawFile):
        if item.captured_at is None:
            return (item.batch, 1, 0.0, item.name)
        return (item.batch, 0, item.captured_at.timestamp(), item.name)

    ordered = sorted(files, key=key)
    return [
        RawFile(f.name, f.batch, f.path, f.sha256, f.captured_at, f.captured_text, index)
        for index, f in enumerate(ordered)
    ]
