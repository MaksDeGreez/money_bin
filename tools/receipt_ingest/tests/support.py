"""Synthetic test images, all generated inside the test run. No real receipt data."""

from __future__ import annotations

import io
import json
import struct
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pillow_heif
import zxingcpp
from PIL import Image

# An invented tax-service URL: the values follow the real shapes, nothing else.
TAX_URL = (
    "https://cabinet.tax.gov.ua/cashregs/check?id=123456&date=20260301&time=1015"
    "&fn=4000000001&sm=12.30&mac=" + "a" * 40
)
OTHER_URL = "https://shop.example.test/promo/42"

BASE_TIME = datetime(2026, 3, 1, 10, 0, 0)


# --- EXIF with a thumbnail, written by hand because Pillow cannot write IFD1 ---


def _ascii(text: str) -> tuple[int, int, bytes]:
    data = text.encode("ascii") + b"\x00"
    return 2, len(data), data


def _short(value: int) -> tuple[int, int, bytes]:
    return 3, 1, struct.pack("<H", value)


def _long(value: int) -> tuple[int, int, bytes]:
    return 4, 1, struct.pack("<I", value)


def _rationals(*pairs: tuple[int, int]) -> tuple[int, int, bytes]:
    return 5, len(pairs), b"".join(struct.pack("<II", a, b) for a, b in pairs)


def _ifd(entries: dict[int, tuple[int, int, bytes]], start: int, next_ifd: int) -> bytes:
    count = len(entries)
    data_start = start + 2 + 12 * count + 4
    body = struct.pack("<H", count)
    extra = b""
    for tag in sorted(entries):
        kind, number, payload = entries[tag]
        if len(payload) <= 4:
            body += struct.pack("<HHI", tag, kind, number) + payload.ljust(4, b"\x00")
        else:
            body += struct.pack("<HHII", tag, kind, number, data_start + len(extra))
            extra += payload + (b"\x00" if len(payload) % 2 else b"")
    return body + struct.pack("<I", next_ifd) + extra


def exif_bytes(
    taken: datetime | None = BASE_TIME,
    subsec: str | None = "123",
    offset: str | None = "+02:00",
    orientation: int | None = None,
    gps: bool = True,
    thumbnail: bool = True,
) -> bytes:
    """EXIF (with the "Exif" prefix) holding capture time, camera, GPS and an embedded thumbnail."""
    exif_entries: dict[int, tuple[int, int, bytes]] = {}
    if taken is not None:
        exif_entries[0x9003] = _ascii(taken.strftime("%Y:%m:%d %H:%M:%S"))
    if offset is not None:
        exif_entries[0x9011] = _ascii(offset)
    if subsec is not None:
        exif_entries[0x9291] = _ascii(subsec)
    if not exif_entries:
        exif_entries[0x9000] = (7, 4, b"0232")
    gps_entries = {
        0x0001: _ascii("N"),
        0x0002: _rationals((11, 1), (22, 1), (33, 1)),
        0x0003: _ascii("E"),
        0x0004: _rationals((44, 1), (55, 1), (6, 1)),
    }
    thumb = b""
    if thumbnail:
        buffer = io.BytesIO()
        Image.new("RGB", (16, 12), (10, 200, 10)).save(buffer, "JPEG")
        thumb = buffer.getvalue()

    def ifd0(exif_at: int, gps_at: int, ifd1_at: int) -> bytes:
        entries = {
            0x010F: _ascii("SyntheticCam"),
            0x0110: _ascii("Model T"),
            0x8769: _long(exif_at),
        }
        if orientation is not None:
            entries[0x0112] = _short(orientation)
        if gps:
            entries[0x8825] = _long(gps_at)
        return _ifd(entries, 8, ifd1_at)

    def ifd1(thumb_at: int) -> dict[int, tuple[int, int, bytes]]:
        return {0x0103: _short(6), 0x0201: _long(thumb_at), 0x0202: _long(len(thumb))}

    # Two passes: the sizes do not depend on the offsets, so the first pass finds the offsets.
    size0 = len(ifd0(0, 0, 0))
    exif_at = 8 + size0
    size_exif = len(_ifd(exif_entries, exif_at, 0))
    gps_at = exif_at + size_exif
    size_gps = len(_ifd(gps_entries, gps_at, 0)) if gps else 0
    ifd1_at = gps_at + size_gps if thumbnail else 0
    size1 = len(_ifd(ifd1(0), ifd1_at, 0)) if thumbnail else 0
    thumb_at = ifd1_at + size1
    tiff = b"II*\x00" + struct.pack("<I", 8)
    tiff += ifd0(exif_at, gps_at, ifd1_at)
    tiff += _ifd(exif_entries, exif_at, 0)
    if gps:
        tiff += _ifd(gps_entries, gps_at, 0)
    if thumbnail:
        tiff += _ifd(ifd1(thumb_at), ifd1_at, 0) + thumb
    return b"Exif\x00\x00" + tiff


# --- A Display-P3-like ICC profile (matrix and gamma curves) ---


def _s15(value: float) -> bytes:
    return struct.pack(">i", round(value * 65536))


def _xyz(x: float, y: float, z: float) -> bytes:
    return b"XYZ \x00\x00\x00\x00" + _s15(x) + _s15(y) + _s15(z)


P3_COLUMNS = ((0.5151, 0.2412, -0.0011), (0.2920, 0.6922, 0.0419), (0.1571, 0.0666, 0.7841))
P3_GAMMA_FIXED = 563  # u8Fixed8 for a gamma of about 2.2


def p3_profile() -> bytes:
    """A version 2 RGB display profile with Display P3 primaries (D50-adapted) and gamma 2.2."""
    description = b"Synthetic P3"
    desc = (
        b"desc\x00\x00\x00\x00"
        + struct.pack(">I", len(description) + 1)
        + description
        + b"\x00"
        + b"\x00" * 4
        + b"\x00" * 4
        + b"\x00" * 3
        + b"\x00" * 67
    )
    curve = b"curv\x00\x00\x00\x00" + struct.pack(">I", 1) + struct.pack(">H", P3_GAMMA_FIXED)
    tags = [
        (b"desc", desc),
        (b"wtpt", _xyz(0.9642, 1.0, 0.8249)),
        (b"rXYZ", _xyz(*P3_COLUMNS[0])),
        (b"gXYZ", _xyz(*P3_COLUMNS[1])),
        (b"bXYZ", _xyz(*P3_COLUMNS[2])),
        (b"rTRC", curve),
        (b"gTRC", curve),
        (b"bTRC", curve),
        (b"cprt", b"text\x00\x00\x00\x00No copyright\x00"),
    ]
    table_size = 4 + 12 * len(tags)
    offset = 128 + table_size
    table = struct.pack(">I", len(tags))
    data = b""
    for signature, payload in tags:
        padded = payload + b"\x00" * (-len(payload) % 4)
        table += signature + struct.pack(">II", offset + len(data), len(payload))
        data += padded
    size = 128 + table_size + len(data)
    header = (
        struct.pack(">I", size)
        + b"\x00" * 4
        + bytes([2, 0x10, 0, 0])
        + b"mntr"
        + b"RGB "
        + b"XYZ "
        + struct.pack(">6H", 2026, 1, 1, 0, 0, 0)
        + b"acsp"
        + b"\x00" * 4
        + b"\x00" * 4
        + b"\x00" * 4
        + b"\x00" * 4
        + b"\x00" * 8
        + b"\x00" * 4
        + _s15(0.9642)
        + _s15(1.0)
        + _s15(0.8249)
        + b"\x00" * 4
        + b"\x00" * 16
        + b"\x00" * 28
    )
    assert len(header) == 128
    return header + table + data


def expected_srgb_from_p3(rgb: tuple[int, int, int]) -> np.ndarray:
    """What an exact P3 -> sRGB conversion (relative colorimetric, D50 PCS) gives, on 0..255."""
    p3 = np.array(P3_COLUMNS).T
    srgb = np.array(
        [
            [0.4360747, 0.3850649, 0.1430804],
            [0.2225045, 0.7168786, 0.0606169],
            [0.0139322, 0.0971045, 0.7141733],
        ]
    )
    linear = (np.array(rgb) / 255.0) ** (P3_GAMMA_FIXED / 256)
    out = np.linalg.solve(srgb, p3 @ linear)
    encoded = np.where(out <= 0.0031308, 12.92 * out, 1.055 * np.power(out, 1 / 2.4) - 0.055)
    return encoded * 255


# --- Images ---


def plain_image(size=(64, 48), color=(120, 130, 140)) -> Image.Image:
    return Image.new("RGB", size, color)


def write_jpeg(
    path: Path,
    image: Image.Image | None = None,
    exif: bytes | None = None,
    icc: bytes | None = None,
    extras: bool = False,
    quality: int = 90,
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    image = image if image is not None else plain_image()
    params: dict = {"quality": quality}
    if exif is not None:
        params["exif"] = exif
    if icc is not None:
        params["icc_profile"] = icc
    if extras:
        params["comment"] = b"synthetic comment"
        params["xmp"] = b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF/></x:xmpmeta>'
        params["dpi"] = (300, 300)
    image.save(path, "JPEG", **params)
    return path


def write_heic(path: Path, image: Image.Image, exif: bytes | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    pillow_heif.register_heif_opener()
    params: dict = {"quality": 90}
    if exif is not None:
        params["exif"] = exif
    image.save(path, format="HEIF", **params)
    return path


def shot(
    raw: Path,
    name: str,
    seconds: float,
    color=(120, 130, 140),
    image: Image.Image | None = None,
) -> Path:
    """A raw JPEG photo taken `seconds` after BASE_TIME, with full EXIF."""
    taken = BASE_TIME + timedelta(seconds=int(seconds))
    subsec = f"{round((seconds % 1) * 1000):03d}"
    picture = image if image is not None else plain_image(color=color)
    return write_jpeg(raw / name, picture, exif_bytes(taken, subsec=subsec))


def qr_array(text: str, scale: int = 4) -> np.ndarray:
    code = zxingcpp.create_barcode(text, zxingcpp.BarcodeFormat.QRCode)
    return np.array(zxingcpp.write_barcode_to_image(code, scale=scale))


def page_with_qr(
    text: str, size=(600, 800), scale: int = 4, at: tuple[int, int] | None = None
) -> Image.Image:
    """A white page with a QR code pasted near the bottom (or at `at`)."""
    page = Image.new("L", size, 255)
    code = Image.fromarray(qr_array(text, scale))
    if at is None:
        at = ((size[0] - code.width) // 2, size[1] - code.height - 20)
    page.paste(code, at)
    return page.convert("RGB")


def receipt_on_table(size=(400, 600), paper=(120, 60, 280, 540)) -> Image.Image:
    """A white rectangle (the receipt) on a dark background."""
    image = Image.new("RGB", size, (40, 30, 25))
    image.paste((240, 240, 235), paper)
    return image


def jpeg_markers(data: bytes) -> list[int]:
    """Markers of the segments before the first scan."""
    markers = []
    pos = 2
    while pos < len(data):
        assert data[pos] == 0xFF
        marker = data[pos + 1]
        markers.append(marker)
        if marker == 0xDA:
            break
        length = struct.unpack(">H", data[pos + 2 : pos + 4])[0]
        pos += 2 + length
    return markers


# --- Reading the output ---


def receipts(out: Path) -> list[dict]:
    lines = (out / "receipts.jsonl").read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines]


def by_first_file(out: Path) -> dict[str, dict]:
    return {line["raw_files"][0]: line for line in receipts(out)}


def state(out: Path) -> dict:
    return json.loads((out / "state.json").read_text(encoding="utf-8"))


def snapshot(folder: Path) -> dict[str, tuple[bytes, int]]:
    """Bytes and mtime (ns) of every file under `folder`."""
    return {
        path.relative_to(folder).as_posix(): (path.read_bytes(), path.stat().st_mtime_ns)
        for path in sorted(folder.rglob("*"))
        if path.is_file()
    }
