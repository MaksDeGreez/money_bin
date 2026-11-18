"""OCR backend registry. The backend is chosen by name, from the `OCR_BACKEND` setting."""

from app.backends.base import (
    Backend,
    BackendConfigError,
    BackendError,
    BackendNotImplementedError,
    Extraction,
    ImageInput,
)
from app.backends.mlx import MlxBackend
from app.backends.mlx_worker import MlxWorker
from app.backends.openrouter import OpenRouterBackend
from app.backends.stub import StubBackend
from app.config import Settings

BACKENDS: dict[str, type[Backend]] = {
    StubBackend.name: StubBackend,
    MlxBackend.name: MlxBackend,
    OpenRouterBackend.name: OpenRouterBackend,
}


class UnknownBackendError(ValueError):
    """Raised at startup when `OCR_BACKEND` names no known backend."""


def create_backend(
    name: str, settings: Settings | None = None, worker: MlxWorker | None = None
) -> Backend:
    """Build the backend with this name, or fail with a list of the valid names.

    Building is cheap: a backend that loads a model does it in `start()`.
    `worker` is the MLX worker thread to share with an MLX categoriser.
    """
    key = name.strip().lower()
    try:
        backend_class = BACKENDS[key]
    except KeyError:
        valid = ", ".join(sorted(BACKENDS))
        raise UnknownBackendError(f"Unknown OCR_BACKEND {name!r}. Valid names: {valid}.") from None
    if backend_class is MlxBackend:
        return MlxBackend(settings, worker=worker)
    return backend_class(settings)


__all__ = [
    "BACKENDS",
    "Backend",
    "BackendConfigError",
    "BackendError",
    "BackendNotImplementedError",
    "Extraction",
    "ImageInput",
    "UnknownBackendError",
    "create_backend",
]
