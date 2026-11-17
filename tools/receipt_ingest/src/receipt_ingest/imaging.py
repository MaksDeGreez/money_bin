"""Decoding raw photos, colour conversion to sRGB, and writing JPEGs that carry no metadata."""

from __future__ import annotations

import io
from functools import lru_cache

import pillow_heif
from PIL import Image, ImageCms, ImageOps

pillow_heif.register_heif_opener()

JPEG_QUALITY = 90
THUMB_QUALITY = 80
THUMB_LONG_SIDE = 320
MAX_IMAGE_BYTES = 15 * 1024 * 1024  # the Rails app's Receipt::MAX_IMAGE_BYTES

# Markers a bare JPEG needs. Everything else (APP1 EXIF/XMP, APP2 ICC/MPF, APP13, COM, ...) can
# carry metadata and is refused.
_SOI, _EOI, _SOS, _APP0 = 0xD8, 0xD9, 0xDA, 0xE0
_ALLOWED_SEGMENTS = {
    0xDB,  # DQT
    0xC0,  # SOF0 baseline
    0xC1,  # SOF1 extended sequential
    0xC2,  # SOF2 progressive
    0xC4,  # DHT
    0xDD,  # DRI
}
_RST = range(0xD0, 0xD8)


class MetadataLeftError(Exception):
    """A written JPEG still carries something besides pixels, or it is too big."""


@lru_cache(maxsize=8)
def _to_srgb_transform(icc: bytes, mode: str) -> ImageCms.ImageCmsTransform:
    source = ImageCms.ImageCmsProfile(io.BytesIO(icc))
    target = ImageCms.createProfile("sRGB")
    return ImageCms.buildTransform(
        source, target, mode, "RGB", renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC
    )


def decode_to_srgb(data: bytes) -> Image.Image:
    """Decode raw photo bytes into an upright 8-bit RGB image in sRGB, with no metadata attached."""
    with Image.open(io.BytesIO(data)) as opened:
        # pillow-heif already rotates HEIC on open and sets the EXIF orientation to 1, so this
        # call is a no-op for HEIC and applies the orientation exactly once for JPEG.
        upright = ImageOps.exif_transpose(opened)
        icc = opened.info.get("icc_profile")
    image = upright
    if icc and image.mode in ("RGB", "L"):
        try:
            transform = _to_srgb_transform(icc, image.mode)
        except (OSError, ImageCms.PyCMSError):
            # A broken or unusual profile (for example a grey profile on an RGB image): keep the
            # pixels as they are, which treats them as sRGB.
            transform = None
        if transform is not None:
            image = ImageCms.applyTransform(image, transform)
    if image.mode != "RGB":
        image = image.convert("RGB")
    # A new image built from the pixel bytes alone cannot carry EXIF, ICC, XMP or comments along.
    return Image.frombytes("RGB", image.size, image.tobytes())


def encode_jpeg(image: Image.Image, quality: int = JPEG_QUALITY) -> bytes:
    clean = Image.frombytes("RGB", image.size, image.convert("RGB").tobytes())
    buffer = io.BytesIO()
    clean.save(buffer, format="JPEG", quality=quality)
    data = buffer.getvalue()
    verify_bare_jpeg(data)
    return data


def thumbnail(image: Image.Image) -> bytes:
    small = image.copy()
    small.thumbnail((THUMB_LONG_SIDE, THUMB_LONG_SIDE), Image.Resampling.LANCZOS)
    return encode_jpeg(small, THUMB_QUALITY)


def _check_app0(segment: bytes) -> None:
    # JFIF APP0: identifier, version (2), units (1), densities (4), thumbnail width and height (2).
    if not segment.startswith(b"JFIF\x00") or len(segment) < 14:
        raise MetadataLeftError("APP0 is not a plain JFIF header")
    if segment[12] != 0 or segment[13] != 0 or len(segment) != 14:
        raise MetadataLeftError("APP0 carries a thumbnail")


def _check_markers(data: bytes) -> None:
    if data[:2] != b"\xff\xd8":
        raise MetadataLeftError("not a JPEG")
    pos = 2
    length = len(data)
    while pos < length:
        if data[pos] != 0xFF:
            raise MetadataLeftError("unexpected bytes between segments")
        while pos < length and data[pos] == 0xFF:
            pos += 1
        if pos >= length:
            break
        marker = data[pos]
        pos += 1
        if marker == _EOI:
            if pos != length:
                raise MetadataLeftError("bytes after the end of the image")
            return
        if marker in _RST:
            continue
        if marker not in _ALLOWED_SEGMENTS and marker not in (_APP0, _SOS):
            raise MetadataLeftError(f"segment 0x{marker:02X} is not allowed")
        seg_len = int.from_bytes(data[pos : pos + 2], "big")
        payload = data[pos + 2 : pos + seg_len]
        if marker == _APP0:
            _check_app0(payload)
        pos += seg_len
        if marker == _SOS:
            pos = _end_of_scan(data, pos)
    raise MetadataLeftError("no end-of-image marker")


def _end_of_scan(data: bytes, pos: int) -> int:
    """Skip entropy-coded data: 0xFF00 is a stuffed byte, RSTn and 0xFF fill bytes stay inside."""
    while True:
        pos = data.find(b"\xff", pos)
        if pos < 0 or pos + 1 >= len(data):
            raise MetadataLeftError("no end-of-image marker")
        following = data[pos + 1]
        if following == 0x00 or following in _RST:
            pos += 2
        elif following == 0xFF:
            pos += 1
        else:
            return pos


def verify_bare_jpeg(data: bytes) -> None:
    """Raise MetadataLeftError unless `data` is a JPEG with pixels only, under the size limit."""
    if len(data) >= MAX_IMAGE_BYTES:
        raise MetadataLeftError("the image is too big")
    _check_markers(data)
    with Image.open(io.BytesIO(data)) as image:
        if len(image.getexif()) > 0:
            raise MetadataLeftError("EXIF left")
        for key in ("icc_profile", "xmp", "comment", "exif", "photoshop", "mp"):
            if key in image.info:
                raise MetadataLeftError(f"{key} left")


def open_jpeg(data: bytes) -> Image.Image:
    with Image.open(io.BytesIO(data)) as image:
        return image.convert("RGB")
