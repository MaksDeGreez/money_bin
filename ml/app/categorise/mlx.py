"""The local item categoriser: a language model run with Apple MLX.

It scores every listed category for every item (`app.categorise.labels`), so
the confidence is the model's own probability of the category, renormalised
over the listed categories. The receipt's items go in one chat, with the shop's
name as context.

The model is `MLX_CATEGORISE_MODEL`, or `MLX_OCR_MODEL` when that is empty. It
runs on the MLX worker thread it shares with the OCR backend
(`app.backends.mlx_worker`); when the two name the same model, it is loaded
once (`app.backends.mlx_vlm_generator`). The model sits behind the
`TokenModel` protocol, so the tests use a fake; the real one is
`app.categorise.mlx_token_model`, imported only on the worker thread.
"""

import logging
import threading
import time
from collections.abc import Callable

from app.backends.mlx_worker import MlxWorker
from app.categorise.base import (
    Categorisation,
    CategoriseInput,
    Categoriser,
    slugs_of,
    top_candidates,
)
from app.categorise.labels import TokenModel, score_items
from app.categorise.prompt import PROMPT_VERSION, local_messages
from app.config import Settings

logger = logging.getLogger(__name__)

TokenModelLoader = Callable[[str], TokenModel]


def load_token_model(model_id: str) -> TokenModel:  # pragma: no cover - needs MLX
    """Load the real model with mlx-vlm. Runs on the worker thread."""
    from app.categorise.mlx_token_model import MlxTokenModel

    return MlxTokenModel.load(model_id)


def categorise_model_id(settings: Settings) -> str:
    """The model that categorises: MLX_CATEGORISE_MODEL, or MLX_OCR_MODEL when it is empty."""
    configured = (settings.mlx_categorise_model or "").strip()
    return configured or settings.mlx_ocr_model


class MlxCategoriser(Categoriser):
    name = "mlx"

    def __init__(
        self,
        settings: Settings | None = None,
        loader: TokenModelLoader | None = None,
        worker: MlxWorker | None = None,
    ) -> None:
        super().__init__(settings)
        self._loader = loader or load_token_model
        self._worker = worker or MlxWorker()
        self.model_name = categorise_model_id(self.settings)
        self.model_version = "not-loaded"
        self._lock = threading.Lock()
        self._model: TokenModel | None = None

    def start(self) -> None:
        """Load the model on the worker thread. Safe to call more than once."""
        with self._lock:
            if self._model is not None:
                return
            self._worker.acquire()
            try:
                model = self._worker.run(self._loader, self.model_name)
            except BaseException:
                self._worker.release()
                raise
            self._model = model
            self.model_version = model.model_version

    def stop(self) -> None:
        with self._lock:
            model, self._model = self._model, None
        if model is None:
            return
        try:
            self._worker.run(model.close)
        except Exception:
            logger.exception("Releasing the MLX categoriser model failed")
        finally:
            self._worker.release()

    def categorise(self, request: CategoriseInput) -> Categorisation:
        self.start()
        model = self._model
        if model is None:
            raise RuntimeError("The mlx categoriser was stopped.")
        slugs = slugs_of(request.categories)
        messages = local_messages(request.categories, request.texts, request.merchant)
        started = time.perf_counter()
        probabilities, stats = self._worker.run(
            score_items, model, messages, slugs, len(request.texts)
        )
        candidates = [
            top_candidates(dict(zip(slugs, values, strict=True))) for values in probabilities
        ]
        return Categorisation(
            candidates=candidates,
            score_kind="label_probability",
            prompt_version=PROMPT_VERSION,
            diagnostics={
                "model_calls": stats.model_calls,
                "prompt_tokens": stats.prompt_tokens,
                "seconds": round(time.perf_counter() - started, 3),
            },
        )
