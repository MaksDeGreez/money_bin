"""The interface that every backend implements."""

from abc import ABC, abstractmethod
from collections.abc import Sequence
from dataclasses import dataclass

from app.schemas import CategoriseResult, Receipt


class BackendNotImplementedError(NotImplementedError):
    """Raised by a backend that is not ready yet. The API answers with HTTP 501."""


@dataclass(frozen=True)
class ImageInput:
    """One uploaded receipt image, already checked by the API layer."""

    content: bytes
    content_type: str
    filename: str | None = None


class Backend(ABC):
    """A model backend for receipt OCR and item categorisation.

    One backend serves both tasks. A single vision-language model (local or
    hosted) can do both, so one interface keeps the selection simple.

    `model_name` is the OCR model. It is reported by `/health` and `/ocr`.
    `categoriser_model_name` is reported by `/categorise`. A backend that uses
    one model for both tasks sets the same value twice. Both share
    `model_version`.
    """

    name: str
    model_name: str
    categoriser_model_name: str
    model_version: str

    @abstractmethod
    def extract_receipt(self, images: Sequence[ImageInput]) -> Receipt:
        """Read one receipt from 1 to 3 images (pages or parts of the same receipt)."""

    @abstractmethod
    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        """Suggest categories for each text. Results keep the order of `texts`."""
