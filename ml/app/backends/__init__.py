"""Backend registry. The backend is chosen by name, from the `OCR_BACKEND` setting."""

from app.backends.base import Backend, BackendNotImplementedError, ImageInput
from app.backends.mlx import MlxBackend
from app.backends.openrouter import OpenRouterBackend
from app.backends.stub import StubBackend

BACKENDS: dict[str, type[Backend]] = {
    StubBackend.name: StubBackend,
    MlxBackend.name: MlxBackend,
    OpenRouterBackend.name: OpenRouterBackend,
}


class UnknownBackendError(ValueError):
    """Raised at startup when `OCR_BACKEND` names no known backend."""


def create_backend(name: str) -> Backend:
    """Build the backend with this name, or fail with a list of the valid names."""
    key = name.strip().lower()
    try:
        backend_class = BACKENDS[key]
    except KeyError:
        valid = ", ".join(sorted(BACKENDS))
        raise UnknownBackendError(f"Unknown OCR_BACKEND {name!r}. Valid names: {valid}.") from None
    return backend_class()


__all__ = [
    "BACKENDS",
    "Backend",
    "BackendNotImplementedError",
    "ImageInput",
    "UnknownBackendError",
    "create_backend",
]
