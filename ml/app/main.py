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
from app.backends.mlx_worker import MlxWorker
from app.categorise import CategoriseInput, Categoriser, create_categoriser
from app.categorise.calibration import Calibration, CalibrationError, calibrate, load_calibration
from app.categorise.prompt import categories_version
from app.categorise.taxonomy import parse_categories
from app.config import Settings
from app.decimals import exact_sum
from app.errors import ApiError, register_error_handlers
from app.schemas import (
    CategoriseRequest,
    CategoriseResponse,
    CategoriseResult,
    CategoriserInfo,
    CategoryCandidate,
    ErrorResponse,
    HealthResponse,
    OcrResponse,
)
from app.transactions import TransactionCategoriser
from app.transactions import router as transactions_router

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


def get_categoriser(request: Request) -> Categoriser:
    categoriser: Categoriser = request.app.state.categoriser
    return categoriser


CategoriserDep = Annotated[Categoriser, Depends(get_categoriser)]


def check_calibration(calibration: Calibration, categoriser: Categoriser) -> None:
    """A calibration fitted for another backend or model stops the service at start-up.

    The prompt version and the score kind are compared per answer (an answer
    of another kind is reported as not calibrated).
    """
    if (calibration.backend, calibration.model_name) != (
        categoriser.name,
        categoriser.model_name,
    ):
        raise CalibrationError(
            "CATEGORISE_CALIBRATION_FILE was fitted for "
            f"{calibration.backend} {calibration.model_name!r}, not for "
            f"{categoriser.name} {categoriser.model_name!r}: fit one for this model or unset it."
        )


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


def create_app(
    settings: Settings | None = None,
    backend: Backend | None = None,
    categoriser: Categoriser | None = None,
    transaction_categoriser: TransactionCategoriser | None = None,
) -> FastAPI:
    """Build the app. An unknown backend name fails here, before the server starts.

    `backend` replaces the OCR backend named by `settings.ocr_backend`, and
    `categoriser` the one named by `settings.categorise_backend` (the tests
    pass ones with fake models). With both on MLX they share one worker thread
    (and one model, when they name the same). Their `start()` runs when the
    server starts (a model is loaded then, so the first request is not slow and
    a broken setup stops the service at once) and `stop()` when it shuts down.
    A calibration file is read and checked at start-up too. The transaction
    categoriser (`app.transactions`) loads lazily, on its first request.
    """
    settings = settings or Settings()
    worker = MlxWorker()
    backend = backend or create_backend(settings.ocr_backend, settings, worker=worker)
    categoriser = categoriser or create_categoriser(
        settings.categorise_backend, settings, worker=worker
    )
    max_image_bytes = settings.ml_max_image_bytes
    calibration_file = settings.categorise_calibration_file

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await run_in_threadpool(backend.start)
        try:
            await run_in_threadpool(categoriser.start)
            try:
                if calibration_file is not None:
                    calibration = load_calibration(calibration_file)
                    check_calibration(calibration, categoriser)
                    app.state.calibration = calibration
                yield
            finally:
                await run_in_threadpool(categoriser.stop)
        finally:
            await run_in_threadpool(backend.stop)

    app = FastAPI(
        title="money_bin ML service",
        version="0.1.0",
        summary="Receipt OCR and item categorisation.",
        lifespan=lifespan,
    )
    app.state.backend = backend
    app.state.categoriser = categoriser
    app.state.calibration = None
    app.state.transaction_categoriser = transaction_categoriser or TransactionCategoriser(settings)
    app.include_router(transactions_router)
    register_error_handlers(app)

    @app.get("/health")
    def health(
        request: Request, backend: BackendDep, categoriser: CategoriserDep
    ) -> HealthResponse:
        return HealthResponse(
            backend=backend.name,
            model_name=backend.model_name,
            model_version=backend.model_version,
            categoriser=CategoriserInfo(
                backend=categoriser.name,
                model_name=categoriser.model_name,
                model_version=categoriser.model_version,
                calibration=request.app.state.calibration is not None,
            ),
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
    async def categorise(
        request: Request, categoriser: CategoriserDep, body: CategoriseRequest
    ) -> CategoriseResponse:
        # The same hand-over parser offline scripts use; the schema has already checked the shape.
        options = parse_categories(category.model_dump() for category in body.categories)
        texts = tuple(" ".join(text.split()) for text in body.texts)
        merchant = " ".join(body.merchant.split()) if body.merchant else None
        started = time.perf_counter()
        categorisation = await run_in_threadpool(
            categoriser.categorise, CategoriseInput(options, texts, merchant or None)
        )
        allowed = {option.slug for option in options}
        if len(categorisation.candidates) != len(texts) or any(
            not candidates or any(candidate.slug not in allowed for candidate in candidates)
            for candidates in categorisation.candidates
        ):
            # A categoriser must answer every item with listed slugs only.
            raise RuntimeError("the categoriser answered outside the request's categories")
        candidates, calibrated = calibrate(
            categorisation, request.app.state.calibration, categoriser.name, categoriser.model_name
        )
        cost = categorisation.diagnostics.get("cost_usd")
        return CategoriseResponse(
            results=[
                CategoriseResult(
                    text=text,
                    candidates=[
                        CategoryCandidate(category_slug=c.slug, score=round(c.score, 6))
                        for c in item_candidates
                    ],
                )
                for text, item_candidates in zip(body.texts, candidates, strict=True)
            ],
            score_kind=categorisation.score_kind,
            calibrated=calibrated,
            prompt_version=categorisation.prompt_version,
            categories_version=categories_version(options),
            elapsed_seconds=elapsed_since(started),
            cost_usd=None if cost is None else exact_sum([Decimal(cost)]),
            backend=categoriser.name,
            model_name=categoriser.model_name,
            model_version=categoriser.model_version,
        )

    return app


app = create_app()
