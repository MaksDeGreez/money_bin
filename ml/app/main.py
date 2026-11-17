"""The FastAPI application: routes for health, receipt OCR and categorisation.

Run it with `uv run uvicorn app.main:app --host 127.0.0.1 --port 8100`.
"""

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

_ERRORS: dict[int | str, dict[str, Any]] = {
    status: {"model": ErrorResponse} for status in (415, 422, 501)
}


def get_backend(request: Request) -> Backend:
    backend: Backend = request.app.state.backend
    return backend


BackendDep = Annotated[Backend, Depends(get_backend)]


def _content_type(upload: UploadFile) -> str:
    """The media type without parameters, in lower case (e.g. "image/png")."""
    raw = upload.content_type or ""
    return raw.split(";", 1)[0].strip().lower()


async def _read_images(uploads: list[UploadFile]) -> list[ImageInput]:
    """Check the uploaded files and read them into memory.

    A request without any `images` field never gets here: FastAPI rejects it
    first with a validation error.
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
        content = await upload.read()
        if not content:
            raise ApiError(422, "empty_image", f"File {upload.filename!r} is empty.")
        images.append(
            ImageInput(content=content, content_type=content_type, filename=upload.filename)
        )
    return images


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the app. An unknown backend name fails here, before the server starts."""
    settings = settings or Settings()
    backend = create_backend(settings.ocr_backend)

    app = FastAPI(
        title="money_bin ML service",
        version="0.1.0",
        summary="Receipt OCR and item categorisation.",
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
        inputs = await _read_images(images)
        receipt = await run_in_threadpool(backend.extract_receipt, inputs)
        return OcrResponse(
            receipt=receipt,
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
