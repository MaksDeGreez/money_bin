"""The interface that every backend implements."""

from abc import ABC, abstractmethod
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from app.config import Settings
from app.schemas import CategoriseResult, Receipt


class BackendNotImplementedError(NotImplementedError):
    """Raised by a backend that is not ready yet. The API answers with HTTP 501."""


class BackendError(Exception):
    """A backend failure the API reports with its own status and code.

    The status tells the Rails job what to do: a 5xx other than 501 is retried
    (a rate limit, a timeout, an upstream outage), a 4xx or 501 is permanent
    (a missing setting, a refused request). `message` is short and written by
    this code: it never repeats an upstream answer, which could echo the
    request. `diagnostics` holds the accounting of the model calls made before
    the failure (tokens, cost), for the evaluation scripts.
    """

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.diagnostics: dict[str, Any] = {}

    @property
    def transient(self) -> bool:
        return self.status_code >= 500 and self.status_code != 501


class BackendConfigError(BackendError):
    """The backend cannot work with the current settings (HTTP 501, permanent)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(501, code, message)


@dataclass(frozen=True)
class ImageInput:
    """One uploaded receipt image, already checked by the API layer."""

    content: bytes
    content_type: str
    filename: str | None = None


@dataclass(frozen=True)
class Extraction:
    """What a backend read from one receipt.

    - `prompt_version`: the version of the prompt and answer schema the model
      was given (`app.ocr.prompt.PROMPT_VERSION`); None for a backend without
      a prompt.
    - `repaired`: the model's first answer was invalid and the repair pass
      fixed it.
    - `diagnostics`: numbers for the evaluation scripts (token counts, peak
      memory, post-processing counts). Never receipt content. The API does not
      return them.
    """

    receipt: Receipt
    prompt_version: str | None = None
    repaired: bool = False
    diagnostics: Mapping[str, Any] = field(default_factory=dict)


class Backend(ABC):
    """A model backend for receipt OCR and item categorisation.

    One backend serves both tasks. A single vision-language model (local or
    hosted) can do both, so one interface keeps the selection simple.

    `model_name` is the OCR model. It is reported by `/health` and `/ocr`.
    `categoriser_model_name` is reported by `/categorise`. A backend that uses
    one model for both tasks sets the same value twice. Both share
    `model_version`.

    `start()` runs when the service starts (before the first request) and
    `stop()` when it shuts down. A backend that needs no warm-up keeps the
    defaults, which do nothing.
    """

    name: str
    model_name: str
    categoriser_model_name: str
    model_version: str

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or Settings()

    def start(self) -> None:  # noqa: B027 - optional hook, empty by default
        """Prepare the backend (load a model). Called once at startup."""

    def stop(self) -> None:  # noqa: B027 - optional hook, empty by default
        """Release what `start` acquired. Called once at shutdown."""

    @abstractmethod
    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        """Read one receipt from 1 to 3 images (pages or parts of the same receipt)."""

    @abstractmethod
    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        """Suggest categories for each text. Results keep the order of `texts`."""
