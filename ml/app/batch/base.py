"""The batch interface and its value types.

Keys: the caller (the Rails app) gives every receipt an opaque key, a random
token of 16 to 64 URL-safe characters that it maps to the receipt itself. The
key is sent to the provider as the request's `custom_id` and comes back with
the result. It is never a receipt id, a file name or anything else of the app:
the mapping exists only in the caller's database, and this service keeps none.
"""

import re
from abc import ABC, abstractmethod
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Literal

from app.backends.base import Extraction, ImageInput

# A receipt's key, and a provider's batch id. Both go into URLs or JSON only after
# these checks, so neither can carry a path, a query or a control character.
KEY_PATTERN = re.compile(r"[A-Za-z0-9_-]{16,64}")
BATCH_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,128}")

# The service's own states. The provider's states map onto them:
# validating, in_progress, finalizing, cancelling (and `completed` while its
# results are not attached yet) -> running; completed -> completed; failed;
# expired; cancelled.
BatchState = Literal["running", "completed", "failed", "expired", "cancelled"]
FINAL_STATES: frozenset[str] = frozenset({"completed", "failed", "expired", "cancelled"})


@dataclass(frozen=True)
class BatchReceipt:
    """One receipt for a batch: its caller-chosen opaque key and its 1 to 3 photos, in order."""

    key: str
    images: Sequence[ImageInput]


@dataclass(frozen=True)
class Capability:
    """Whether a batch can be submitted now, and if not, why (`code`, `message`)."""

    available: bool
    code: str | None = None
    message: str | None = None
    model_name: str | None = None
    model_version: str | None = None
    providers: tuple[str, ...] = ()
    max_receipts: int = 0
    max_upload_bytes: int = 0
    retention_days: int = 30
    prompt_price_usd: Decimal | None = None
    completion_price_usd: Decimal | None = None


@dataclass(frozen=True)
class Estimate:
    """A rough cost before submitting (see `basis`), in US dollars, as exact decimals."""

    receipts: int
    images: int
    prompt_tokens: int
    completion_tokens_typical: int
    completion_tokens_max: int
    cost_usd: Decimal
    cost_usd_max: Decimal
    model_name: str
    model_version: str
    basis: str


@dataclass(frozen=True)
class BatchStatus:
    """A batch as the provider reports it, in the service's own terms.

    `error_code` and `error_message` are the service's own words for a failed,
    expired or cancelled batch; an upstream message is never passed on.
    """

    id: str
    state: BatchState
    provider_status: str | None
    provider: str | None
    model_name: str | None
    request_total: int | None = None
    request_completed: int | None = None
    request_failed: int | None = None
    cost_usd: Decimal | None = None
    created_at: datetime | None = None
    expires_at: datetime | None = None
    finished_at: datetime | None = None
    error_code: str | None = None
    error_message: str | None = None
    results_ready: bool = False
    estimated_cost_usd: Decimal | None = None


@dataclass(frozen=True)
class ItemError:
    """Why one receipt of a batch has no result. `retry_sync`: a synchronous read may help."""

    code: str
    message: str
    retry_sync: bool


@dataclass(frozen=True)
class BatchItem:
    """The result for one key: an extraction (as `/ocr` reads it) or an error, with accounting."""

    key: str
    extraction: Extraction | None = None
    error: ItemError | None = None
    model_version: str | None = None
    provider: str | None = None
    cost_usd: Decimal | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    finish_reason: str | None = None


@dataclass(frozen=True)
class BatchResults:
    status: BatchStatus
    items: list[BatchItem] = field(default_factory=list)
    # Results whose custom_id is not a valid key, or repeats one: left out, counted.
    ignored: int = 0


@dataclass(frozen=True)
class Deletion:
    """What deleting a batch removed: OpenRouter's copy, and the provider's (`upstream_status`:
    `deleted`, `unsupported` or `not_applicable`, as OpenRouter reports it)."""

    id: str
    openrouter: str | None
    upstream_provider: str | None
    upstream_status: str | None


class OcrBatches(ABC):
    """Submit, follow, read and delete batches of receipts. Every method is synchronous."""

    @abstractmethod
    def capability(self) -> Capability:
        """Whether batches can be submitted now. Sends nothing with the key and no receipt data."""

    @abstractmethod
    def estimate(self, receipts: int, images: int) -> Estimate:
        """A rough cost for `receipts` receipts with `images` photos in all."""

    @abstractmethod
    def submit(self, receipts: Sequence[BatchReceipt]) -> BatchStatus:
        """Build one provider batch from the receipts and submit it."""

    @abstractmethod
    def status(self, batch_id: str) -> BatchStatus:
        """The batch's state, counts, cost so far and expiry."""

    @abstractmethod
    def results(self, batch_id: str) -> BatchResults:
        """The results of a completed batch, per key."""

    @abstractmethod
    def delete(self, batch_id: str) -> Deletion:
        """Delete a finished batch at OpenRouter (and at the provider where it can)."""
