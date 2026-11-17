import numpy as np
from PIL import Image
from support import receipt_on_table

from receipt_ingest import crop


def grey(image: Image.Image) -> np.ndarray:
    return np.array(image.convert("L"))


def test_white_receipt_on_a_dark_table():
    image = receipt_on_table(size=(400, 600), paper=(120, 60, 280, 540))
    result = crop.find_quad(grey(image))
    assert result.reason is None
    flat = crop.warp(np.array(image), result.quad)
    height, width = flat.shape[:2]
    assert abs(width - 160) <= 8
    assert abs(height - 480) <= 8
    assert flat[height // 2, width // 2].mean() > 200


def test_tilted_receipt_is_warped_upright():
    image = receipt_on_table(size=(600, 600), paper=(220, 100, 380, 500))
    tilted = image.rotate(12, fillcolor=(40, 30, 25), resample=Image.Resampling.BICUBIC)
    result = crop.find_quad(grey(tilted))
    assert result.reason is None
    flat = crop.warp(np.array(tilted), result.quad)
    height, width = flat.shape[:2]
    assert abs(width - 160) <= 12
    assert abs(height - 400) <= 12
    # A straight warp leaves almost no table in the corners.
    assert flat[5:-5, 5:-5].mean() > 220


def test_tape_strips_sticking_out_are_ignored():
    image = receipt_on_table(size=(400, 600), paper=(150, 40, 250, 560))
    for top in (120, 300, 480):
        image.paste((235, 235, 225), (110, top, 290, top + 14))
    result = crop.find_quad(grey(image))
    assert result.reason is None
    xs = [point[0] for point in result.quad]
    assert min(xs) >= 140 and max(xs) <= 260


def test_frame_without_a_receipt():
    dark = np.full((400, 300), 35, np.uint8)
    assert crop.find_quad(dark).quad is None
    noise = (np.random.default_rng(3).random((400, 300)) * 255).astype(np.uint8)
    assert crop.find_quad(noise).quad is None


def test_whole_frame_and_small_shapes_fail():
    almost_white = np.full((400, 300), 240, np.uint8)
    almost_white[:4, :] = 30
    assert crop.find_quad(almost_white).reason in {"whole_frame", "no_bright_region"}
    tiny = np.full((400, 300), 30, np.uint8)
    tiny[10:40, 10:40] = 240
    assert crop.find_quad(tiny).reason == "too_small"


def test_round_shapes_fail():
    image = np.full((400, 400), 30, np.uint8)
    yy, xx = np.mgrid[:400, :400]
    image[(yy - 200) ** 2 + (xx - 200) ** 2 < 150**2] = 240
    assert crop.find_quad(image).reason == "not_four_sided"


def test_wide_triangle_fails():
    image = np.full((400, 400), 30, np.uint8)
    for row in range(100, 300):
        half = (row - 100) * 4 // 5
        image[row, 200 - half : 200 + half] = 240
    assert crop.find_quad(image).quad is None


def test_low_contrast_fails():
    image = np.full((400, 400), 120, np.uint8)
    image[80:320, 120:280] = 135
    assert crop.find_quad(image).reason == "low_contrast"
