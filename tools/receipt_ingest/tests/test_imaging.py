import io

import numpy as np
import pillow_heif
import pytest
from PIL import Image
from support import (
    exif_bytes,
    expected_srgb_from_p3,
    jpeg_markers,
    p3_profile,
    plain_image,
    write_heic,
    write_jpeg,
)

from receipt_ingest import imaging

ALLOWED_MARKERS = {0xE0, 0xDB, 0xC0, 0xC1, 0xC2, 0xC4, 0xDD, 0xDA}


def halves() -> Image.Image:
    """40x20: red on the left, blue on the right."""
    image = Image.new("RGB", (40, 20), (0, 0, 255))
    image.paste((255, 0, 0), (0, 0, 20, 20))
    return image


def assert_bare(data: bytes) -> None:
    assert set(jpeg_markers(data)) <= ALLOWED_MARKERS
    for needle in (b"Exif", b"ICC_PROFILE", b"http://ns.adobe.com", b"GPS", b"SyntheticCam"):
        assert needle not in data
    with Image.open(io.BytesIO(data)) as image:
        assert len(image.getexif()) == 0
        assert not {"icc_profile", "xmp", "comment", "exif"} & set(image.info)


def test_all_metadata_is_gone(tmp_path):
    source = write_jpeg(
        tmp_path / "in.jpg",
        plain_image(),
        exif=exif_bytes(orientation=1, gps=True, thumbnail=True),
        icc=p3_profile(),
        extras=True,
    )
    raw = source.read_bytes()
    # The input really carries EXIF (with GPS and a thumbnail), ICC, XMP and a comment.
    assert {0xE1, 0xE2, 0xFE} <= set(jpeg_markers(raw))
    assert raw.count(b"\xff\xd8") == 2
    with Image.open(source) as image:
        assert image.getexif().get_ifd(0x8825)
    data = imaging.encode_jpeg(imaging.decode_to_srgb(raw))
    assert_bare(data)
    with Image.open(io.BytesIO(data)) as image:
        assert image.mode == "RGB"
        assert image.size == (64, 48)


def test_colours_are_converted_from_p3_to_srgb(tmp_path):
    colour = (200, 100, 60)
    picture = plain_image(color=colour)
    source = write_jpeg(tmp_path / "p3.jpg", picture, icc=p3_profile(), quality=100)
    converted = np.array(imaging.decode_to_srgb(source.read_bytes()))[24, 32].astype(float)
    expected = expected_srgb_from_p3(colour)
    assert np.all(np.abs(converted - expected) <= 3), (converted, expected)
    assert np.max(np.abs(converted - np.array(colour))) >= 10


def test_without_a_profile_pixels_stay_as_they_are(tmp_path):
    colour = (200, 100, 60)
    source = write_jpeg(tmp_path / "plain.jpg", plain_image(color=colour), quality=100)
    converted = np.array(imaging.decode_to_srgb(source.read_bytes()))[24, 32].astype(float)
    assert np.all(np.abs(converted - np.array(colour)) <= 2)


def test_a_broken_profile_is_ignored(tmp_path):
    source = write_jpeg(tmp_path / "bad.jpg", plain_image(), icc=b"not a profile at all" * 10)
    assert imaging.decode_to_srgb(source.read_bytes()).mode == "RGB"


def test_greyscale_input_becomes_rgb(tmp_path):
    source = tmp_path / "grey.jpg"
    Image.new("L", (10, 10), 128).save(source, "JPEG")
    assert imaging.decode_to_srgb(source.read_bytes()).mode == "RGB"


def assert_upright(image: Image.Image) -> None:
    # Orientation 6 means "rotate 90 degrees clockwise to view": the left half ends up on top.
    assert image.size == (20, 40)
    top = image.getpixel((10, 5))
    bottom = image.getpixel((10, 35))
    assert top[0] > 200 and top[2] < 60
    assert bottom[2] > 200 and bottom[0] < 60


def test_jpeg_orientation_is_applied_once(tmp_path):
    source = write_jpeg(tmp_path / "rot.jpg", halves(), exif=exif_bytes(orientation=6))
    assert_upright(imaging.decode_to_srgb(source.read_bytes()))


def heic_supported() -> bool:
    return bool(pillow_heif.libheif_info().get("HEIF"))


@pytest.mark.skipif(not heic_supported(), reason="this libheif build has no HEIC encoder")
def test_heic_orientation_is_applied_once(tmp_path):
    source = write_heic(tmp_path / "rot.heic", halves(), exif=exif_bytes(orientation=6))
    picture = imaging.decode_to_srgb(source.read_bytes())
    assert_upright(picture)
    assert_bare(imaging.encode_jpeg(picture))


def test_verify_refuses_metadata_and_junk():
    buffer = io.BytesIO()
    plain_image().save(buffer, "JPEG", comment=b"hello")
    with pytest.raises(imaging.MetadataLeftError, match="0xFE"):
        imaging.verify_bare_jpeg(buffer.getvalue())
    with pytest.raises(imaging.MetadataLeftError, match="not a JPEG"):
        imaging.verify_bare_jpeg(b"GIF89a")
    clean = imaging.encode_jpeg(plain_image())
    with pytest.raises(imaging.MetadataLeftError, match="after the end"):
        imaging.verify_bare_jpeg(clean + b"trailer")
    with pytest.raises(imaging.MetadataLeftError, match="no end-of-image"):
        imaging.verify_bare_jpeg(clean[:-2])
    with pytest.raises(imaging.MetadataLeftError, match="between segments"):
        imaging.verify_bare_jpeg(clean[:2] + b"\x00" + clean[2:])


def test_verify_refuses_a_jfif_thumbnail():
    clean = imaging.encode_jpeg(plain_image())
    assert clean[2:4] == b"\xff\xe0"
    length = int.from_bytes(clean[4:6], "big")
    app0 = bytearray(clean[6 : 4 + length])
    app0[12] = 1
    app0[13] = 1
    thumb = bytes(app0) + b"\x00\x00\x00"
    patched = clean[:4] + (len(thumb) + 2).to_bytes(2, "big") + thumb + clean[4 + length :]
    with pytest.raises(imaging.MetadataLeftError, match="thumbnail"):
        imaging.verify_bare_jpeg(patched)
    not_jfif = clean[:6] + b"JFXX\x00" + clean[11:]
    with pytest.raises(imaging.MetadataLeftError, match="plain JFIF"):
        imaging.verify_bare_jpeg(not_jfif)


def test_verify_accepts_progressive_and_restart_markers():
    buffer = io.BytesIO()
    Image.effect_noise((64, 64), 40).convert("RGB").save(buffer, "JPEG", progressive=True)
    imaging.verify_bare_jpeg(buffer.getvalue())
    buffer = io.BytesIO()
    Image.effect_noise((64, 64), 40).convert("RGB").save(buffer, "JPEG", restart_marker_blocks=1)
    imaging.verify_bare_jpeg(buffer.getvalue())


def test_verify_refuses_a_too_big_file(monkeypatch):
    monkeypatch.setattr(imaging, "MAX_IMAGE_BYTES", 100)
    with pytest.raises(imaging.MetadataLeftError, match="too big"):
        imaging.encode_jpeg(plain_image())


def test_thumbnail_is_small_and_bare():
    data = imaging.thumbnail(Image.new("RGB", (800, 400), (1, 2, 3)))
    assert_bare(data)
    with Image.open(io.BytesIO(data)) as image:
        assert image.size == (320, 160)
