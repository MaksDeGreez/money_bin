"""Finding QR codes in receipt photos with a cascade of strategies, cheapest and most useful first.

Receipts are printed on thermal paper. On many photos the QR code is faded, low in contrast and
small, so plain decoding misses most of them. Local contrast enhancement (CLAHE) finds far more,
and a closer look at the regions where zxing saw a QR code but could not read it (Reed-Solomon
checksum failure) rescues more: a minimum filter fills the white holes in faded dark modules.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass, field

import cv2
import numpy as np
import zxingcpp

from receipt_ingest import taxurl

QR_FORMAT = zxingcpp.BarcodeFormat.QRCode
# A detected region smaller than this (in full-resolution pixels) is noise, not a receipt QR code.
MIN_REGION_SIDE = 40
MAX_REGIONS = 4
# Regions larger than this (with their margin) are not upscaled: a receipt QR code that zxing
# cannot read is small, and upscaling a large region costs seconds for nothing.
MAX_UPSCALED_SIDE = 700


@dataclass
class Context:
    """One image and the derived copies the strategies share, so each copy is built once."""

    grey: np.ndarray
    regions: list[tuple[int, int, int, int]] = field(default_factory=list)
    _cache: dict[str, np.ndarray] = field(default_factory=dict)

    def derived(self, key: str, build: Callable[[], np.ndarray]) -> np.ndarray:
        if key not in self._cache:
            self._cache[key] = build()
        return self._cache[key]

    @property
    def half(self) -> np.ndarray:
        return self.derived("half", lambda: _scale(self.grey, 0.5))

    @property
    def clahe_half(self) -> np.ndarray:
        return self.derived("clahe_half", lambda: _clahe(self.half))

    @property
    def clahe_full(self) -> np.ndarray:
        return self.derived("clahe_full", lambda: _clahe(self.grey))


def _scale(image: np.ndarray, factor: float) -> np.ndarray:
    interpolation = cv2.INTER_AREA if factor < 1 else cv2.INTER_CUBIC
    return cv2.resize(image, None, fx=factor, fy=factor, interpolation=interpolation)


def _clahe(image: np.ndarray, clip: float = 2.0, tiles: int = 8) -> np.ndarray:
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(tiles, tiles)).apply(image)


def _read(
    image: np.ndarray,
    binarizer: zxingcpp.Binarizer = zxingcpp.Binarizer.LocalAverage,
    context: Context | None = None,
    factor: float = 1.0,
) -> list[str]:
    """Decode QR codes in `image`; record regions of codes that were found but not read."""
    results = zxingcpp.read_barcodes(
        image,
        formats=QR_FORMAT,
        text_mode=zxingcpp.TextMode.Plain,
        binarizer=binarizer,
        return_errors=context is not None,
    )
    texts = []
    for result in results:
        if result.format != QR_FORMAT:
            continue
        if result.valid and result.text:
            texts.append(result.text)
        elif not result.valid and context is not None:
            _remember_region(context, result.position, factor)
    return texts


def _remember_region(context: Context, position: zxingcpp.Position, factor: float) -> None:
    corners = (
        position.top_left,
        position.top_right,
        position.bottom_right,
        position.bottom_left,
    )
    xs = [point.x / factor for point in corners]
    ys = [point.y / factor for point in corners]
    x0, x1, y0, y1 = int(min(xs)), int(max(xs)), int(min(ys)), int(max(ys))
    if max(x1 - x0, y1 - y0) < MIN_REGION_SIDE:
        return
    for rx0, ry0, _, _ in context.regions:
        # The same code seen in two copies of the image: keep the first sighting.
        if abs(rx0 - x0) < MIN_REGION_SIDE and abs(ry0 - y0) < MIN_REGION_SIDE:
            return
    if len(context.regions) < MAX_REGIONS:
        context.regions.append((x0, y0, x1, y1))


def clahe_half(context: Context) -> list[str]:
    return _read(context.clahe_half, context=context, factor=0.5)


def clahe_full(context: Context) -> list[str]:
    return _read(context.clahe_full, context=context)


def clahe_strong_half(context: Context) -> list[str]:
    return _read(_clahe(context.half, 4.0, 16))


def _region_variants(region: np.ndarray):
    """Copies of a region, in the order that read the most codes on real receipt photos.

    Erosion (a minimum filter) fills white holes in faded dark modules; an opening removes white
    specks. Upscaling helps small codes and is skipped for large regions, where it only costs time.
    """
    local, global_ = zxingcpp.Binarizer.LocalAverage, zxingcpp.Binarizer.GlobalHistogram
    square = {size: np.ones((size, size), np.uint8) for size in (3, 5)}
    if max(region.shape) <= MAX_UPSCALED_SIDE:
        yield cv2.erode(_clahe(_scale(region, 2.0), 2.0, 4), square[5]), global_
    yield cv2.erode(_clahe(region, 1.0, 4), square[3]), local
    strong = _clahe(region, 4.0, 4)
    yield cv2.erode(strong, square[3]), local
    yield cv2.morphologyEx(strong, cv2.MORPH_OPEN, square[5]), local
    yield _clahe(region, 2.0, 4), local


def region_rescue(context: Context) -> list[str]:
    """Look harder at the places where an earlier strategy saw a QR code it could not read."""
    texts: list[str] = []
    height, width = context.grey.shape
    for x0, y0, x1, y1 in context.regions:
        margin = max(x1 - x0, y1 - y0) // 2
        region = context.grey[
            max(0, y0 - margin) : min(height, y1 + margin),
            max(0, x0 - margin) : min(width, x1 + margin),
        ]
        for variant, binarizer in _region_variants(region):
            found = _read(variant, binarizer)
            texts.extend(found)
            if any(taxurl.is_tax_url(text) for text in found):
                return texts
    return texts


Strategy = tuple[str, Callable[[Context], list[str]]]

# Measured on the owner's photos (README, "QR strategies"). Plain greyscale decoding at full, half
# and quarter size, the GlobalHistogram binariser, tiles, Otsu and adaptive thresholds, sharpening
# and OpenCV's QRCodeDetector found no tax-service code that this cascade misses, so they are left
# out.
CASCADE: tuple[Strategy, ...] = (
    ("clahe_half", clahe_half),
    ("clahe_full", clahe_full),
    ("region_rescue", region_rescue),
    ("clahe_strong_half", clahe_strong_half),
)


@dataclass
class ImageResult:
    # Each decoded payload with the name of the strategy that found it first, in the order found.
    found: list[tuple[str, str]]
    hits: dict[str, int]
    seconds: dict[str, float]

    @property
    def payloads(self) -> list[str]:
        return [payload for payload, _ in self.found]


def decode_image(grey: np.ndarray, cascade: tuple[Strategy, ...] = CASCADE) -> ImageResult:
    """Run the cascade on one greyscale image until a tax-service URL turns up.

    Other payloads (promo or payment codes) are collected along the way as a fallback.
    """
    context = Context(grey)
    found: list[tuple[str, str]] = []
    hits: dict[str, int] = {}
    seconds: dict[str, float] = {}
    for name, strategy in cascade:
        started = time.perf_counter()
        texts = strategy(context)
        seconds[name] = time.perf_counter() - started
        known = {payload for payload, _ in found}
        new = list(dict.fromkeys(text for text in texts if text not in known))
        if new:
            hits[name] = len(new)
            found.extend((text, name) for text in new)
        if any(taxurl.is_tax_url(text) for text in new):
            break
    return ImageResult(found, hits, seconds)


def decode_jpeg(data: bytes, cascade: tuple[Strategy, ...] = CASCADE) -> ImageResult:
    grey = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
    if grey is None:
        raise ValueError("not an image")
    return decode_image(grey, cascade)


def receipt_qr(per_image: list[ImageResult]) -> dict:
    """Pick a receipt's QR payload from its images and work out the QR flags.

    A tax-service URL wins over any other code; otherwise the first other payload in part order.
    """
    tax: list[str] = []
    other: list[str] = []
    source: dict[str, tuple[int, str]] = {}
    for index, result in enumerate(per_image, start=1):
        for payload, strategy in result.found:
            bucket = tax if taxurl.is_tax_url(payload) else other
            if payload not in bucket:
                bucket.append(payload)
                source[payload] = (index, strategy)
    payload = tax[0] if tax else (other[0] if other else None)
    part, strategy = source[payload] if payload is not None else (None, None)
    flags = []
    if payload is None:
        flags.append("no_qr")
    elif not tax:
        flags.append("qr_not_tax_url")
    if len(tax) > 1 or (not tax and len(other) > 1):
        flags.append("qr_conflict")
    return {"payload": payload, "strategy": strategy, "part": part, "flags": flags}
