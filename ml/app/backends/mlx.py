"""Placeholder for a local vision model that runs with Apple MLX.

In a later phase this backend will load a vision-language model on the local
machine, read receipts from the images and suggest categories for item texts.
Today every method raises `BackendNotImplementedError`.
"""

from collections.abc import Sequence

from app.backends.base import Backend, BackendNotImplementedError, ImageInput
from app.schemas import CategoriseResult, Receipt


class MlxBackend(Backend):
    name = "mlx"
    model_name = "mlx-placeholder"
    categoriser_model_name = "mlx-placeholder"
    model_version = "0.0.0"

    def extract_receipt(self, images: Sequence[ImageInput]) -> Receipt:
        raise BackendNotImplementedError("The mlx backend cannot read receipts yet.")

    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        raise BackendNotImplementedError("The mlx backend cannot categorise items yet.")
