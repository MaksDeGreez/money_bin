"""Placeholder for a hosted model that is called through OpenRouter.

In a later phase this backend will send the receipt images and item texts to
a hosted vision-language model and map its answer to our schemas. It will
need an API key from the environment. Today it makes no network calls, reads
no keys, and every method raises `BackendNotImplementedError`.
"""

from collections.abc import Sequence

from app.backends.base import Backend, BackendNotImplementedError, ImageInput
from app.schemas import CategoriseResult, Receipt


class OpenRouterBackend(Backend):
    name = "openrouter"
    model_name = "openrouter-placeholder"
    categoriser_model_name = "openrouter-placeholder"
    model_version = "0.0.0"

    def extract_receipt(self, images: Sequence[ImageInput]) -> Receipt:
        raise BackendNotImplementedError("The openrouter backend cannot read receipts yet.")

    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        raise BackendNotImplementedError("The openrouter backend cannot categorise items yet.")
