"""A deterministic receipt crop: the largest bright four-sided shape on a darker background."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

# The search runs on a small copy: contours of a 4032 px photo are slow and no more accurate.
WORK_LONG_SIDE = 1000
MIN_AREA_RATIO = 0.08  # smaller than this is not the receipt itself
MAX_AREA_RATIO = 0.92  # larger is practically the whole frame, so cropping would change nothing
MIN_FILL_RATIO = 0.90  # the bright shape must fill most of its four-sided outline
MIN_CONTRAST = 25  # mean brightness inside minus outside, on a 0-255 scale
MIN_SIDE = 40  # pixels in the work copy
MIN_ANGLE = 65  # degrees; every corner must be between this and 180 minus this
# (threshold above Otsu's, opening kernel side as a share of the long side), tried in order.
# A higher threshold shrinks the halo of a lamp reflection; a larger kernel cuts wider bridges.
ATTEMPTS = ((0, 0.06), (25, 0.06), (0, 0.10), (25, 0.10), (50, 0.10))


@dataclass
class CropResult:
    quad: list[list[int]] | None  # corners in full-resolution pixels: TL, TR, BR, BL
    reason: str | None  # why there is no crop


def _order_corners(points: np.ndarray) -> np.ndarray:
    pts = points.reshape(4, 2).astype(np.float64)
    sums = pts.sum(axis=1)
    diffs = pts[:, 1] - pts[:, 0]
    return np.array(
        [pts[np.argmin(sums)], pts[np.argmin(diffs)], pts[np.argmax(sums)], pts[np.argmax(diffs)]]
    )


def _corner_angles(corners: np.ndarray) -> list[float]:
    angles = []
    for i in range(4):
        before = corners[i - 1] - corners[i]
        after = corners[(i + 1) % 4] - corners[i]
        cosine = np.dot(before, after) / (np.linalg.norm(before) * np.linalg.norm(after))
        angles.append(float(np.degrees(np.arccos(np.clip(cosine, -1.0, 1.0)))))
    return angles


def _quad_for(contour: np.ndarray) -> np.ndarray | None:
    hull = cv2.convexHull(contour)
    perimeter = cv2.arcLength(hull, True)
    for epsilon in (0.01, 0.02, 0.03, 0.04, 0.05, 0.06):
        approx = cv2.approxPolyDP(hull, epsilon * perimeter, True)
        if len(approx) == 4:
            return approx
    return None


def _attempt(small: np.ndarray, blurred: np.ndarray, offset: int, open_ratio: float) -> CropResult:
    otsu, _ = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    _, mask = cv2.threshold(blurred, min(250.0, otsu + offset), 255, cv2.THRESH_BINARY)
    # An opening removes bright parts narrower than the kernel: strips of tape that stick out past
    # the paper, and thin bridges to a lamp reflection on the table. The print on the paper only
    # makes holes, which an external contour ignores, so no closing is needed.
    side = max(3, round(open_ratio * max(small.shape)) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (side, side))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return CropResult(None, "no_bright_region")
    contour = max(contours, key=cv2.contourArea)
    frame_area = float(small.shape[0] * small.shape[1])
    blob_area = cv2.contourArea(contour)
    if blob_area < MIN_AREA_RATIO * frame_area:
        return CropResult(None, "too_small")
    quad = _quad_for(contour)
    if quad is None:
        return CropResult(None, "not_four_sided")
    if not cv2.isContourConvex(quad):
        return CropResult(None, "not_convex")
    quad_area = cv2.contourArea(quad)
    if quad_area > MAX_AREA_RATIO * frame_area:
        return CropResult(None, "whole_frame")
    # A bright shape that fills its outline badly is not a sheet of paper, or it is paper joined
    # to something else (most often a lamp reflection). The outline must also cover the shape:
    # four corners cut out of a round shape leave much of it outside.
    hull_area = cv2.contourArea(cv2.convexHull(contour))
    if blob_area < MIN_FILL_RATIO * quad_area or quad_area < MIN_FILL_RATIO * hull_area:
        return CropResult(None, "not_four_sided")
    corners = _order_corners(quad)
    sides = [np.linalg.norm(corners[i] - corners[(i + 1) % 4]) for i in range(4)]
    if min(sides) < MIN_SIDE:
        return CropResult(None, "too_small")
    # Paper seen from above is close to a rectangle. A sharp corner means the shape includes
    # something else, such as a lamp reflection next to the receipt.
    if not all(MIN_ANGLE <= angle <= 180 - MIN_ANGLE for angle in _corner_angles(corners)):
        return CropResult(None, "not_rectangular")
    inside = np.zeros(small.shape, np.uint8)
    cv2.fillConvexPoly(inside, corners.astype(np.int32), 255)
    mean_in = cv2.mean(small, mask=inside)[0]
    mean_out = cv2.mean(small, mask=cv2.bitwise_not(inside))[0]
    if mean_in - mean_out < MIN_CONTRAST:
        return CropResult(None, "low_contrast")
    return CropResult(corners.tolist(), None)


def find_quad(grey: np.ndarray) -> CropResult:
    """Find the receipt's corners, trying stricter masks when the first one gives no clean shape."""
    height, width = grey.shape
    factor = min(1.0, WORK_LONG_SIDE / max(height, width))
    small = cv2.resize(grey, None, fx=factor, fy=factor, interpolation=cv2.INTER_AREA)
    blurred = cv2.GaussianBlur(small, (7, 7), 0)
    first: CropResult | None = None
    for offset, open_ratio in ATTEMPTS:
        result = _attempt(small, blurred, offset, open_ratio)
        if result.quad is not None:
            corners = np.array(result.quad) / factor
            full = np.clip(np.rint(corners), 0, [width - 1, height - 1]).astype(int)
            return CropResult(full.tolist(), None)
        first = first or result
    assert first is not None
    return first


def warp(rgb: np.ndarray, quad: list[list[int]]) -> np.ndarray:
    """Warp the four-sided region of an RGB array to an upright rectangle."""
    corners = np.array(quad, dtype=np.float32)
    top = np.linalg.norm(corners[1] - corners[0])
    bottom = np.linalg.norm(corners[2] - corners[3])
    left = np.linalg.norm(corners[3] - corners[0])
    right = np.linalg.norm(corners[2] - corners[1])
    out_w = max(1, round(max(top, bottom)))
    out_h = max(1, round(max(left, right)))
    target = np.array([[0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1], [0, out_h - 1]], np.float32)
    matrix = cv2.getPerspectiveTransform(corners, target)
    return cv2.warpPerspective(rgb, matrix, (out_w, out_h), flags=cv2.INTER_CUBIC)
