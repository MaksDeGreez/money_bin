"""The real `VisionGenerator`: a vision-language model run by mlx-vlm.

Import and use this module only on the mlx backend's worker thread (see
`app.backends.mlx`): mlx-vlm creates a thread-local MLX stream when it is
imported, and the model must run on the thread that owns it.

mlx-vlm is installed only on macOS on Apple silicon (the `mlx` dependency
group). The tests never import this module; it is left out of the coverage
measurement in `pyproject.toml`.

The loaded models are kept in one place (`acquire_model`, `release_model`), so
the OCR backend and the item categoriser (`app.categorise.mlx_token_model`)
share a model when they name the same one: one copy in memory.
"""

from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from PIL.Image import Image

from app.backends.mlx import Generation, weights_revision

try:
    import mlx.core as mx
    from mlx_vlm import clear_mlx_streams, generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.structured import build_json_schema_logits_processor
    from mlx_vlm.utils import get_model_path
except ImportError as error:
    raise RuntimeError(
        "OCR_BACKEND=mlx needs mlx-vlm, which runs only on macOS on Apple silicon. "
        "Install it with `uv sync` in ml/."
    ) from error


# Loaded models by id: [model, processor, revision, users]. Touched only on the worker thread.
_LOADED: dict[str, list[Any]] = {}


def acquire_model(model_id: str) -> tuple[Any, Any, str]:
    """The model, its processor and its weights revision, loaded once per id.

    The cache is tried first, so a service whose model is already downloaded
    starts without contacting the Hugging Face Hub.
    """
    entry = _LOADED.get(model_id)
    if entry is None:
        try:
            path = get_model_path(model_id, local_files_only=True)
        except Exception:
            path = get_model_path(model_id)
        model, processor = load(str(path))
        entry = [model, processor, weights_revision(Path(path)), 0]
        _LOADED[model_id] = entry
    entry[3] += 1
    return entry[0], entry[1], entry[2]


def release_model(model_id: str) -> None:
    """One user less; the last one drops the model and this thread's MLX streams and cache."""
    entry = _LOADED.get(model_id)
    if entry is not None:
        entry[3] -= 1
        if entry[3] <= 0:
            del _LOADED[model_id]
    if not _LOADED:
        clear_mlx_streams()
    mx.clear_cache()


class MlxVlmGenerator:
    def __init__(self, model: Any, processor: Any, model_name: str, model_version: str) -> None:
        self._model = model
        self._processor = processor
        self._tokenizer = getattr(processor, "tokenizer", processor)
        self.model_name = model_name
        self.model_version = model_version

    @classmethod
    def load(cls, model_id: str) -> "MlxVlmGenerator":
        """Load the model (or share the one already loaded under this id)."""
        model, processor, revision = acquire_model(model_id)
        return cls(model, processor, model_id, revision)

    def generate(
        self,
        messages: Sequence[Mapping[str, str]],
        images: Sequence[Image],
        *,
        schema: Mapping[str, Any] | None,
        max_tokens: int,
    ) -> Generation:
        prompt = apply_chat_template(
            self._processor,
            self._model.config,
            [dict(message) for message in messages],
            num_images=len(images),
        )
        extra: dict[str, Any] = {}
        if schema is not None:
            # A fresh processor per answer: it keeps the parser state of one generation.
            extra["logits_processors"] = [
                build_json_schema_logits_processor(self._tokenizer, dict(schema))
            ]
        mx.reset_peak_memory()
        try:
            result = generate(
                self._model,
                self._processor,
                prompt,
                image=list(images),
                max_tokens=max_tokens,
                temperature=0.0,
                verbose=False,
                **extra,
            )
        finally:
            # Return the cached buffers of this answer to the system between receipts.
            mx.clear_cache()
        return Generation(
            text=result.text,
            prompt_tokens=result.prompt_tokens,
            generation_tokens=result.generation_tokens,
            peak_memory_gb=round(float(result.peak_memory), 3),
            finish_reason=result.finish_reason,
        )

    def close(self) -> None:
        """Drop the model; the last user releases this (the worker) thread's MLX streams."""
        self._model = self._processor = self._tokenizer = None
        release_model(self.model_name)
