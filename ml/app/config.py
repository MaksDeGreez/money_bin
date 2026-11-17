"""Service settings, read from environment variables."""

from pydantic import Field
from pydantic_settings import BaseSettings

DEFAULT_MAX_IMAGE_BYTES = 15 * 1024 * 1024


class Settings(BaseSettings):
    """All settings of the service.

    Each field maps to an environment variable with the same name in upper case.
    For example, `ocr_backend` is read from `OCR_BACKEND`.
    """

    ocr_backend: str = "stub"
    # The largest accepted image file, in bytes (`ML_MAX_IMAGE_BYTES`). A phone
    # photo is a few megabytes; 15 MB leaves room for a large HEIC or PNG scan.
    ml_max_image_bytes: int = Field(default=DEFAULT_MAX_IMAGE_BYTES, gt=0)
