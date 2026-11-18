"""Batch mode through OpenRouter's Batch API (`POST/GET/DELETE /api/v1/batches`).

What it gives up, and why it is a separate opt-in
(`docs/decisions/0017-ocr-batch-mode.md`): a batch cannot use zero-data-retention
endpoints. OpenRouter keeps a batch's requests and results for 30 days unless
the batch is deleted earlier, and the provider holds them while it works. So:

- **Off unless allowed.** Every method refuses (501 `openrouter_batch_not_allowed`)
  unless `OPENROUTER_BATCH_ALLOW_RETENTION=true`. `capability` reports the same
  refusal as "not available". No setting of the synchronous path can switch it
  on (three request-shaping settings are shared: `OPENROUTER_MAX_TOKENS`,
  `OPENROUTER_OCR_IMAGE_MAX_SIDE`, `OPENROUTER_STRUCTURED_OUTPUT`), and nothing
  here changes the synchronous path.
- **Named providers only.** A batch is routed with `provider.only` =
  `OPENROUTER_BATCH_PROVIDERS` (only those that serve the model's `:batch`
  variant and are known to read inline images in a batch) and
  `allow_fallbacks: false`. The provider that ran the batch is checked against
  them; results from any other provider are not used.
- **Only the photos and the fixed prompt.** Each request is the synchronous
  path's own request body (`receipt_request_body`: the prompt, the re-encoded
  photos as inline data URLs, temperature, max tokens, the answer schema) with
  the caller's opaque key as `custom_id`. No file name, no app id, no ledger
  data, no attribution header. Photos are never put on a URL: when the account
  is not allowed to send inline images, the batch fails and says so.
- **Deleted when done.** The caller deletes each batch once its results are
  stored (`delete`).

The answer of each request is read exactly as the synchronous path reads it
(`parse_answer`, then `postprocess`), so the same answer gives the same
receipt. The repair pass cannot run inside a batch: an answer that does not
parse is reported as `ocr_parse_failed` with `retry_sync: true`.

The HTTP calls sit behind `BatchTransport`; the tests use a fake.
"""

import json
import logging
import math
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any, Protocol

import httpx

from app.backends.base import BackendConfigError, BackendError, Extraction
from app.backends.openrouter import (
    _INVALID_KEY_MESSAGE,
    API_BASE,
    CATALOGUE_TIMEOUT_SECONDS,
    CATALOGUE_TTL_SECONDS,
    CONNECT_TIMEOUT_SECONDS,
    MODELS_URL,
    HttpResponse,
    _client,
    _count,
    _decimal,
    _decode,
    _provider_key,
    _setting,
    _text_of,
    encode_jpeg,
    jpeg_part,
    key_is_valid,
    receipt_request_body,
    upstream_error,
)
from app.batch.base import (
    BATCH_ID_PATTERN,
    KEY_PATTERN,
    BatchItem,
    BatchReceipt,
    BatchResults,
    BatchStatus,
    Capability,
    Deletion,
    Estimate,
    ItemError,
    OcrBatches,
)
from app.config import Settings
from app.decimals import wide_context
from app.ocr.images import prepare_images
from app.ocr.parsing import AnswerError, parse_answer
from app.ocr.postprocess import postprocess
from app.ocr.prompt import PROMPT_VERSION, build_messages

logger = logging.getLogger(__name__)

BATCHES_URL = f"{API_BASE}/batches"
CHAT_ENDPOINT = "/v1/chat/completions"
BATCH_SUFFIX = ":batch"
COMPLETION_WINDOW = "24h"
RETENTION_DAYS = 30

# The most receipts in one batch. OpenRouter caps the requests per batch (the cap is
# only reported in a 413) and the body at 200 MB; 100 receipts of 1 to 3 photos stay
# well inside both at the default image size. The Rails app splits larger selections.
MAX_RECEIPTS = 100
# The largest batch body this service sends: under OpenRouter's 200 MB, with room.
MAX_BODY_BYTES = 190 * 1024 * 1024
# The most photo bytes one create request may upload to this service (the photos as
# stored, before they are scaled down and re-encoded).
MAX_UPLOAD_BYTES = 300 * 1024 * 1024
# Sending a body of up to 190 MB: the upload may take minutes on a slow line.
SUBMIT_TIMEOUT_SECONDS = 300.0
READ_TIMEOUT_SECONDS = 60.0

# Providers OpenRouter's batch documentation lists as reading inline (base64) images
# in a batch, by endpoint slug, with their decoded size limits per image and per
# request (None: no limit given). Inline images need the account on OpenRouter's
# allowlist as well; any provider not here refuses them.
INLINE_IMAGE_LIMITS: Mapping[str, tuple[int, int | None]] = {
    "anthropic": (5 * 1024 * 1024, None),
    "openai": (20 * 1024 * 1024, 20 * 1024 * 1024),
    "deepinfra": (20 * 1024 * 1024, 20 * 1024 * 1024),
    "mistral": (10 * 1024 * 1024, 20 * 1024 * 1024),
    "xai": (17 * 1024 * 1024, 17 * 1024 * 1024),
    "google-vertex": (7 * 1024 * 1024, 20 * 1024 * 1024),
    "alibaba": (4 * 1024 * 1024, 4 * 1024 * 1024),
    "sail-research": (20 * 1024 * 1024, 20 * 1024 * 1024),
}

# The estimate (see `estimate`): image tokens per photo at the default 2048 px side
# (providers scale a photo to about a megapixel and count roughly 1,000 to 1,600
# tokens for it), characters per prompt token (the prompt mixes English and
# Ukrainian), and the answer of a typical receipt (20 items, about 1,200 tokens).
IMAGE_TOKENS_PER_PHOTO = 1600
PROMPT_CHARS_PER_TOKEN = 3
TYPICAL_ANSWER_TOKENS = 1200

_FINAL = {
    "completed": "completed",
    "failed": "failed",
    "expired": "expired",
    "cancelled": "cancelled",
}

NOT_ALLOWED_MESSAGE = (
    "Batch mode is off. A batch is not zero-retention: OpenRouter and the provider keep the "
    "photos and the answers until the batch is deleted (at most 30 days), which the normal "
    "path's rule forbids. To accept that for batches only, set "
    "OPENROUTER_BATCH_ALLOW_RETENTION=true (see ml/README.md, 'Batch mode')."
)


class BatchTransport(Protocol):
    """The HTTP calls of batch mode. `api_key` None: a public catalogue read without the key."""

    def request(
        self,
        method: str,
        url: str,
        *,
        api_key: str | None,
        body: bytes | None = None,
        timeout: float,
    ) -> HttpResponse: ...  # pragma: no cover

    def close(self) -> None: ...  # pragma: no cover


class HttpxBatchTransport:
    """httpx with the synchronous path's client rules: no environment, no redirects, no cookies.

    Public catalogue reads and keyed batch calls use separate clients, so they
    share no connection. Only `Authorization` (keyed calls) and `Content-Type`
    (a body) are added to the client's own headers.
    """

    def __init__(self, transport: httpx.BaseTransport | None = None) -> None:
        self._public = _client(transport)
        self._keyed = _client(transport)

    def request(
        self,
        method: str,
        url: str,
        *,
        api_key: str | None,
        body: bytes | None = None,
        timeout: float,
    ) -> HttpResponse:
        headers = {}
        client = self._public
        if api_key is not None:
            headers["Authorization"] = f"Bearer {api_key}"
            client = self._keyed
        if body is not None:
            headers["Content-Type"] = "application/json"
        response = client.request(
            method,
            url,
            content=body,
            headers=headers,
            timeout=httpx.Timeout(timeout, connect=min(CONNECT_TIMEOUT_SECONDS, timeout)),
        )
        return HttpResponse(response.status_code, response.text)

    def close(self) -> None:
        self._public.close()
        self._keyed.close()


@dataclass(frozen=True)
class BatchCatalogue:
    """The batch model as OpenRouter lists it, and the allowed providers that serve it."""

    model: str
    model_version: str
    endpoints: tuple[str, ...]
    structured: bool
    providers: frozenset[str]
    prompt_price: Decimal
    completion_price: Decimal
    image_limit: int
    request_image_limit: int | None
    read_at: float


def _error(status: int, code: str, message: str) -> BackendError:
    return BackendError(status, code, message)


def _submit_unknown() -> BackendError:
    return _error(
        504,
        "openrouter_batch_submit_unknown",
        "The batch was sent but its answer was lost or unreadable: OpenRouter may have accepted "
        "it. Check the Batches tab of OpenRouter's logs and delete it there if it exists.",
    )


def _not_found() -> BackendError:
    return _error(
        404,
        "batch_not_found",
        "OpenRouter has no batch with this id: it was deleted, or it is older than 30 days.",
    )


def _upstream_message(text: str) -> str:
    """The upstream error's message, lower-cased, for classifying it here. Never passed on."""
    try:
        document = json.loads(text)
    except ValueError:
        return ""
    error = document.get("error") if isinstance(document, dict) else None
    message = error.get("message") if isinstance(error, dict) else None
    return message.casefold() if isinstance(message, str) else ""


def _refusal(message: str) -> tuple[str, str] | None:
    """A known kind of refusal in an upstream message, as the service's own code and words."""
    if "zero data retention" in message or "privacy setting" in message:
        return (
            "openrouter_batch_zdr_required",
            "OpenRouter refused the batch: the account's privacy settings require zero data "
            "retention, which a batch cannot meet. Only the owner can change that in the "
            "OpenRouter account (ml/README.md, 'Batch mode'); this code never does.",
        )
    if "image url" in message or "base64" in message or "inline" in message:
        return (
            "openrouter_batch_inline_images_refused",
            "The batch provider refused the inline photos: the account is not on OpenRouter's "
            "allowlist for base64 images in batches, or the provider cannot read them. Photos "
            "are never put on a public URL; read these receipts one at a time instead.",
        )
    if "prohibited content" in message:
        return (
            "openrouter_batch_refused",
            "The provider refused the content of a request (a content screening).",
        )
    return None


def batch_upstream_error(status: int, text: str) -> BackendError:
    """The service's own error for an error answer of the Batch API. No upstream text."""
    known = _refusal(_upstream_message(text))
    if known is not None and 400 <= status < 500 and status not in (404, 409, 410, 429):
        return _error(424, *known)
    if status == 413:
        return _error(
            413,
            "batch_too_large",
            "OpenRouter refused the batch as too large (its cap on requests per batch, or "
            "200 MB); send fewer receipts in it.",
        )
    if status in (404, 410):
        return _not_found()
    if status == 409:
        return _error(
            409, "batch_running", "The batch is still running; it can be deleted once it ends."
        )
    return upstream_error(status)


def _time(value: Any) -> datetime | None:
    """A provider time (Unix seconds, or ISO 8601 text) as an aware UTC datetime."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int | Decimal | float):
        try:
            return datetime.fromtimestamp(float(value), UTC)
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
    return None


def _provider_tag(tag: str) -> str:
    """An endpoint slug's provider part (`vendor/eu` -> `vendor`)."""
    return tag.split("/", 1)[0].strip().casefold()


def parse_providers(value: str | None) -> tuple[str, ...]:
    """`OPENROUTER_BATCH_PROVIDERS` as a sorted tuple of slugs."""
    if value is None:
        return ()
    return tuple(sorted({part.strip().casefold() for part in value.split(",") if part.strip()}))


class OpenRouterBatches(OcrBatches):
    """`OcrBatches` through OpenRouter. Built by `OpenRouterBackend.batches()`."""

    def __init__(
        self,
        settings: Settings,
        *,
        transport: BatchTransport | None = None,
        halted: Callable[[], None] = lambda: None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self._make_transport: Callable[[], BatchTransport] = (
            (lambda: transport) if transport is not None else HttpxBatchTransport
        )
        self._transport: BatchTransport | None = None
        # The synchronous path's halt (a wrong provider answered): no hosted call of any
        # kind goes out until the service restarts, batches included.
        self._check_not_halted = halted
        self._clock = clock
        self._lock = threading.Lock()
        self._catalogue: BatchCatalogue | None = None
        self.model = _setting(settings.openrouter_batch_model)
        self.providers = parse_providers(settings.openrouter_batch_providers)

    # Settings ------------------------------------------------------------------

    def _ready(self, *, needs_key: bool = True) -> None:
        """Refuse unless batch mode is allowed and configured. The opt-in comes first."""
        if self.settings.openrouter_batch_allow_retention is not True:
            raise BackendConfigError("openrouter_batch_not_allowed", NOT_ALLOWED_MESSAGE)
        if self.model is None:
            raise BackendConfigError(
                "openrouter_batch_model_missing",
                "Batch mode needs OPENROUTER_BATCH_MODEL: a model id whose ':batch' variant is "
                "listed on openrouter.ai/models (see ml/README.md).",
            )
        if not self.providers:
            raise BackendConfigError(
                "openrouter_batch_providers_missing",
                "Batch mode needs OPENROUTER_BATCH_PROVIDERS: the provider slugs a batch may run "
                "on, for example 'anthropic' (see ml/README.md).",
            )
        unknown = [
            slug for slug in self.providers if _provider_tag(slug) not in INLINE_IMAGE_LIMITS
        ]
        if unknown:
            raise BackendConfigError(
                "openrouter_batch_provider_unsupported",
                f"OPENROUTER_BATCH_PROVIDERS names {', '.join(unknown)}, which OpenRouter does "
                "not list as reading inline images in a batch; photos are never sent as URLs.",
            )
        if needs_key:
            self._api_key()
        self._check_not_halted()

    def _api_key(self) -> str:
        key = self.settings.openrouter_api_key
        if key is None or not key.get_secret_value().strip():
            raise BackendConfigError(
                "openrouter_key_missing", "Batch mode needs OPENROUTER_API_KEY (see ml/README.md)."
            )
        if not key_is_valid(self.settings):
            raise BackendConfigError("openrouter_key_invalid", _INVALID_KEY_MESSAGE)
        return key.get_secret_value().strip()

    def _transport_or_new(self) -> BatchTransport:
        if self._transport is None:
            self._transport = self._make_transport()
        return self._transport

    def close(self) -> None:
        with self._lock:
            transport, self._transport = self._transport, None
            self._catalogue = None
        if transport is not None:
            transport.close()

    # The catalogue ---------------------------------------------------------------

    def catalogue(self) -> BatchCatalogue:
        """The batch model and its allowed endpoints, read again once an hour (public lists)."""
        assert self.model is not None
        with self._lock:
            now = self._clock()
            if self._catalogue is None or now - self._catalogue.read_at >= CATALOGUE_TTL_SECONDS:
                self._catalogue = self._read_catalogue(now)
            return self._catalogue

    def _public_json(self, url: str) -> Any:
        try:
            response = self._transport_or_new().request(
                "GET", url, api_key=None, timeout=CATALOGUE_TIMEOUT_SECONDS
            )
        except httpx.HTTPError:
            raise self._catalogue_unavailable("network error") from None
        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise self._catalogue_unavailable(f"HTTP {response.status_code}")
        try:
            return _decode(response.text)
        except ValueError:
            raise self._catalogue_unavailable("not JSON") from None

    @staticmethod
    def _catalogue_unavailable(detail: str) -> BackendError:
        return _error(
            503,
            "openrouter_catalogue_unavailable",
            f"OpenRouter's model list could not be read ({detail}); nothing was sent.",
        )

    def _unsupported(self) -> BackendConfigError:
        return BackendConfigError(
            "openrouter_batch_model_unsupported",
            f"OPENROUTER_BATCH_MODEL {self.model!r} has no batch variant that takes images "
            "('<model>:batch' on openrouter.ai/models); choose another model.",
        )

    def _read_catalogue(self, now: float) -> BatchCatalogue:
        assert self.model is not None
        variant = self.model + BATCH_SUFFIX
        models = self._public_json(MODELS_URL)
        data = models.get("data") if isinstance(models, dict) else None
        if not isinstance(data, list):
            raise self._catalogue_unavailable("unexpected shape")
        entry = next(
            (item for item in data if isinstance(item, dict) and item.get("id") == variant), None
        )
        if entry is None:
            raise self._unsupported()
        architecture = entry.get("architecture")
        modalities = (
            architecture.get("input_modalities") if isinstance(architecture, dict) else None
        )
        if not isinstance(modalities, list) or "image" not in modalities:
            raise self._unsupported()
        listing = self._public_json(f"{MODELS_URL}/{variant}/endpoints")
        listed = listing.get("data", {}).get("endpoints") if isinstance(listing, dict) else None
        if not isinstance(listed, list):
            raise self._unsupported()
        allowed = [
            item
            for item in listed
            if isinstance(item, dict)
            and isinstance(item.get("tag"), str)
            and isinstance(item.get("provider_name"), str)
            and item["tag"].strip().casefold() in self.providers
        ]
        if not allowed:
            raise BackendConfigError(
                "openrouter_batch_no_provider",
                f"None of OPENROUTER_BATCH_PROVIDERS ({', '.join(self.providers)}) serves "
                f"{self.model!r} in batch mode now.",
            )
        structured_tags = [
            item["tag"]
            for item in allowed
            if isinstance(item.get("supported_parameters"), list)
            and {"structured_outputs", "response_format"} <= set(item["supported_parameters"])
        ]
        structured = bool(structured_tags) and self.settings.openrouter_structured_output
        chosen = (
            [item for item in allowed if item["tag"] in structured_tags] if structured else allowed
        )
        prompt, completion = self._prices(chosen, entry)
        limits = [INLINE_IMAGE_LIMITS[_provider_tag(item["tag"])] for item in chosen]
        request_limits = [limit for _image, limit in limits if limit is not None]
        return BatchCatalogue(
            model=self.model,
            model_version=str(entry.get("canonical_slug") or self.model),
            endpoints=tuple(sorted({item["tag"] for item in chosen})),
            structured=structured,
            providers=frozenset(
                {_provider_key(item["provider_name"]) for item in chosen}
                | {_provider_tag(item["tag"]) for item in chosen}
            ),
            prompt_price=prompt,
            completion_price=completion,
            image_limit=min(image for image, _limit in limits),
            request_image_limit=min(request_limits) if request_limits else None,
            read_at=now,
        )

    def _prices(
        self, endpoints: Sequence[Mapping[str, Any]], entry: Mapping[str, Any]
    ) -> tuple[Decimal, Decimal]:
        """The highest batch price per prompt and per completion token among the endpoints."""
        prompts: list[Decimal] = []
        completions: list[Decimal] = []
        for source in [*(item.get("pricing") for item in endpoints), entry.get("pricing")]:
            if not isinstance(source, dict):
                continue
            prompt, completion = _decimal(source.get("prompt")), _decimal(source.get("completion"))
            if prompt is not None and completion is not None:
                prompts.append(prompt)
                completions.append(completion)
        if not prompts:
            raise self._catalogue_unavailable("no batch price")
        return max(prompts), max(completions)

    # Capability and estimate ---------------------------------------------------------

    def capability(self) -> Capability:
        limits = {"max_receipts": MAX_RECEIPTS, "max_upload_bytes": MAX_UPLOAD_BYTES}
        try:
            self._ready()
            catalogue = self.catalogue()
        except BackendError as error:
            return Capability(available=False, code=error.code, message=error.message, **limits)
        return Capability(
            available=True,
            model_name=catalogue.model,
            model_version=catalogue.model_version,
            providers=catalogue.endpoints,
            retention_days=RETENTION_DAYS,
            prompt_price_usd=catalogue.prompt_price,
            completion_price_usd=catalogue.completion_price,
            **limits,
        )

    def estimate(self, receipts: int, images: int) -> Estimate:
        """A rough cost: about right for typical receipts, within a factor of two either way.

        Prompt tokens: the fixed prompt (characters / 3) per receipt plus
        `IMAGE_TOKENS_PER_PHOTO` per photo (the real count depends on the
        provider and the photo's size). Answer tokens: `TYPICAL_ANSWER_TOKENS`
        per receipt for `cost_usd`, `OPENROUTER_MAX_TOKENS` per receipt for
        `cost_usd_max` (no receipt can cost more than that, if the image count
        holds). Prices: the highest batch price among the allowed endpoints.
        """
        self._ready(needs_key=False)
        catalogue = self.catalogue()
        prompt_text = sum(len(message["content"]) for message in build_messages(1))
        prompt_tokens = receipts * math.ceil(prompt_text / PROMPT_CHARS_PER_TOKEN) + (
            images * IMAGE_TOKENS_PER_PHOTO
        )
        typical = receipts * TYPICAL_ANSWER_TOKENS
        most = receipts * self.settings.openrouter_max_tokens
        # Exact: a price may have up to 50 digits, more than the default context's 28.
        with wide_context():
            prompt_cost = prompt_tokens * catalogue.prompt_price
            cost = prompt_cost + typical * catalogue.completion_price
            cost_max = prompt_cost + most * catalogue.completion_price
        return Estimate(
            receipts=receipts,
            images=images,
            prompt_tokens=prompt_tokens,
            completion_tokens_typical=typical,
            completion_tokens_max=most,
            cost_usd=cost,
            cost_usd_max=cost_max,
            model_name=catalogue.model,
            model_version=catalogue.model_version,
            basis=(
                f"{IMAGE_TOKENS_PER_PHOTO} prompt tokens per photo, the prompt at "
                f"{PROMPT_CHARS_PER_TOKEN} characters per token, {TYPICAL_ANSWER_TOKENS} answer "
                "tokens per receipt (the maximum: OPENROUTER_MAX_TOKENS), at the model's batch "
                "price. Rough: within a factor of two either way."
            ),
        )

    # Submit --------------------------------------------------------------------------

    def batch_body(self, catalogue: BatchCatalogue, receipts: Sequence[BatchReceipt]) -> bytes:
        """The provider batch as JSON bytes, `requests` last (OpenRouter reads it as a stream)."""
        requests = []
        for receipt in receipts:
            pictures = prepare_images(receipt.images, self.settings.openrouter_ocr_image_max_side)
            jpegs = [encode_jpeg(picture) for picture in pictures]
            if any(len(jpeg) > catalogue.image_limit for jpeg in jpegs) or (
                catalogue.request_image_limit is not None
                and sum(len(jpeg) for jpeg in jpegs) > catalogue.request_image_limit
            ):
                raise _error(
                    422,
                    "batch_image_too_large",
                    f"A photo of receipt key {receipt.key} is larger than the batch provider "
                    "takes inline, even scaled down; lower OPENROUTER_OCR_IMAGE_MAX_SIDE or read "
                    "it one at a time.",
                )
            body = receipt_request_body(
                catalogue.model,
                build_messages(len(pictures)),
                [jpeg_part(jpeg) for jpeg in jpegs],
                max_tokens=self.settings.openrouter_max_tokens,
                structured=catalogue.structured,
            )
            requests.append({"custom_id": receipt.key, "body": body})
        document: dict[str, Any] = {
            "endpoint": CHAT_ENDPOINT,
            "model": catalogue.model,
            # Named providers only, and no fallback to any other.
            "provider": {"only": list(catalogue.endpoints), "allow_fallbacks": False},
            "completion_window": COMPLETION_WINDOW,
        }
        document["requests"] = requests
        return json.dumps(document, ensure_ascii=False).encode()

    def submit(self, receipts: Sequence[BatchReceipt]) -> BatchStatus:
        self._ready()
        if not 1 <= len(receipts) <= MAX_RECEIPTS:
            raise _error(
                422,
                "batch_too_many_receipts",
                f"A batch holds 1 to {MAX_RECEIPTS} receipts, got {len(receipts)}.",
            )
        keys = [receipt.key for receipt in receipts]
        if len(set(keys)) != len(keys) or not all(KEY_PATTERN.fullmatch(key) for key in keys):
            raise _error(
                422,
                "batch_invalid_key",
                "Every receipt needs its own key of 16 to 64 letters, digits, '-' or '_'.",
            )
        catalogue = self.catalogue()
        body = self.batch_body(catalogue, receipts)
        if len(body) > MAX_BODY_BYTES:
            raise _error(
                413,
                "batch_too_large",
                f"The batch would be {len(body)} bytes, over the limit of {MAX_BODY_BYTES}; "
                "send fewer receipts in it.",
            )
        estimate = self.estimate(len(receipts), sum(len(receipt.images) for receipt in receipts))
        api_key = self._api_key()
        self._check_not_halted()
        try:
            response = self._transport_or_new().request(
                "POST", BATCHES_URL, api_key=api_key, body=body, timeout=SUBMIT_TIMEOUT_SECONDS
            )
        except (httpx.ConnectError, httpx.ConnectTimeout):
            # Never connected: nothing was sent, so trying again is safe.
            raise _error(
                502, "openrouter_unreachable", "OpenRouter could not be reached."
            ) from None
        except httpx.HTTPError:
            raise _submit_unknown() from None
        if response.status_code >= 500:
            # A gateway or server error after the upload may come after the batch was stored:
            # sending it again could pay for it twice, so the outcome is unknown.
            raise _submit_unknown()
        if response.status_code not in (200, 202):
            raise batch_upstream_error(response.status_code, response.text)
        try:
            document = self._document(response.text)
            status = self._status_of(document, catalogue)
        except Exception:
            # Accepted (2xx), but the answer cannot be read: OpenRouter has the batch, and
            # nothing here knows its id. Never a 5xx that a caller would retry.
            logger.exception("A batch was accepted but its answer could not be read")
            raise _submit_unknown() from None
        return BatchStatus(**{**status.__dict__, "estimated_cost_usd": estimate.cost_usd})

    # Status, results, delete ------------------------------------------------------------

    @staticmethod
    def _document(text: str) -> dict[str, Any]:
        try:
            document = _decode(text)
        except ValueError:
            document = None
        if not isinstance(document, dict) or not isinstance(document.get("id"), str):
            raise _error(
                502, "openrouter_bad_response", "OpenRouter's batch answer had an unexpected shape."
            )
        return document

    def _keyed(self, method: str, batch_id: str, suffix: str = "") -> HttpResponse:
        if not BATCH_ID_PATTERN.fullmatch(batch_id):
            raise _error(
                422, "batch_invalid_id", "A batch id has 1 to 128 letters, digits, '-' or '_'."
            )
        api_key = self._api_key()
        try:
            return self._transport_or_new().request(
                method,
                f"{BATCHES_URL}/{batch_id}{suffix}",
                api_key=api_key,
                timeout=READ_TIMEOUT_SECONDS,
            )
        except httpx.TimeoutException:
            raise _error(504, "openrouter_timeout", "OpenRouter did not answer in time.") from None
        except httpx.HTTPError:
            raise _error(
                502, "openrouter_unreachable", "OpenRouter could not be reached."
            ) from None

    def _fetch(self, batch_id: str) -> dict[str, Any]:
        self._ready()
        response = self._keyed("GET", batch_id)
        if response.status_code != 200:
            raise batch_upstream_error(response.status_code, response.text)
        return self._document(response.text)

    def status(self, batch_id: str) -> BatchStatus:
        document = self._fetch(batch_id)
        return self._status_of(document, self._catalogue_or_none())

    def _catalogue_or_none(self) -> BatchCatalogue | None:
        try:
            return self.catalogue()
        except BackendError:
            return None

    def _status_of(
        self, document: Mapping[str, Any], catalogue: BatchCatalogue | None
    ) -> BatchStatus:
        raw = document.get("status")
        provider_status = raw if isinstance(raw, str) else None
        results_ready = isinstance(document.get("results"), list)
        if provider_status in _FINAL and not (provider_status == "completed" and not results_ready):
            state = _FINAL[provider_status]
        else:
            # `completed` without results yet, an unknown status, or one still working.
            state = "running"
        counts = document.get("request_counts")
        counts = counts if isinstance(counts, dict) else {}
        usage = document.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        error_code = error_message = None
        if state in ("failed", "expired", "cancelled"):
            error_code, error_message = self._batch_error(state, document.get("error"))
        provider = document.get("provider")
        model = document.get("model")
        return BatchStatus(
            id=str(document["id"]),
            state=state,  # type: ignore[arg-type]
            provider_status=provider_status,
            provider=provider if isinstance(provider, str) else None,
            model_name=model
            if isinstance(model, str)
            else (catalogue.model if catalogue else None),
            request_total=_count(counts.get("total")),
            request_completed=_count(counts.get("completed")),
            request_failed=_count(counts.get("failed")),
            cost_usd=_decimal(usage.get("cost")),
            created_at=_time(document.get("created_at")),
            expires_at=_time(document.get("expires_at")),
            finished_at=_time(document.get("finalized_at")) if state != "running" else None,
            error_code=error_code,
            error_message=error_message,
            results_ready=state == "completed",
        )

    @staticmethod
    def _batch_error(state: str, error: Any) -> tuple[str, str]:
        if state == "expired":
            return "batch_expired", "The provider did not finish the batch before it expired."
        if state == "cancelled":
            return "batch_cancelled", "The provider cancelled the batch."
        message = error.get("message") if isinstance(error, dict) else None
        known = _refusal(message.casefold()) if isinstance(message, str) else None
        if known is not None:
            return known
        return (
            "openrouter_batch_failed",
            "The batch failed at OpenRouter or the provider (its validation or a refusal).",
        )

    def results(self, batch_id: str) -> BatchResults:
        document = self._fetch(batch_id)
        # A batch sent earlier is read even if its model or provider has left the catalogue
        # since: its answers are then checked against OPENROUTER_BATCH_PROVIDERS itself.
        catalogue = self._catalogue_or_none()
        allowed = (
            catalogue.providers
            if catalogue is not None
            else frozenset(_provider_tag(slug) for slug in self.providers)
        )
        status = self._status_of(document, catalogue)
        if status.state != "completed":
            raise _error(
                409,
                "batch_not_finished",
                f"The batch is {status.state}; only a completed batch has results.",
            )
        batch_provider_ok = status.provider is None or self._provider_ok(status.provider, allowed)
        items: list[BatchItem] = []
        seen: set[str] = set()
        ignored = 0
        for entry in document["results"]:
            key = entry.get("custom_id") if isinstance(entry, dict) else None
            if not isinstance(key, str) or not KEY_PATTERN.fullmatch(key) or key in seen:
                ignored += 1
                continue
            seen.add(key)
            items.append(self._item(key, entry, status, catalogue, allowed, batch_provider_ok))
        return BatchResults(status=status, items=items, ignored=ignored)

    @staticmethod
    def _provider_ok(provider: str, allowed: frozenset[str]) -> bool:
        key = _provider_key(provider)
        return key in allowed or _provider_tag(key) in allowed

    def _item(
        self,
        key: str,
        entry: Mapping[str, Any],
        status: BatchStatus,
        catalogue: BatchCatalogue | None,
        allowed: frozenset[str],
        batch_provider_ok: bool,
    ) -> BatchItem:
        def failed(
            code: str, message: str, retry_sync: bool = True, **accounting: Any
        ) -> BatchItem:
            return BatchItem(key=key, error=ItemError(code, message, retry_sync), **accounting)

        if entry.get("error") is not None or not isinstance(entry.get("response"), dict):
            error = entry.get("error")
            message = error.get("message") if isinstance(error, dict) else None
            known = _refusal(message.casefold()) if isinstance(message, str) else None
            if known is not None:
                code, text = known
                return failed(code, text, retry_sync=code != "openrouter_batch_refused")
            return failed(
                "openrouter_batch_request_failed",
                "The provider could not answer this receipt's request in the batch.",
            )
        response = entry["response"]
        body = response.get("body")
        code = response.get("status_code")
        if isinstance(code, int) and not isinstance(code, bool) and code != 200:
            return failed(
                "openrouter_batch_request_failed",
                f"The provider answered this receipt's request in the batch with HTTP {code}.",
            )
        if not isinstance(body, dict):
            return failed(
                "openrouter_bad_response",
                "The receipt's answer in the batch had an unexpected shape.",
            )
        usage = body.get("usage") if isinstance(body.get("usage"), dict) else {}
        choices = body.get("choices")
        choice = choices[0] if isinstance(choices, list) and choices else None
        provider = (
            body.get("provider") if isinstance(body.get("provider"), str) else status.provider
        )
        model = body.get("model")
        accounting = {
            "provider": provider,
            "model_version": (
                model
                if isinstance(model, str)
                else (catalogue.model_version if catalogue else status.model_name)
            ),
            "cost_usd": _decimal(usage.get("cost")),
            "prompt_tokens": _count(usage.get("prompt_tokens")),
            "completion_tokens": _count(usage.get("completion_tokens")),
            "finish_reason": (
                choice.get("finish_reason")
                if isinstance(choice, dict) and isinstance(choice.get("finish_reason"), str)
                else None
            ),
        }
        if provider is None or not batch_provider_ok or not self._provider_ok(provider, allowed):
            return failed(
                "openrouter_batch_provider_unverified",
                "The answer came from a provider outside OPENROUTER_BATCH_PROVIDERS; "
                "it was not used.",
                **accounting,
            )
        if (
            not isinstance(choice, dict)
            or not isinstance(choice.get("message"), dict)
            or body.get("error")
        ):
            return failed(
                "openrouter_batch_request_failed",
                "The provider could not answer this receipt's request in the batch.",
                **accounting,
            )
        try:
            raw = parse_answer(_text_of(choice["message"].get("content")))
        except AnswerError as error:
            return failed(
                "ocr_parse_failed",
                f"The model's answer was not valid receipt JSON ({error.problems}); a read one "
                "at a time can try the repair pass, which a batch cannot.",
                **accounting,
            )
        receipt, report = postprocess(raw)
        extraction = Extraction(
            receipt=receipt,
            prompt_version=PROMPT_VERSION,
            repaired=False,
            diagnostics={"postprocess": report.as_dict()},
        )
        return BatchItem(key=key, extraction=extraction, **accounting)

    def delete(self, batch_id: str) -> Deletion:
        self._ready()
        response = self._keyed("DELETE", batch_id)
        if response.status_code != 200:
            raise batch_upstream_error(response.status_code, response.text)
        document = self._document(response.text)
        deletion = document.get("deletion") if isinstance(document.get("deletion"), dict) else {}
        upstream = deletion.get("upstream") if isinstance(deletion.get("upstream"), dict) else {}

        def text(value: Any) -> str | None:
            return value if isinstance(value, str) else None

        return Deletion(
            id=str(document["id"]),
            openrouter=text(deletion.get("openrouter")),
            upstream_provider=text(upstream.get("provider")),
            upstream_status=text(upstream.get("status")),
        )
