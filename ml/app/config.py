"""Service settings, read from environment variables."""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """All settings of the service.

    Each field maps to an environment variable with the same name in upper case.
    For example, `ocr_backend` is read from `OCR_BACKEND`.
    """

    ocr_backend: str = "stub"
