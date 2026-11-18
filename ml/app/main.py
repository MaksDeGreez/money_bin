"""The FastAPI application: routes for health, receipt OCR and categorisation.

Run it with `uv run uvicorn app.main:app --host 127.0.0.1 --port 8100`.
"""

import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Annotated, Any

from fastapi import Depends, FastAPI, File, Request, UploadFile
from fastapi.concurrency import run_in_threadpool

from app.backends import Backend, ImageInput, create_backend
from app.config import Settings
from app.errors import ApiError, register_error_handlers
from app.schemas import (
    CategoriseRequest,
    CategoriseResponse,
    ErrorResponse,
    HealthResponse,
    OcrResponse,
)

MAX_IMAGES = 3
ALLOWED_IMAGE_TYPES = frozenset({"image/jpeg", "image/png", "image/webp", "image/heic"})
# Major brands of the ISO base media file format that mean a HEIF/HEIC still image.
HEIF_BRANDS = frozenset(
    {
        b"heic",
        b"heix",
        b"hevc",
        b"hevx",
        b"heim",
        b"heis",
        b"hevm",
        b"hevs",
        b"mif1",
        b"msf1",
        b"heif",
    }
)

_ERRORS: dict[int | str, dict[str, Any]] = {
    status: {"model": ErrorResponse} for status in (413, 415, 422, 501)
}


def get_backend(request: Request) -> Backend:
    backend: Backend = request.app.state.backend
    return backend


BackendDep = Annotated[Backend, Depends(get_backend)]


def _content_type(upload: UploadFile) -> str:
    """The media type without parameters, in lower case (e.g. "image/png")."""
    raw = upload.content_type or ""
    return raw.split(";", 1)[0].strip().lower()


def detect_image_type(content: bytes) -> str | None:
    """The image type that the file signature (its first bytes) shows, or None."""
    if content.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if content[:4] == b"RIFF" and content[8:12] == b"WEBP":
        return "image/webp"
    if content[4:8] == b"ftyp" and content[8:12] in HEIF_BRANDS:
        return "image/heic"
    return None


def _too_large(upload: UploadFile, max_bytes: int) -> ApiError:
    return ApiError(
        413,
        "image_too_large",
        f"File {upload.filename!r} is larger than the limit of {max_bytes} bytes.",
    )


async def _read_images(uploads: list[UploadFile], max_bytes: int) -> list[ImageInput]:
    """Check the uploaded files and read them into memory.

    A request without any `images` field never gets here: FastAPI rejects it
    first with a validation error. The multipart parser has already spooled
    each file to a temporary file, so an oversized file is refused from its
    size without being read into memory, and at most `max_bytes + 1` bytes of
    any file are read.
    """
    if len(uploads) > MAX_IMAGES:
        raise ApiError(
            422, "too_many_images", f"Send at most {MAX_IMAGES} files, got {len(uploads)}."
        )
    images = []
    for upload in uploads:
        content_type = _content_type(upload)
        if content_type not in ALLOWED_IMAGE_TYPES:
            allowed = ", ".join(sorted(ALLOWED_IMAGE_TYPES))
            raise ApiError(
                415,
                "unsupported_media_type",
                f"File {upload.filename!r} has type {content_type or 'unknown'!r}. "
                f"Allowed types: {allowed}.",
            )
        if upload.size is not None and upload.size > max_bytes:
            raise _too_large(upload, max_bytes)
        content = await upload.read(max_bytes + 1)
        if len(content) > max_bytes:
            raise _too_large(upload, max_bytes)
        if not content:
            raise ApiError(422, "empty_image", f"File {upload.filename!r} is empty.")
        if detect_image_type(content) != content_type:
            raise ApiError(
                415,
                "unsupported_media_type",
                f"File {upload.filename!r} is declared as {content_type!r}, "
                "but its content is not an image of that type.",
            )
        images.append(
            ImageInput(content=content, content_type=content_type, filename=upload.filename)
        )
    return images


def elapsed_since(started: float) -> Decimal:
    """Seconds since `started` (a `time.perf_counter()` value), to the millisecond."""
    return Decimal(f"{time.perf_counter() - started:.3f}")


def create_app(settings: Settings | None = None, backend: Backend | None = None) -> FastAPI:
    """Build the app. An unknown backend name fails here, before the server starts.

    `backend` replaces the one named by `settings.ocr_backend` (the tests pass
    a backend with a fake model). The backend's `start()` runs when the server
    starts (a model is loaded then, so the first request is not slow and a
    broken setup stops the service at once) and `stop()` when it shuts down.
    """
    settings = settings or Settings()
    backend = backend or create_backend(settings.ocr_backend, settings)
    max_image_bytes = settings.ml_max_image_bytes

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await run_in_threadpool(backend.start)
        try:
            yield
        finally:
            await run_in_threadpool(backend.stop)

    app = FastAPI(
        title="money_bin ML service",
        version="0.1.0",
        summary="Receipt OCR and item categorisation.",
        lifespan=lifespan,
    )
    app.state.backend = backend
    register_error_handlers(app)

    @app.get("/health")
    def health(backend: BackendDep) -> HealthResponse:
        return HealthResponse(
            backend=backend.name,
            model_name=backend.model_name,
            model_version=backend.model_version,
        )

    @app.post("/ocr", responses=_ERRORS)
    async def ocr(
        backend: BackendDep,
        images: Annotated[
            list[UploadFile], File(description=f"1 to {MAX_IMAGES} images of one receipt.")
        ],
    ) -> OcrResponse:
        inputs = await _read_images(images, max_image_bytes)
        started = time.perf_counter()
        extraction = await run_in_threadpool(backend.extract_receipt, inputs)
        return OcrResponse(
            receipt=extraction.receipt,
            prompt_version=extraction.prompt_version,
            repaired=extraction.repaired,
            elapsed_seconds=elapsed_since(started),
            backend=backend.name,
            model_name=backend.model_name,
            model_version=backend.model_version,
        )

    @app.post("/categorise", responses=_ERRORS)
    async def categorise(backend: BackendDep, request: CategoriseRequest) -> CategoriseResponse:
        results = await run_in_threadpool(backend.categorise, request.texts)
        return CategoriseResponse(
            results=results,
            backend=backend.name,
            model_name=backend.categoriser_model_name,
            model_version=backend.model_version,
        )

    return app


app = create_app()
