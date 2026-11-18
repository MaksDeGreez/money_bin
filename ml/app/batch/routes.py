"""The `/ocr/batches` endpoints. The service keeps no state: every call asks OpenRouter.

- `GET    /ocr/batches/capability`      whether batch mode can be used now, and why not
- `POST   /ocr/batches/estimate`        a rough cost for N receipts with M photos
- `POST   /ocr/batches`                 multipart: `manifest` (JSON) and the `images` parts
- `GET    /ocr/batches/{id}`            status, counts, cost so far, expiry
- `GET    /ocr/batches/{id}/results`    per key: a receipt in `/ocr`'s shape, or an error
- `DELETE /ocr/batches/{id}`            delete a finished batch at OpenRouter

Every endpoint but `capability` refuses (501) unless batch mode is allowed
(`OPENROUTER_BATCH_ALLOW_RETENTION=true`) on the openrouter backend.
"""

from collections.abc import Awaitable, Callable
from typing import Annotated

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import TypeAdapter, ValidationError

from app.backends.base import Backend, BackendNotImplementedError, ImageInput
from app.batch.base import BatchReceipt, BatchResults, BatchStatus, OcrBatches
from app.batch.openrouter import MAX_RECEIPTS, MAX_UPLOAD_BYTES
from app.batch.schemas import (
    BatchCapabilityResponse,
    BatchDeletionResponse,
    BatchEstimateRequest,
    BatchEstimateResponse,
    BatchItemError,
    BatchManifestEntry,
    BatchOcr,
    BatchRequestCounts,
    BatchResultCounts,
    BatchResultItem,
    BatchResultsResponse,
    BatchStatusResponse,
)
from app.errors import ApiError
from app.schemas import ErrorDetail

ReadImages = Callable[[list[UploadFile], int], Awaitable[list[ImageInput]]]
_MANIFEST = TypeAdapter(list[BatchManifestEntry])


def _batches(request: Request) -> tuple[Backend, OcrBatches]:
    backend: Backend = request.app.state.backend
    return backend, backend.batches()


def status_response(status: BatchStatus) -> BatchStatusResponse:
    error = (
        ErrorDetail(code=status.error_code, message=status.error_message or "")
        if status.error_code
        else None
    )
    return BatchStatusResponse(
        id=status.id,
        state=status.state,
        provider_status=status.provider_status,
        provider=status.provider,
        model_name=status.model_name,
        requests=BatchRequestCounts(
            total=status.request_total,
            completed=status.request_completed,
            failed=status.request_failed,
        ),
        cost_usd=status.cost_usd,
        estimated_cost_usd=status.estimated_cost_usd,
        created_at=status.created_at,
        expires_at=status.expires_at,
        finished_at=status.finished_at,
        error=error,
    )


def results_response(backend: Backend, results: BatchResults) -> BatchResultsResponse:
    items = []
    parse_failed = failed = 0
    for item in results.items:
        if item.extraction is not None:
            ocr = BatchOcr(
                receipt=item.extraction.receipt,
                prompt_version=item.extraction.prompt_version,
                repaired=item.extraction.repaired,
                elapsed_seconds=None,
                backend=backend.name,
                model_name=results.status.model_name or backend.model_name,
                model_version=item.model_version or "unknown",
                mode="batch",
                batch_id=results.status.id,
                provider=item.provider,
                cost_usd=item.cost_usd,
                prompt_tokens=item.prompt_tokens,
                completion_tokens=item.completion_tokens,
                finish_reason=item.finish_reason,
            )
            items.append(
                BatchResultItem(
                    key=item.key, status="ok", ocr=ocr, error=None, cost_usd=item.cost_usd
                )
            )
            continue
        assert item.error is not None
        if item.error.code == "ocr_parse_failed":
            parse_failed += 1
        else:
            failed += 1
        error = BatchItemError(
            code=item.error.code, message=item.error.message, retry_sync=item.error.retry_sync
        )
        items.append(
            BatchResultItem(
                key=item.key, status="error", ocr=None, error=error, cost_usd=item.cost_usd
            )
        )
    return BatchResultsResponse(
        batch=status_response(results.status),
        results=items,
        counts=BatchResultCounts(
            ok=len(items) - parse_failed - failed,
            parse_failed=parse_failed,
            failed=failed,
            ignored=results.ignored,
        ),
    )


def batch_router(read_images: ReadImages, max_image_bytes: int) -> APIRouter:
    """The routes. `read_images` is the `/ocr` endpoint's own check of one receipt's photos."""
    router = APIRouter(prefix="/ocr/batches", tags=["batches"])

    @router.get("/capability")
    async def capability(request: Request) -> BatchCapabilityResponse:
        backend: Backend = request.app.state.backend
        try:
            batches = backend.batches()
        except BackendNotImplementedError as error:
            return BatchCapabilityResponse(
                available=False,
                code="backend_not_implemented",
                message=str(error),
                backend=backend.name,
                model_name=None,
                model_version=None,
                providers=[],
                max_receipts=0,
                max_upload_bytes=0,
                retention_days=30,
                prompt_price_usd=None,
                completion_price_usd=None,
            )
        found = await run_in_threadpool(batches.capability)
        return BatchCapabilityResponse(
            available=found.available,
            code=found.code,
            message=found.message,
            backend=backend.name,
            model_name=found.model_name,
            model_version=found.model_version,
            providers=list(found.providers),
            max_receipts=found.max_receipts,
            max_upload_bytes=found.max_upload_bytes,
            retention_days=found.retention_days,
            prompt_price_usd=found.prompt_price_usd,
            completion_price_usd=found.completion_price_usd,
        )

    @router.post("/estimate")
    async def estimate(request: Request, body: BatchEstimateRequest) -> BatchEstimateResponse:
        _backend, batches = _batches(request)
        found = await run_in_threadpool(batches.estimate, body.receipts, body.images)
        return BatchEstimateResponse(**found.__dict__)

    @router.post("", status_code=202)
    async def create(
        request: Request,
        manifest: Annotated[str, Form(description="JSON: [{key, images}], one per receipt.")],
        images: Annotated[list[UploadFile], File(description="The photos, receipt by receipt.")],
    ) -> BatchStatusResponse:
        _backend, batches = _batches(request)
        try:
            entries = _MANIFEST.validate_json(manifest)
        except ValidationError as error:
            raise ApiError(
                422, "validation_error", f"manifest: {error.error_count()} problem(s)"
            ) from None
        if not 1 <= len(entries) <= MAX_RECEIPTS:
            raise ApiError(
                422,
                "batch_too_many_receipts",
                f"A batch holds 1 to {MAX_RECEIPTS} receipts, got {len(entries)}.",
            )
        if sum(entry.images for entry in entries) != len(images):
            raise ApiError(
                422,
                "batch_manifest_mismatch",
                f"The manifest names {sum(entry.images for entry in entries)} photos, "
                f"but {len(images)} were sent.",
            )
        uploaded = sum(upload.size or 0 for upload in images)
        if uploaded > MAX_UPLOAD_BYTES:
            raise ApiError(
                413,
                "batch_upload_too_large",
                f"The photos add up to {uploaded} bytes, over the limit of {MAX_UPLOAD_BYTES}; "
                "send fewer receipts at once.",
            )
        receipts = []
        start = 0
        for entry in entries:
            photos = await read_images(images[start : start + entry.images], max_image_bytes)
            receipts.append(BatchReceipt(key=entry.key, images=photos))
            start += entry.images
        status = await run_in_threadpool(batches.submit, receipts)
        return status_response(status)

    @router.get("/{batch_id}")
    async def status(request: Request, batch_id: str) -> BatchStatusResponse:
        _backend, batches = _batches(request)
        return status_response(await run_in_threadpool(batches.status, batch_id))

    @router.get("/{batch_id}/results")
    async def results(request: Request, batch_id: str) -> BatchResultsResponse:
        backend, batches = _batches(request)
        found = await run_in_threadpool(batches.results, batch_id)
        return results_response(backend, found)

    @router.delete("/{batch_id}")
    async def delete(request: Request, batch_id: str) -> BatchDeletionResponse:
        _backend, batches = _batches(request)
        found = await run_in_threadpool(batches.delete, batch_id)
        return BatchDeletionResponse(
            id=found.id,
            deleted=True,
            openrouter=found.openrouter,
            upstream_provider=found.upstream_provider,
            upstream_status=found.upstream_status,
        )

    return router
