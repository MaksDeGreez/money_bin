import pytest

from app.backends import ImageInput
from app.main import detect_image_type
from app.ocr.images import ImageDecodeError, prepare_image, prepare_images
from tests.conftest import JPEG_BYTES, encoded_image


@pytest.mark.parametrize(
    ("image_format", "content_type"),
    [("JPEG", "image/jpeg"), ("PNG", "image/png"), ("WEBP", "image/webp"), ("HEIF", "image/heic")],
)
def test_every_accepted_type_decodes(image_format: str, content_type: str) -> None:
    content = encoded_image(image_format=image_format)
    assert detect_image_type(content) == content_type

    image = prepare_image(content, max_side=2048)

    assert image.size == (64, 32)
    assert image.mode == "RGB"


def test_large_images_are_scaled_to_the_longer_side() -> None:
    image = prepare_image(encoded_image(4000, 1000), max_side=2000)

    assert image.size == (2000, 500)


def test_small_images_are_never_enlarged() -> None:
    assert prepare_image(encoded_image(300, 200), max_side=2048).size == (300, 200)


def test_the_exif_orientation_is_applied() -> None:
    # Orientation 6: the camera was turned; the picture must be rotated a quarter turn.
    image = prepare_image(encoded_image(80, 40, orientation=6), max_side=2048)

    assert image.size == (40, 80)


def test_a_file_that_is_not_a_full_image_is_refused_with_its_name() -> None:
    with pytest.raises(ImageDecodeError) as error:
        prepare_image(JPEG_BYTES, max_side=2048, filename="cut.jpg")

    assert error.value.filename == "cut.jpg"
    assert str(error.value) == "File 'cut.jpg' cannot be read as an image."


def test_a_truncated_jpeg_is_refused() -> None:
    content = encoded_image(400, 400)

    with pytest.raises(ImageDecodeError):
        prepare_image(content[: len(content) // 2], max_side=2048)


def test_prepare_images_keeps_the_order() -> None:
    images = [
        ImageInput(content=encoded_image(10, 20), content_type="image/jpeg", filename="a.jpg"),
        ImageInput(content=encoded_image(30, 20), content_type="image/jpeg", filename="b.jpg"),
    ]

    assert [image.size for image in prepare_images(images, 2048)] == [(10, 20), (30, 20)]
