"""Decoding the uploaded photos for a vision model.

Each photo is decoded (JPEG, PNG, WebP or HEIC), turned upright from its EXIF
orientation, converted to RGB and scaled down so that its longer side is at
most `max_side` pixels. A phone photo has about 12 megapixels; a vision model
turns pixels into tokens, so a smaller image is much faster and, at a size
where the print stays legible, reads just as well.
"""

from collections.abc import Sequence
from io import BytesIO
from typing import TYPE_CHECKING

import pillow_heif
from PIL import Image, ImageOps

if TYPE_CHECKING:  # pragma: no cover
    from app.backends.base import ImageInput

pillow_heif.register_heif_opener()


class ImageDecodeError(ValueError):
    """An uploaded file has a valid signature but cannot be decoded as an image."""

    def __init__(self, filename: str | None) -> None:
        super().__init__(f"File {filename or 'image'!r} cannot be read as an image.")
        self.filename = filename


def prepare_image(content: bytes, max_side: int, filename: str | None = None) -> Image.Image:
    """One upright RGB image whose longer side is at most `max_side` pixels."""
    try:
        with Image.open(BytesIO(content)) as opened:
            opened.load()
            image = ImageOps.exif_transpose(opened)
            image = image.convert("RGB")
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        raise ImageDecodeError(filename) from None
    image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
    return image


def prepare_images(images: Sequence["ImageInput"], max_side: int) -> list[Image.Image]:
    """`prepare_image` for each upload, in order."""
    return [prepare_image(image.content, max_side, image.filename) for image in images]
