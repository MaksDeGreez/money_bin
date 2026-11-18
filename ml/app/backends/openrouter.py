"""The hosted OCR backend: a vision-language model reached through OpenRouter.

It uses the same prompt, parsing with one repair pass and post-processing as
the local backend (`app.ocr`), so a comparison differs only in the model.

Privacy rules (`docs/decisions/0012-hosted-ocr-backend.md`):

- **Zero data retention only.** Before the first call, and again every
  `CATALOGUE_TTL_SECONDS`, the backend reads OpenRouter's public list of
  zero-data-retention endpoints and keeps the configured model's endpoints
  that do NOT use Safety Retention (an endpoint where the provider may keep
  prompts its classifiers flag). Every request then carries the fixed
  provider preferences `zdr: true`, `data_collection: "deny"` and
  `only: [those endpoints]`. They are built here from constants; no setting
  can change or remove them. With no such endpoint the backend refuses to
  start or to call. The provider that served each answer is checked against
  the list afterwards.
- **Only the photos and the fixed prompt are sent.** Each photo is decoded and
  re-encoded from its pixels as a new JPEG (no EXIF, GPS, ICC profile or
  comment survives), and sent as a data URL. No file name, receipt id, user
  id or ledger data is sent; no `user`, `session_id`, `metadata` or `trace`
  field, no attribution header (`HTTP-Referer`, `X-Title`). The HTTP client
  reads nothing from the environment (no proxy settings, no `.netrc`).
- **The API key** comes only from `OPENROUTER_API_KEY`. It is sent in the
  `Authorization` header of the chat request and nowhere else (the catalogue
  is read without it), and it is never logged, put in an error or written to
  a file.

The HTTP calls sit behind the small `Transport` protocol; the tests use a fake.
"""

import base64
import json
import logging
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from io import BytesIO
from typing import Any, Protocol

import httpx
from PIL import Image

from app.backends.base import (
    Backend,
    BackendConfigError,
    BackendError,
    BackendNotImplementedError,
    Extraction,
    ImageInput,
)
from app.config import Settings
from app.ocr.images import prepare_images
from app.ocr.parsing import OcrParseError, read_with_repair
from app.ocr.postprocess import postprocess
from app.ocr.prompt import ANSWER_SCHEMA, PROMPT_VERSION, Repair, build_messages
from app.schemas import CategoriseResult

logger = logging.getLogger(__name__)

API_BASE = "https://openrouter.ai/api/v1"
CHAT_URL = f"{API_BASE}/chat/completions"
MODELS_URL = f"{API_BASE}/models"
ZDR_ENDPOINTS_URL = f"{API_BASE}/endpoints/zdr"

# How long the list of zero-retention endpoints is trusted before it is read again.
CATALOGUE_TTL_SECONDS = 3600.0
# Opening a connection; reading the answer has its own limit (OPENROUTER_TIMEOUT).
CONNECT_TIMEOUT_SECONDS = 10.0
CATALOGUE_TIMEOUT_SECONDS = 30.0
# The photos are sent as JPEG at this quality: the print stays sharp.
JPEG_QUALITY = 90
# A generic client name: it names neither this app, nor its owner, nor the machine.
USER_AGENT = "ocr-client"
SCHEMA_NAME = "receipt"

# The provider preferences of every request. They are constants on purpose: no
# setting reaches them, and `_provider_preferences` copies them before adding
# the endpoint list.
PRIVACY_PREFERENCES: Mapping[str, Any] = {"zdr": True, "data_collection": "deny"}

NOT_STARTED = "not-started"


@dataclass(frozen=True)
class HttpResponse:
    """What the backend needs of an HTTP answer: the status and the body text."""

    status_code: int
    text: str


class Transport(Protocol):
    """The HTTP calls of the backend. The tests use a fake."""

    def get(self, url: str, *, timeout: float) -> HttpResponse:
        """GET a public catalogue URL, without the API key."""
        ...  # pragma: no cover

    def post_json(
        self, url: str, body: Mapping[str, Any], *, api_key: str, timeout: float
    ) -> HttpResponse:
        """POST `body` as JSON with the API key as a bearer token."""
        ...  # pragma: no cover

    def close(self) -> None: ...  # pragma: no cover


class HttpxTransport:
    """The real transport: one httpx client, no environment, no redirects.

    `trust_env=False`: no proxy settings and no `.netrc` credentials from the
    environment. Only the headers set here (plus httpx's own Host,
    Content-Length, Accept-Encoding and Connection) are sent.
    """

    def __init__(self, transport: httpx.BaseTransport | None = None) -> None:
        self._client = httpx.Client(
            transport=transport,
            trust_env=False,
            follow_redirects=False,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )

    def _timeout(self, seconds: float) -> httpx.Timeout:
        return httpx.Timeout(seconds, connect=CONNECT_TIMEOUT_SECONDS)

    def get(self, url: str, *, timeout: float) -> HttpResponse:
        response = self._client.get(url, timeout=self._timeout(timeout))
        return HttpResponse(response.status_code, response.text)

    def post_json(
        self, url: str, body: Mapping[str, Any], *, api_key: str, timeout: float
    ) -> HttpResponse:
        response = self._client.post(
            url,
            content=json.dumps(body, ensure_ascii=False).encode(),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            timeout=self._timeout(timeout),
        )
        return HttpResponse(response.status_code, response.text)

    def close(self) -> None:
        self._client.close()


@dataclass(frozen=True)
class Catalogue:
    """The configured model as OpenRouter lists it, and its usable endpoints.

    `endpoints` are the endpoint slugs (`tag`) with zero data retention and no
    Safety Retention; `structured_endpoints` the ones of them that support
    structured outputs. `providers` are their provider names, as a chat
    answer reports the provider that served it.
    """

    model_version: str
    endpoints: tuple[str, ...]
    structured_endpoints: tuple[str, ...]
    providers: frozenset[str]
    read_at: float


@dataclass
class Call:
    """The accounting of one model call. Never the answer text."""

    seconds: float
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    cost_usd: Decimal | None = None
    provider: str | None = None
    model: str | None = None
    finish_reason: str | None = None
    structured_output: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "seconds": round(self.seconds, 3),
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "cost_usd": None if self.cost_usd is None else plain(self.cost_usd),
            "provider": self.provider,
            "model": self.model,
            "finish_reason": self.finish_reason,
            "structured_output": self.structured_output,
        }


def plain(value: Decimal) -> str:
    """A decimal as plain text, never in exponent form (`1E-9` is `0.000000001`)."""
    return format(value, "f")


def _setting(value: str | None) -> str | None:
    if value is None or not value.strip():
        return None
    return value.strip()


def missing_settings(settings: Settings) -> list[str]:
    """The settings the backend needs that are not set."""
    missing = []
    if _setting(settings.openrouter_ocr_model) is None:
        missing.append("OPENROUTER_OCR_MODEL")
    key = settings.openrouter_api_key
    if key is None or not key.get_secret_value().strip():
        missing.append("OPENROUTER_API_KEY")
    return missing


def _missing_message(missing: Sequence[str]) -> str:
    return (
        f"The openrouter backend is not configured: set {' and '.join(missing)} "
        "(OPENROUTER_OCR_MODEL is a model id from openrouter.ai/models; see ml/README.md)."
    )


def encode_jpeg(image: Image.Image) -> bytes:
    """A new JPEG made from the pixels only: no EXIF, GPS, ICC profile or comment.

    The image is copied into a fresh one, so nothing in `image.info` (where
    Pillow keeps the metadata it read) can reach the encoder.
    """
    clean = Image.new("RGB", image.size)
    clean.paste(image.convert("RGB"))
    buffer = BytesIO()
    clean.save(buffer, "JPEG", quality=JPEG_QUALITY)
    return buffer.getvalue()


def image_part(image: Image.Image) -> dict[str, Any]:
    data = base64.b64encode(encode_jpeg(image)).decode("ascii")
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{data}"}}


def _decode(text: str) -> Any:
    """JSON with every number as `Decimal` (a cost is never a float)."""
    return json.loads(text, parse_float=Decimal)


def _decimal(value: Any) -> Decimal | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, Decimal | int):
        return Decimal(value)
    if isinstance(value, str):
        try:
            return Decimal(value)
        except InvalidOperation:
            return None
    return None


def _count(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _text_of(content: Any) -> str:
    """The answer text: a string, or the text parts of a list of parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        )
    return ""


def upstream_error(status: int) -> BackendError:
    """The service's own error for an OpenRouter error status. No upstream text."""
    if status == 429:
        return BackendError(
            503, "openrouter_rate_limited", "The hosted model is rate limited (HTTP 429)."
        )
    if status == 408 or status >= 500:
        return BackendError(
            502,
            "openrouter_upstream_error",
            f"The hosted model's service failed (HTTP {status}).",
        )
    if status == 401:
        return BackendError(
            424, "openrouter_auth_failed", "OpenRouter refused the API key (HTTP 401)."
        )
    if status == 402:
        return BackendError(
            424,
            "openrouter_payment_required",
            "OpenRouter refused the request for lack of credits (HTTP 402).",
        )
    if status == 404:
        return BackendError(
            424,
            "openrouter_no_zdr_endpoint",
            "No zero-retention endpoint can serve the model now (HTTP 404).",
        )
    if status == 403:
        return BackendError(
            424,
            "openrouter_refused",
            "OpenRouter refused the request: a content policy or a budget (HTTP 403).",
        )
    return BackendError(
        424, "openrouter_bad_request", f"OpenRouter refused the request (HTTP {status})."
    )


def _catalogue_unavailable(detail: str) -> BackendError:
    return BackendError(
        503,
        "openrouter_catalogue_unavailable",
        f"The list of zero-retention endpoints could not be read ({detail}); "
        "nothing was sent to a hosted model.",
    )


def read_catalogue(transport: Transport, model: str, *, structured: bool, now: float) -> Catalogue:
    """Read the model and its strict zero-retention endpoints from OpenRouter's public lists.

    Raises `BackendConfigError` when the model is unknown, takes no images or
    has no endpoint with zero retention and no Safety Retention, and a 503
    `BackendError` when the lists cannot be read.
    """
    models = _get_json(transport, MODELS_URL)
    entry = next(
        (
            item
            for item in _data(models)
            if isinstance(item, dict) and model in (item.get("id"), item.get("canonical_slug"))
        ),
        None,
    )
    if entry is None:
        raise BackendConfigError(
            "openrouter_model_unknown",
            f"OPENROUTER_OCR_MODEL {model!r} is not in OpenRouter's model list.",
        )
    modalities = (entry.get("architecture") or {}).get("input_modalities") or []
    if "image" not in modalities:
        raise BackendConfigError(
            "openrouter_model_without_images",
            f"OPENROUTER_OCR_MODEL {model!r} does not take images.",
        )
    ids = {entry.get("id"), entry.get("canonical_slug")} - {None}
    endpoints = [
        item
        for item in _data(_get_json(transport, ZDR_ENDPOINTS_URL))
        if isinstance(item, dict)
        and item.get("model_id") in ids
        # Only an explicit `false` counts: a missing flag is not proof.
        and item.get("safety_retention") is False
        and isinstance(item.get("tag"), str)
        and item["tag"]
    ]
    if not endpoints:
        raise BackendConfigError(
            "openrouter_no_zdr_endpoint",
            f"OPENROUTER_OCR_MODEL {model!r} has no endpoint with zero data retention "
            "and no Safety Retention; choose another model.",
        )
    tags = tuple(sorted({item["tag"] for item in endpoints}))
    structured_tags = tuple(
        sorted(
            {
                item["tag"]
                for item in endpoints
                if {"structured_outputs", "response_format"}
                <= set(item.get("supported_parameters") or [])
            }
        )
    )
    return Catalogue(
        model_version=str(entry.get("canonical_slug") or entry.get("id")),
        endpoints=tags,
        structured_endpoints=structured_tags if structured else (),
        providers=frozenset(
            str(item["provider_name"]) for item in endpoints if item.get("provider_name")
        ),
        read_at=now,
    )


def _get_json(transport: Transport, url: str) -> Any:
    try:
        response = transport.get(url, timeout=CATALOGUE_TIMEOUT_SECONDS)
    except httpx.TimeoutException:
        raise _catalogue_unavailable("timeout") from None
    except httpx.HTTPError:
        raise _catalogue_unavailable("network error") from None
    if response.status_code != 200:
        raise _catalogue_unavailable(f"HTTP {response.status_code}")
    try:
        return _decode(response.text)
    except ValueError:
        raise _catalogue_unavailable("not JSON") from None


def _data(document: Any) -> list[Any]:
    if isinstance(document, dict) and isinstance(document.get("data"), list):
        return document["data"]
    raise _catalogue_unavailable("unexpected shape")


class OpenRouterBackend(Backend):
    name = "openrouter"

    def __init__(
        self,
        settings: Settings | None = None,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        super().__init__(settings)
        # A given transport (the tests' fake) is used again after `stop()`; without
        # one, a new HTTP client is made when the first call needs it.
        self._make_transport: Callable[[], Transport] = (
            (lambda: transport) if transport is not None else HttpxTransport
        )
        self._transport: Transport | None = None
        self._clock = clock
        self._model = _setting(self.settings.openrouter_ocr_model)
        self.model_name = self._model or "not-configured"
        self.categoriser_model_name = self.model_name
        # The model's dated slug, known once the catalogue is read.
        self.model_version = NOT_STARTED
        self._catalogue: Catalogue | None = None
        self._lock = threading.Lock()

    # Start-up -----------------------------------------------------------------

    def start(self) -> None:
        """Check the settings and read the catalogue.

        Without a model the service refuses to start, with a message naming what
        to set. Without a key it starts, logs that, and `/ocr` answers 501
        `openrouter_key_missing`. A model that is unknown, takes no images or has
        no strict zero-retention endpoint stops it too. A catalogue that cannot
        be read now (no network) is only logged: it is read again before the
        first call, and no call is made without it.
        """
        missing = missing_settings(self.settings)
        if "OPENROUTER_OCR_MODEL" in missing:
            raise BackendConfigError("openrouter_model_missing", _missing_message(missing))
        if missing:
            logger.error(_missing_message(missing))
        try:
            self._current_catalogue()
        except BackendConfigError:
            raise
        except BackendError as error:
            logger.warning("%s", error.message)

    def stop(self) -> None:
        with self._lock:
            transport, self._transport = self._transport, None
            self._catalogue = None
        if transport is not None:
            transport.close()

    @property
    def catalogue(self) -> Catalogue | None:
        """The last catalogue read (the allowed endpoints), or None before the first."""
        return self._catalogue

    def _transport_or_new(self) -> Transport:
        if self._transport is None:
            self._transport = self._make_transport()
        return self._transport

    def _current_catalogue(self) -> Catalogue:
        """The catalogue, read again when it is older than `CATALOGUE_TTL_SECONDS`."""
        assert self._model is not None
        with self._lock:
            now = self._clock()
            catalogue = self._catalogue
            if catalogue is None or now - catalogue.read_at >= CATALOGUE_TTL_SECONDS:
                catalogue = read_catalogue(
                    self._transport_or_new(),
                    self._model,
                    structured=self.settings.openrouter_structured_output,
                    now=now,
                )
                self._catalogue = catalogue
                self.model_version = catalogue.model_version
            return catalogue

    # One receipt ----------------------------------------------------------------

    def _api_key(self) -> str:
        missing = missing_settings(self.settings)
        if "OPENROUTER_OCR_MODEL" in missing:
            raise BackendConfigError("openrouter_model_missing", _missing_message(missing))
        if missing:
            raise BackendConfigError("openrouter_key_missing", _missing_message(missing))
        key = self.settings.openrouter_api_key
        assert key is not None
        return key.get_secret_value().strip()

    def request_body(
        self,
        catalogue: Catalogue,
        messages: Sequence[Mapping[str, str]],
        images: Sequence[Image.Image],
    ) -> dict[str, Any]:
        """The chat request: the fixed prompt, the photos, the privacy preferences.

        Nothing else goes in: no user, session, metadata or trace field.
        """
        structured = bool(catalogue.structured_endpoints)
        system, user = messages
        body: dict[str, Any] = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": system["content"]},
                {
                    "role": "user",
                    "content": [
                        *(image_part(image) for image in images),
                        {"type": "text", "text": user["content"]},
                    ],
                },
            ],
            "temperature": 0,
            "max_tokens": self.settings.openrouter_max_tokens,
            "stream": False,
            "provider": _provider_preferences(catalogue),
        }
        if structured:
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": SCHEMA_NAME, "strict": True, "schema": ANSWER_SCHEMA},
            }
        return body

    def _call(self, body: Mapping[str, Any], catalogue: Catalogue, calls: list[Call]) -> str:
        transport = self._transport_or_new()
        api_key = self._api_key()
        started = time.perf_counter()
        try:
            response = transport.post_json(
                CHAT_URL, body, api_key=api_key, timeout=self.settings.openrouter_timeout
            )
        except httpx.TimeoutException:
            raise BackendError(
                504, "openrouter_timeout", "The hosted model did not answer in time."
            ) from None
        except httpx.HTTPError:
            raise BackendError(
                502, "openrouter_unreachable", "OpenRouter could not be reached."
            ) from None
        seconds = time.perf_counter() - started
        if response.status_code != 200:
            raise upstream_error(response.status_code)
        return self._read_answer(response.text, seconds, catalogue, calls)

    def _read_answer(
        self, text: str, seconds: float, catalogue: Catalogue, calls: list[Call]
    ) -> str:
        """The answer text. The call's accounting goes into `calls` before any check."""
        bad = BackendError(
            502, "openrouter_bad_response", "The hosted model's answer had an unexpected shape."
        )
        try:
            document = _decode(text)
        except ValueError:
            raise bad from None
        if not isinstance(document, dict):
            raise bad
        usage = document.get("usage") if isinstance(document.get("usage"), dict) else {}
        provider = document.get("provider")
        choices = document.get("choices")
        choice = choices[0] if isinstance(choices, list) and choices else None
        call = Call(
            seconds=seconds,
            prompt_tokens=_count(usage.get("prompt_tokens")),
            completion_tokens=_count(usage.get("completion_tokens")),
            cost_usd=_decimal(usage.get("cost")),
            provider=provider if isinstance(provider, str) else None,
            model=document.get("model") if isinstance(document.get("model"), str) else None,
            finish_reason=(
                choice.get("finish_reason")
                if isinstance(choice, dict) and isinstance(choice.get("finish_reason"), str)
                else None
            ),
            structured_output=bool(catalogue.structured_endpoints),
        )
        calls.append(call)
        if call.provider not in catalogue.providers:
            # The request named only strict zero-retention endpoints; an answer from
            # anywhere else (or from an unnamed provider) is not accepted.
            logger.error("OpenRouter answered from a provider outside the zero-retention list")
            raise BackendError(
                424,
                "openrouter_provider_unverified",
                "The answer came from a provider that is not on the zero-retention list; "
                "it was discarded.",
            )
        if not isinstance(choice, dict) or isinstance(choice.get("error"), dict):
            raise BackendError(
                502, "openrouter_upstream_error", "The hosted model's service failed."
            )
        message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
        return _text_of(message.get("content"))

    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        self._api_key()
        catalogue = self._current_catalogue()
        pictures = prepare_images(images, self.settings.openrouter_ocr_image_max_side)
        calls: list[Call] = []

        def ask(repair: Repair | None) -> str:
            body = self.request_body(catalogue, build_messages(len(pictures), repair), pictures)
            return self._call(body, catalogue, calls)

        try:
            parsed = read_with_repair(ask)
        except OcrParseError as error:
            error.diagnostics.update(_accounting(calls))
            raise
        except BackendError as error:
            error.diagnostics = _accounting(calls)
            raise
        receipt, report = postprocess(parsed.receipt)
        return Extraction(
            receipt=receipt,
            prompt_version=PROMPT_VERSION,
            repaired=parsed.repaired,
            diagnostics={**_accounting(calls), "postprocess": report.as_dict()},
        )

    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        raise BackendNotImplementedError("The openrouter backend cannot categorise items yet.")


def _provider_preferences(catalogue: Catalogue) -> dict[str, Any]:
    """The routing preferences: the privacy constants plus the allowed endpoints."""
    structured = bool(catalogue.structured_endpoints)
    endpoints = catalogue.structured_endpoints if structured else catalogue.endpoints
    preferences: dict[str, Any] = {
        "only": list(endpoints),
        "require_parameters": structured,
        "allow_fallbacks": True,
    }
    # Applied last, so nothing above can replace them.
    preferences.update(PRIVACY_PREFERENCES)
    return preferences


def _accounting(calls: Sequence[Call]) -> dict[str, Any]:
    """Totals and per-call accounting of the model calls. Never the answer text.

    `cost_usd` is the sum of the costs OpenRouter reported, as a decimal
    string; None when any call did not report one (a partial sum would
    understate the cost).
    """
    costs = [call.cost_usd for call in calls]
    known = [cost for cost in costs if cost is not None]
    total = sum(known, Decimal("0")) if calls and len(known) == len(costs) else None

    def tokens(values: list[int | None]) -> int:
        return sum(value or 0 for value in values)

    return {
        "model_calls": len(calls),
        "prompt_tokens": tokens([call.prompt_tokens for call in calls]),
        "generation_tokens": tokens([call.completion_tokens for call in calls]),
        "finish_reasons": [call.finish_reason for call in calls],
        "cost_usd": None if total is None else plain(total),
        "latency_seconds": round(sum(call.seconds for call in calls), 3),
        "providers": [call.provider for call in calls],
        "structured_output": any(call.structured_output for call in calls),
        "calls": [call.as_dict() for call in calls],
    }
