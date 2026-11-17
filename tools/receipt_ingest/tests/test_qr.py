import io

import cv2
import numpy as np
import pytest
from PIL import Image
from support import OTHER_URL, TAX_URL, page_with_qr, qr_array

from receipt_ingest import qr


def grey(image: Image.Image) -> np.ndarray:
    return np.array(image.convert("L"))


def jpeg(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=90)
    return buffer.getvalue()


def test_small_qr_in_a_large_page():
    page = page_with_qr(TAX_URL, size=(2400, 3200), scale=3)
    result = qr.decode_jpeg(jpeg(page))
    assert result.payloads == [TAX_URL]
    assert sum(result.hits.values()) == 1


def test_rotated_qr():
    page = page_with_qr(TAX_URL, size=(900, 900), scale=5).rotate(
        30, fillcolor=(255, 255, 255), expand=False
    )
    assert qr.decode_image(grey(page)).payloads == [TAX_URL]


def test_tax_url_stops_the_cascade_and_wins_over_another_code():
    page = page_with_qr(OTHER_URL, size=(900, 1200), scale=5, at=(40, 40))
    page.paste(page_with_qr(TAX_URL, size=(500, 500), scale=4, at=(20, 20)), (380, 650))
    result = qr.decode_image(grey(page))
    assert TAX_URL in result.payloads
    assert len(result.hits) == 1  # found by the first strategy, nothing else ran
    summary = qr.receipt_qr([result])
    assert summary["payload"] == TAX_URL
    assert summary["flags"] == []
    assert summary["part"] == 1


def test_other_code_only_runs_every_strategy():
    result = qr.decode_image(grey(page_with_qr(OTHER_URL, size=(600, 600), scale=4)))
    assert result.payloads == [OTHER_URL]
    assert set(result.seconds) == {name for name, _ in qr.CASCADE}
    summary = qr.receipt_qr([result])
    assert summary["payload"] == OTHER_URL
    assert summary["flags"] == ["qr_not_tax_url"]


def test_no_qr():
    result = qr.decode_image(np.full((300, 300), 255, np.uint8))
    assert result.payloads == []
    summary = qr.receipt_qr([result, result])
    assert summary == {"payload": None, "strategy": None, "part": None, "flags": ["no_qr"]}


def found(*pairs):
    return qr.ImageResult(list(pairs), {}, {})


def test_receipt_rules_across_parts():
    second_tax = TAX_URL.replace("id=123456", "id=654321")
    summary = qr.receipt_qr([found((OTHER_URL, "a")), found((TAX_URL, "b"))])
    assert (summary["payload"], summary["part"], summary["strategy"]) == (TAX_URL, 2, "b")
    assert summary["flags"] == []
    conflict = qr.receipt_qr([found((TAX_URL, "a")), found((second_tax, "b"))])
    assert conflict["payload"] == TAX_URL
    assert conflict["flags"] == ["qr_conflict"]
    others = qr.receipt_qr([found(("x", "a")), found(("y", "a"))])
    assert others["payload"] == "x"
    assert others["flags"] == ["qr_not_tax_url", "qr_conflict"]
    same = qr.receipt_qr([found((TAX_URL, "a")), found((TAX_URL, "b"))])
    assert same["flags"] == []


def test_region_rescue_reads_a_faded_code():
    """A code with white holes in its dark modules, which a minimum filter fills."""
    code = qr_array(TAX_URL, scale=6)
    faded = code.copy()
    rng = np.random.default_rng(7)
    dark = faded < 128
    holes = dark & (rng.random(faded.shape) < 0.35)
    faded[holes] = 255
    faded[dark & ~holes] = 150
    page = np.full((faded.shape[0] + 200, faded.shape[1] + 200), 235, np.uint8)
    page[100:-100, 100:-100] = faded
    context = qr.Context(page)
    context.regions.append((100, 100, 100 + faded.shape[1], 100 + faded.shape[0]))
    assert qr.region_rescue(context) == [TAX_URL]


def test_region_memory_ignores_noise_and_repeats():
    context = qr.Context(np.zeros((10, 10), np.uint8))

    class Point:
        def __init__(self, x, y):
            self.x, self.y = x, y

    class Position:
        def __init__(self, x0, y0, side):
            self.top_left = Point(x0, y0)
            self.top_right = Point(x0 + side, y0)
            self.bottom_right = Point(x0 + side, y0 + side)
            self.bottom_left = Point(x0, y0 + side)

    qr._remember_region(context, Position(0, 0, 10), 1.0)  # too small
    qr._remember_region(context, Position(100, 100, 50), 0.5)
    qr._remember_region(context, Position(201, 199, 100), 1.0)  # the same place again
    for start in range(1000, 6000, 1000):
        qr._remember_region(context, Position(start, start, 100), 1.0)
    assert context.regions[0] == (200, 200, 300, 300)
    assert len(context.regions) == qr.MAX_REGIONS


def test_decode_jpeg_refuses_junk():
    with pytest.raises(ValueError, match="not an image"):
        qr.decode_jpeg(b"junk")


def test_strategies_on_derived_copies_are_built_once():
    context = qr.Context(np.full((200, 200), 255, np.uint8))
    assert context.clahe_half is context.clahe_half
    assert context.half.shape == (100, 100)
    assert cv2.countNonZero(context.clahe_full) > 0
