"""Request and response models of `/ocr/batches`. Money (costs) is a decimal string."""

from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, Field, PlainSerializer, model_validator

from app.schemas import BackendInfo, ErrorDetail, Receipt

# A cost or a price in US dollars, written as a plain decimal string ("0.0000005",
# never "5E-7"), with every digit OpenRouter reported.
Usd = Annotated[Decimal, PlainSerializer(lambda value: format(value, "f"), return_type=str)]


class BatchCapabilityResponse(BaseModel):
    """Whether batch mode can be used now; `code` and `message` say why not.

    Read-only: it reads OpenRouter's public model list (without the key) and
    sends no receipt data.
    """

    available: bool
    code: str | None
    message: str | None
    backend: str
    model_name: str | None
    model_version: str | None
    providers: list[str]
    max_receipts: int
    max_upload_bytes: int
    retention_days: int
    prompt_price_usd: Usd | None
    completion_price_usd: Usd | None


class BatchEstimateRequest(BaseModel):
    receipts: int = Field(ge=1, le=1_000_000)
    images: int = Field(ge=1, le=3_000_000)

    @model_validator(mode="after")
    def _images_per_receipt(self) -> "BatchEstimateRequest":
        if not self.receipts <= self.images <= 3 * self.receipts:
            raise ValueError("images must be between receipts and 3 x receipts")
        return self


class BatchEstimateResponse(BaseModel):
    receipts: int
    images: int
    prompt_tokens: int
    completion_tokens_typical: int
    completion_tokens_max: int
    cost_usd: Usd
    cost_usd_max: Usd
    model_name: str
    model_version: str
    basis: str


class BatchManifestEntry(BaseModel):
    """One receipt of a create request: its opaque key, and how many `images` parts are its."""

    key: str = Field(pattern=r"^[A-Za-z0-9_-]{16,64}$")
    images: int = Field(ge=1, le=3)


class BatchRequestCounts(BaseModel):
    total: int | None
    completed: int | None
    failed: int | None


class BatchStatusResponse(BaseModel):
    """A batch: the service's `state` (running, completed, failed, expired, cancelled), the
    provider's own status, counts, the cost so far, and the times (UTC)."""

    id: str
    state: Literal["running", "completed", "failed", "expired", "cancelled"]
    provider_status: str | None
    provider: str | None
    model_name: str | None
    requests: BatchRequestCounts
    cost_usd: Usd | None
    estimated_cost_usd: Usd | None
    created_at: datetime | None
    expires_at: datetime | None
    finished_at: datetime | None
    error: ErrorDetail | None


class BatchOcr(BackendInfo):
    """One receipt read in a batch, in the shape of `/ocr`'s answer plus the batch accounting.

    `repaired` is always false (no repair pass in a batch) and `elapsed_seconds`
    null (the provider does not say how long one request took).
    """

    receipt: Receipt
    prompt_version: str | None
    repaired: bool
    elapsed_seconds: Decimal | None
    mode: Literal["batch"]
    batch_id: str
    provider: str | None
    cost_usd: Usd | None
    prompt_tokens: int | None
    completion_tokens: int | None
    finish_reason: str | None


class BatchItemError(BaseModel):
    """`retry_sync`: reading this receipt one at a time may succeed (for `ocr_parse_failed`, the
    repair pass a batch cannot run)."""

    code: str
    message: str
    retry_sync: bool


class BatchResultItem(BaseModel):
    key: str
    status: Literal["ok", "error"]
    ocr: BatchOcr | None
    error: BatchItemError | None
    cost_usd: Usd | None


class BatchResultCounts(BaseModel):
    ok: int
    parse_failed: int
    failed: int
    ignored: int


class BatchResultsResponse(BaseModel):
    batch: BatchStatusResponse
    results: list[BatchResultItem]
    counts: BatchResultCounts


class BatchDeletionResponse(BaseModel):
    """`upstream_status`: what the provider did with its copy (`deleted`, `unsupported`,
    `not_applicable`), as OpenRouter reports it."""

    id: str
    deleted: bool
    openrouter: str | None
    upstream_provider: str | None
    upstream_status: str | None
