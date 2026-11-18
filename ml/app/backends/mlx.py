"""The local OCR backend: a Qwen vision-language model run with Apple MLX.

The model is loaded once, when the service starts, and stays in memory.

Every MLX call runs on the one worker thread of `app.backends.mlx_worker`
(MLX keeps its GPU streams per thread): it loads the model and runs every
generation; a request hands its work to that thread and waits. One generation
runs at a time. With CATEGORISE_BACKEND=mlx the item categoriser shares the
worker, and the model when it is the same one.

The model call sits behind the small `VisionGenerator` protocol, so the tests
use a fake generator and need neither MLX nor model weights. The real one is
`app.backends.mlx_vlm_generator`, imported only on the worker thread.

The prompt, the parsing with its repair pass and the post-processing are the
shared modules in `app.ocr`; this backend only runs the model.
"""

import logging
import threading
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from PIL.Image import Image

from app.backends.base import Backend, Extraction, ImageInput
from app.backends.mlx_worker import WORKER_THREAD_NAME, MlxWorker
from app.config import Settings
from app.ocr.images import prepare_images
from app.ocr.parsing import OcrParseError, read_with_repair
from app.ocr.postprocess import postprocess
from app.ocr.prompt import ANSWER_SCHEMA, PROMPT_VERSION, Repair, build_messages

__all__ = ["WORKER_THREAD_NAME", "Generation", "MlxBackend", "VisionGenerator", "weights_revision"]

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class Generation:
    """One answer of the model and its cost."""

    text: str
    prompt_tokens: int = 0
    generation_tokens: int = 0
    peak_memory_gb: float = 0.0
    finish_reason: str | None = None


class VisionGenerator(Protocol):
    """A loaded vision-language model. Used only from the worker thread."""

    model_name: str
    model_version: str

    def generate(
        self,
        messages: Sequence[Mapping[str, str]],
        images: Sequence[Image],
        *,
        schema: Mapping[str, Any] | None,
        max_tokens: int,
    ) -> Generation:
        """Answer the chat `messages` about `images` (attached to the user message).

        With a `schema`, the answer's tokens are constrained to that JSON schema.
        Sampling is greedy (temperature 0), so the same input gives the same answer.
        """
        ...  # pragma: no cover

    def close(self) -> None:
        """Release the model and this thread's MLX streams. Runs on the worker thread."""
        ...  # pragma: no cover


GeneratorLoader = Callable[[Settings], VisionGenerator]


def weights_revision(model_path: Path) -> str:
    """The Hugging Face commit of the weights, or "local" for a plain folder.

    A model from the Hugging Face cache lives in `.../snapshots/<commit>/`.
    """
    if model_path.parent.name == "snapshots":
        return model_path.name
    return "local"


def load_mlx_vlm(settings: Settings) -> VisionGenerator:  # pragma: no cover - needs MLX
    """Load the real model with mlx-vlm. Runs on the worker thread."""
    from app.backends.mlx_vlm_generator import MlxVlmGenerator

    return MlxVlmGenerator.load(settings.mlx_ocr_model)


class MlxBackend(Backend):
    name = "mlx"

    def __init__(
        self,
        settings: Settings | None = None,
        loader: GeneratorLoader | None = None,
        worker: MlxWorker | None = None,
    ):
        super().__init__(settings)
        self._loader = loader or load_mlx_vlm
        self._worker = worker or MlxWorker()
        self.model_name = self.settings.mlx_ocr_model
        # The weights revision is known once the model is loaded.
        self.model_version = "not-loaded"
        self._lock = threading.Lock()
        self._generator: VisionGenerator | None = None

    def start(self) -> None:
        """Start the worker thread and load the model on it. Waits until it is loaded.

        Safe to call more than once. A failed load (mlx-vlm missing, unknown
        model) raises here, so the service does not start half-working.
        """
        with self._lock:
            if self._generator is not None:
                return
            self._worker.acquire()
            try:
                generator = self._worker.run(self._loader, self.settings)
            except BaseException:
                self._worker.release()
                raise
            self._generator = generator
            self.model_name = generator.model_name
            self.model_version = generator.model_version

    def stop(self) -> None:
        """Finish the queued work, release the model on the worker thread, then stop it.

        MLX streams belong to the thread that made them, so only the worker can
        release its own; mlx-vlm's exit hook runs on the main thread.
        """
        with self._lock:
            generator, self._generator = self._generator, None
        if generator is None:
            return
        try:
            self._worker.run(generator.close)
        except Exception:
            logger.exception("Releasing the MLX model failed")
        finally:
            self._worker.release()

    def _generate(self, messages: list[dict[str, str]], images: Sequence[Image]) -> Generation:
        generator = self._generator
        if generator is None:
            raise RuntimeError("The mlx backend was stopped.")
        schema = ANSWER_SCHEMA if self.settings.mlx_ocr_constrained_decoding else None
        return self._worker.run(
            generator.generate,
            messages,
            images,
            schema=schema,
            max_tokens=self.settings.mlx_ocr_max_tokens,
        )

    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        self.start()
        pictures = prepare_images(images, self.settings.mlx_ocr_image_max_side)
        generations: list[Generation] = []

        def ask(repair: Repair | None) -> str:
            generation = self._generate(build_messages(len(pictures), repair), pictures)
            generations.append(generation)
            return generation.text

        try:
            parsed = read_with_repair(ask)
        except OcrParseError as error:
            error.diagnostics.update(_generation_stats(generations))
            raise
        receipt, report = postprocess(parsed.receipt)
        return Extraction(
            receipt=receipt,
            prompt_version=PROMPT_VERSION,
            repaired=parsed.repaired,
            diagnostics={**_generation_stats(generations), "postprocess": report.as_dict()},
        )


def _generation_stats(generations: Sequence[Generation]) -> dict[str, Any]:
    """Token counts and memory of the model calls. Never the answer text."""
    return {
        "model_calls": len(generations),
        "prompt_tokens": sum(g.prompt_tokens for g in generations),
        "generation_tokens": sum(g.generation_tokens for g in generations),
        "peak_memory_gb": max((g.peak_memory_gb for g in generations), default=0.0),
        "finish_reasons": [g.finish_reason for g in generations],
    }
