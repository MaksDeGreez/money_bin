"""The hosted OCR backend, and the zero-retention OpenRouter client it shares.

`OpenRouterBackend` reads receipts with a vision-language model. It uses the
same prompt, parsing with one repair pass and post-processing as the local
backend (`app.ocr`), so a comparison differs only in the model.

`OpenRouterClient` holds everything that keeps a hosted call private: the
catalogue of strict zero-retention endpoints, the fixed provider preferences,
the provider check of every answer and the halt after a wrong one, the key, the
deadline and the accounting. The OCR backend, the hosted item categoriser
(`app.categorise.openrouter`) and the decision-model categoriser
(`app.categorise.decisions`, through `app.decisions`) all call through it, so
the rules exist once. A chat model is called with `call` (chat completions), a
decision model with `decide` (the Decisions API); both go through the same
catalogue, key, lock, halt and provider check.

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
  the list afterwards; an answer from anywhere else stops the backend until
  the service is restarted.
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
import re
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from http.cookiejar import CookieJar, DefaultCookiePolicy
from io import BytesIO
from typing import Any, Protocol

import httpx
from PIL import Image

from app.backends.base import (
    Backend,
    BackendConfigError,
    BackendError,
    Extraction,
    ImageInput,
)
from app.config import Settings
from app.decimals import bounded, exact_sum
from app.ocr.images import prepare_images
from app.ocr.parsing import OcrParseError, read_with_repair
from app.ocr.postprocess import postprocess
from app.ocr.prompt import ANSWER_SCHEMA, PROMPT_VERSION, Repair, build_messages

logger = logging.getLogger(__name__)

API_BASE = "https://openrouter.ai/api/v1"
CHAT_URL = f"{API_BASE}/chat/completions"
MODELS_URL = f"{API_BASE}/models"
# Decision models are listed only when every output modality is asked for.
ALL_MODELS_URL = f"{MODELS_URL}?output_modalities=all"
DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
DECISIONS_MODALITY = "decisions"
ZDR_ENDPOINTS_URL = f"{API_BASE}/endpoints/zdr"

# How long the list of zero-retention endpoints is trusted before it is read again.
CATALOGUE_TTL_SECONDS = 3600.0
# Opening a connection. The whole receipt has its own limit (OPENROUTER_TIMEOUT).
CONNECT_TIMEOUT_SECONDS = 10.0
CATALOGUE_TIMEOUT_SECONDS = 10.0
# The most of a chat call's time that sending the photos may take.
UPLOAD_TIMEOUT_SECONDS = 20.0
# A call is not started with less time than this left for the receipt, nor a
# repair call with less than the first call took: it would be paid and lost.
MIN_CALL_SECONDS = 10.0
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
OCR_MODEL_SETTING = "OPENROUTER_OCR_MODEL"

# Set when an answer came from a provider outside the zero-retention list. From
# then on no hosted call of any task (OCR or categorisation) is sent until the
# service restarts: routing can no longer be trusted, and a person has to look.
_HALT = threading.Event()
# One chat call at a time, from sending to checking the provider, so no request
# can slip out after another one found a wrong provider. The Rails OCR queue
# sends one request at a time anyway.
_CALL_LOCK = threading.Lock()


def reset_halt() -> None:
    """Forget a halt. Only the tests call it; the service restarts instead."""
    _HALT.clear()


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


class _NoCookies(CookieJar):
    """A cookie jar that never keeps a cookie: no request ever carries one."""

    def __init__(self) -> None:
        super().__init__(policy=DefaultCookiePolicy(allowed_domains=[]))


def _client(transport: httpx.BaseTransport | None) -> httpx.Client:
    return httpx.Client(
        transport=transport,
        trust_env=False,
        follow_redirects=False,
        # The jar itself, not a copy: httpx copies the cookies of a `Cookies` object
        # into a fresh jar of its own, which would keep cookies again.
        cookies=_NoCookies(),
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )


class HttpxTransport:
    """The real transport: httpx, no environment, no redirects, no cookies.

    `trust_env=False`: no proxy settings and no `.netrc` credentials from the
    environment. Only the headers set here (plus httpx's own Host,
    Content-Length, Accept-Encoding and Connection) are sent. The anonymous
    catalogue reads and the keyed chat requests use two separate clients (no
    shared connection), and neither keeps a cookie.

    A chat request has a hard deadline: `timeout` seconds from its start. The
    connect, upload and read limits of httpx are shares of it, and the answer
    is read in chunks and abandoned as soon as the deadline passes (httpx's
    read limit applies between chunks, so a slowly trickling answer would
    otherwise run on).
    """

    def __init__(self, transport: httpx.BaseTransport | None = None) -> None:
        self._public = _client(transport)
        self._chat = _client(transport)

    def get(self, url: str, *, timeout: float) -> HttpResponse:
        response = self._public.get(
            url, timeout=httpx.Timeout(timeout, connect=min(CONNECT_TIMEOUT_SECONDS, timeout))
        )
        return HttpResponse(response.status_code, response.text)

    def post_json(
        self, url: str, body: Mapping[str, Any], *, api_key: str, timeout: float
    ) -> HttpResponse:
        deadline = time.perf_counter() + timeout
        connect = min(CONNECT_TIMEOUT_SECONDS, timeout * 0.1)
        upload = min(UPLOAD_TIMEOUT_SECONDS, timeout * 0.2)
        limits = httpx.Timeout(
            connect=connect, write=upload, pool=connect, read=timeout - connect - upload
        )
        with self._chat.stream(
            "POST",
            url,
            content=json.dumps(body, ensure_ascii=False).encode(),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            timeout=limits,
        ) as response:
            chunks = []
            for chunk in response.iter_bytes():
                chunks.append(chunk)
                if time.perf_counter() > deadline:
                    raise httpx.ReadTimeout("deadline passed", request=response.request)
            text = b"".join(chunks).decode("utf-8", errors="replace")
            return HttpResponse(response.status_code, text)

    def close(self) -> None:
        self._public.close()
        self._chat.close()


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
    # The endpoints that return token log-probabilities (`logprobs` and `top_logprobs`).
    logprob_endpoints: tuple[str, ...] = ()


@dataclass(frozen=True)
class Answer:
    """The text of a model's answer, and its token log-probabilities when the endpoint gave them.

    `logprobs` is the `choices[0].logprobs.content` list as OpenRouter returns it
    (one entry per token: `token`, `logprob`, `top_logprobs`), or None.
    """

    text: str
    logprobs: list[Any] | None = None


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


# A key is visible ASCII without spaces. Anything else (a pasted line break) is
# refused before it reaches the HTTP stack, whose errors would quote the header.
_KEY_PATTERN = re.compile(r"[\x21-\x7e]+")


def key_is_valid(settings: Settings) -> bool:
    key = settings.openrouter_api_key
    if key is None:
        return False
    return _KEY_PATTERN.fullmatch(key.get_secret_value().strip()) is not None


def missing_settings(settings: Settings, model_setting: str = OCR_MODEL_SETTING) -> list[str]:
    """The settings a hosted task needs that are not set (`model_setting` names its model)."""
    missing = []
    if _setting(getattr(settings, model_setting.lower())) is None:
        missing.append(model_setting)
    key = settings.openrouter_api_key
    if key is None or not key.get_secret_value().strip():
        missing.append("OPENROUTER_API_KEY")
    return missing


_INVALID_KEY_MESSAGE = (
    "OPENROUTER_API_KEY has characters an API key cannot have (a space or a line break?)."
)


def _missing_message(missing: Sequence[str], model_setting: str = OCR_MODEL_SETTING) -> str:
    return (
        f"The openrouter backend is not configured: set {' and '.join(missing)} "
        f"({model_setting} is a model id from openrouter.ai/models; see ml/README.md)."
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
    """A reported cost as a `Decimal`; None when it is missing, odd or absurdly long."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, Decimal | int):
        return bounded(Decimal(value))
    if isinstance(value, str):
        try:
            return bounded(Decimal(value))
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
            "openrouter_no_matching_endpoint",
            "No allowed zero-retention endpoint can serve the request now (HTTP 404).",
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


def _upstream_failed() -> BackendError:
    return BackendError(502, "openrouter_upstream_error", "The hosted model's service failed.")


def _unreachable() -> BackendError:
    return BackendError(502, "openrouter_unreachable", "OpenRouter could not be reached.")


def _embedded_error(document: Mapping[str, Any], choice: Any) -> BackendError | None:
    """The error an answer with HTTP 200 carries (top level or in its choice), or None.

    Mapped by its numeric code like an error status; no upstream text is kept.
    """
    for holder in (document, choice):
        error = holder.get("error") if isinstance(holder, dict) else None
        if isinstance(error, dict):
            code = error.get("code")
            if isinstance(code, int) and not isinstance(code, bool) and 400 <= code <= 599:
                return upstream_error(code)
            return _upstream_failed()
    return None


def _out_of_time() -> BackendError:
    return BackendError(
        504, "openrouter_timeout", "The hosted model did not answer within OPENROUTER_TIMEOUT."
    )


def _provider_unverified() -> BackendError:
    return BackendError(
        424,
        "openrouter_provider_unverified",
        "An answer came from a provider that is not on the zero-retention list; it was "
        "discarded, and nothing more is sent until the ML service is restarted.",
    )


def _catalogue_unavailable(detail: str) -> BackendError:
    return BackendError(
        503,
        "openrouter_catalogue_unavailable",
        f"The list of zero-retention endpoints could not be read ({detail}); "
        "nothing was sent to a hosted model.",
    )


def read_catalogue(
    transport: Transport,
    model: str,
    *,
    structured: bool,
    now: float,
    timeout: float = CATALOGUE_TIMEOUT_SECONDS,
    needs_images: bool = True,
    setting: str = OCR_MODEL_SETTING,
    decisions: bool = False,
) -> Catalogue:
    """Read the model and its strict zero-retention endpoints from OpenRouter's public lists.

    Raises `BackendConfigError` when the model is unknown, takes no images
    (when `needs_images`), is not a decision model (when `decisions`: those are
    listed only in the list of every output modality) or has no endpoint with
    zero retention and no Safety Retention, and a 503 `BackendError` when the
    lists cannot be read. `setting` names the model's setting in the messages.
    A moving alias (`~vendor/model-latest`) has no entry of its own in the
    zero-retention list, so it never has an endpoint here.
    """
    if decisions and model.startswith("~"):
        # A moving alias may start answering from another model at any time: a run must name
        # the model it measured.
        raise BackendConfigError(
            "openrouter_moving_alias",
            f"{setting} {model!r} is a moving alias; name a concrete model.",
        )
    models = _get_json(transport, ALL_MODELS_URL if decisions else MODELS_URL, timeout)
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
            f"{setting} {model!r} is not in OpenRouter's model list.",
        )
    architecture = entry.get("architecture")
    modalities = architecture.get("input_modalities") if isinstance(architecture, dict) else None
    if needs_images and (not isinstance(modalities, list) or "image" not in modalities):
        raise BackendConfigError(
            "openrouter_model_without_images",
            f"{setting} {model!r} does not take images.",
        )
    outputs = architecture.get("output_modalities") if isinstance(architecture, dict) else None
    if decisions and (not isinstance(outputs, list) or DECISIONS_MODALITY not in outputs):
        raise BackendConfigError(
            "openrouter_not_a_decision_model",
            f"{setting} {model!r} is not a decision model.",
        )
    ids = {entry.get("id"), entry.get("canonical_slug")} - {None}
    listed = [
        item
        for item in _data(_get_json(transport, ZDR_ENDPOINTS_URL, timeout))
        if isinstance(item, dict) and item.get("model_id") in ids
    ]
    # Only an explicit `false` with a slug and a provider name counts: anything
    # else is not proof, and is treated as an endpoint that may retain.
    strict = [
        item
        for item in listed
        if item.get("safety_retention") is False
        and isinstance(item.get("tag"), str)
        and item["tag"]
        and isinstance(item.get("provider_name"), str)
    ]
    retaining = [item for item in listed if not any(item is other for other in strict)]
    retaining_tags = [item["tag"] for item in retaining if isinstance(item.get("tag"), str)]
    retaining_names = {
        _provider_key(item["provider_name"])
        for item in retaining
        if isinstance(item.get("provider_name"), str)
    }
    endpoints = [
        item
        for item in strict
        # In `provider.only` a slug also matches the endpoints whose slugs extend it
        # (`vendor` matches `vendor/eu`): a slug that would also reach a retaining
        # endpoint of the model is not used.
        if not any(
            other == item["tag"] or other.startswith(item["tag"] + "/") for other in retaining_tags
        )
        # An answer names its provider, not its endpoint: a provider that also has a
        # retaining endpoint for the model could not be checked afterwards.
        and _provider_key(item["provider_name"]) not in retaining_names
    ]
    if any(
        not (isinstance(item.get("tag"), str) and item["tag"])
        and not isinstance(item.get("provider_name"), str)
        for item in retaining
    ):
        # A retaining entry with neither a slug nor a provider name could be any of
        # them: nothing can be shown to be safe.
        endpoints = []
    if not endpoints:
        raise BackendConfigError(
            "openrouter_no_zdr_endpoint",
            f"{setting} {model!r} has no endpoint with zero data retention "
            "and no Safety Retention; choose another model.",
        )
    tags = tuple(sorted({item["tag"] for item in endpoints}))
    structured_tags = tuple(
        sorted(
            {
                item["tag"]
                for item in endpoints
                if isinstance(item.get("supported_parameters"), list)
                and {"structured_outputs", "response_format"} <= set(item["supported_parameters"])
            }
        )
    )
    logprob_tags = tuple(
        sorted(
            {
                item["tag"]
                for item in endpoints
                if isinstance(item.get("supported_parameters"), list)
                and {"logprobs", "top_logprobs"} <= set(item["supported_parameters"])
            }
        )
    )
    return Catalogue(
        model_version=str(entry.get("canonical_slug") or entry.get("id")),
        endpoints=tags,
        structured_endpoints=structured_tags if structured else (),
        providers=frozenset(_provider_key(item["provider_name"]) for item in endpoints),
        read_at=now,
        logprob_endpoints=logprob_tags,
    )


def _provider_key(name: str) -> str:
    """A provider name compared without regard to case and outer spaces."""
    return name.strip().casefold()


def _get_json(transport: Transport, url: str, timeout: float) -> Any:
    try:
        response = transport.get(url, timeout=timeout)
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


class OpenRouterClient:
    """One hosted model behind the zero-retention rules: catalogue, key, calls, accounting.

    `model_setting` is the setting that names the model (`OPENROUTER_OCR_MODEL`,
    `OPENROUTER_CATEGORISE_MODEL`, `DECISIONS_MODEL`); `needs_images` refuses a
    model that takes no images, `decisions` one that is not a decision model. A
    given transport (the tests' fake) is used again after `stop()`;
    without one, a new HTTP client is made when the first call needs it.
    """

    def __init__(
        self,
        settings: Settings,
        model_setting: str,
        *,
        needs_images: bool,
        decisions: bool = False,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self.model_setting = model_setting
        self.needs_images = needs_images
        self.decisions = decisions
        self._make_transport: Callable[[], Transport] = (
            (lambda: transport) if transport is not None else HttpxTransport
        )
        self._transport: Transport | None = None
        self._clock = clock
        self.model = _setting(getattr(settings, model_setting.lower()))
        self.model_name = self.model or "not-configured"
        # The model's dated slug, known once the catalogue is read.
        self.model_version = NOT_STARTED
        self._catalogue: Catalogue | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        """Check the settings and read the catalogue.

        Without a model the service refuses to start, with a message naming what
        to set. Without a key it starts, logs that, and every call answers 501
        `openrouter_key_missing`. A model that is unknown, takes no images (when
        it must) or has no strict zero-retention endpoint stops it too. A
        catalogue that cannot be read now (no network) is only logged: it is
        read again before the first call, and no call is made without it.
        """
        missing = missing_settings(self.settings, self.model_setting)
        if self.model_setting in missing:
            raise BackendConfigError(
                "openrouter_model_missing", _missing_message(missing, self.model_setting)
            )
        if missing:
            logger.error(_missing_message(missing, self.model_setting))
        elif not key_is_valid(self.settings):
            logger.error(_INVALID_KEY_MESSAGE)
        try:
            self.current_catalogue()
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

    def transport_or_new(self) -> Transport:
        if self._transport is None:
            self._transport = self._make_transport()
        return self._transport

    def current_catalogue(self, timeout: float = CATALOGUE_TIMEOUT_SECONDS) -> Catalogue:
        """The catalogue, read again when it is older than `CATALOGUE_TTL_SECONDS`."""
        assert self.model is not None
        with self._lock:
            now = self._clock()
            catalogue = self._catalogue
            if catalogue is None or now - catalogue.read_at >= CATALOGUE_TTL_SECONDS:
                catalogue = read_catalogue(
                    self.transport_or_new(),
                    self.model,
                    structured=self.settings.openrouter_structured_output,
                    now=now,
                    timeout=timeout,
                    needs_images=self.needs_images,
                    setting=self.model_setting,
                    decisions=self.decisions,
                )
                self._catalogue = catalogue
                self.model_version = catalogue.model_version
            return catalogue

    def api_key(self) -> str:
        missing = missing_settings(self.settings, self.model_setting)
        if self.model_setting in missing:
            raise BackendConfigError(
                "openrouter_model_missing", _missing_message(missing, self.model_setting)
            )
        if missing:
            raise BackendConfigError(
                "openrouter_key_missing", _missing_message(missing, self.model_setting)
            )
        if not key_is_valid(self.settings):
            raise BackendConfigError("openrouter_key_invalid", _INVALID_KEY_MESSAGE)
        key = self.settings.openrouter_api_key
        assert key is not None
        return key.get_secret_value().strip()

    def check_not_halted(self) -> None:
        if _HALT.is_set():
            raise _provider_unverified()

    def call(
        self,
        body: Mapping[str, Any],
        catalogue: Catalogue,
        calls: list["Call"],
        deadline: float,
        *,
        structured: bool,
    ) -> Answer:
        """One chat call within `deadline`; its accounting goes into `calls`.

        `body` must carry `provider` from `provider_preferences`. Calls of every
        task go one at a time, and the halt and the deadline are checked after
        waiting for the previous one.
        """
        with _CALL_LOCK:
            text, seconds = self._post(CHAT_URL, body, calls, deadline, structured)
            return self._read_answer(text, seconds, catalogue, calls, structured)

    def decide(
        self,
        body: Mapping[str, Any],
        catalogue: Catalogue,
        calls: list["Call"],
        deadline: float,
    ) -> dict[str, Any]:
        """One Decisions API request within `deadline`; its accounting goes into `calls`.

        Returns the answer document once its provider is checked; reading the
        answers is the caller's (`app.decisions`). `body` must carry `provider`
        from `provider_preferences`. Under the same lock and halt as chat calls.
        """
        with _CALL_LOCK:
            text, seconds = self._post(DECISIONS_URL, body, calls, deadline, False)
            return self._read_decision(text, seconds, catalogue, calls)

    def _post(
        self,
        url: str,
        body: Mapping[str, Any],
        calls: list["Call"],
        deadline: float,
        structured: bool,
    ) -> tuple[str, float]:
        """POST one request (under `_CALL_LOCK`); the halt and the deadline are checked first."""
        transport = self.transport_or_new()
        api_key = self.api_key()
        self.check_not_halted()
        started = time.perf_counter()
        remaining = deadline - started
        needed = max([MIN_CALL_SECONDS, *(call.seconds for call in calls)])
        if remaining < needed:
            raise _out_of_time()

        def lost() -> None:
            # The request may have reached the model and been paid for; its cost is
            # unknown, which makes the task's cost unknown rather than too low.
            calls.append(Call(seconds=time.perf_counter() - started, structured_output=structured))

        try:
            response = transport.post_json(url, body, api_key=api_key, timeout=remaining)
        except httpx.ConnectTimeout:
            raise _out_of_time() from None
        except httpx.TimeoutException:
            lost()
            raise _out_of_time() from None
        except httpx.ConnectError:
            raise _unreachable() from None
        except httpx.HTTPError:
            lost()
            raise _unreachable() from None
        seconds = time.perf_counter() - started
        if response.status_code != 200:
            raise upstream_error(response.status_code)
        return response.text, seconds

    def _verify_provider(self, call: "Call", catalogue: Catalogue) -> None:
        if call.provider is None or _provider_key(call.provider) not in catalogue.providers:
            # The request named only strict zero-retention endpoints; an answer from
            # anywhere else (or from an unnamed provider) is not accepted, and nothing
            # more is sent until a person has looked at it and restarted the service.
            _HALT.set()
            logger.error(
                "OpenRouter answered from a provider outside the zero-retention list; "
                "nothing more is sent to OpenRouter until the service is restarted"
            )
            raise _provider_unverified()

    def _read_decision(
        self, text: str, seconds: float, catalogue: Catalogue, calls: list["Call"]
    ) -> dict[str, Any]:
        """A Decisions API answer document. The call's accounting goes into `calls` first."""
        try:
            document = _decode(text)
        except ValueError:
            document = None
        if not isinstance(document, dict):
            calls.append(Call(seconds=seconds))
            raise BackendError(
                502, "openrouter_bad_response", "The decision model's answer was not JSON."
            )
        usage = document.get("usage") if isinstance(document.get("usage"), dict) else {}
        provider = document.get("provider")
        call = Call(
            seconds=seconds,
            # The Decisions API counts `input_tokens` and `output_tokens` (output is free).
            prompt_tokens=_count(usage.get("input_tokens")),
            completion_tokens=_count(usage.get("output_tokens")),
            cost_usd=_decimal(usage.get("cost")),
            provider=provider if isinstance(provider, str) else None,
            model=document.get("model") if isinstance(document.get("model"), str) else None,
        )
        calls.append(call)
        embedded = _embedded_error(document, None)
        if embedded is not None and call.provider is None and not document.get("answers"):
            # An error reported with HTTP 200 before any provider answered (no answers at all).
            raise embedded
        self._verify_provider(call, catalogue)
        if embedded is not None:
            raise embedded
        return document

    def _read_answer(
        self,
        text: str,
        seconds: float,
        catalogue: Catalogue,
        calls: list["Call"],
        structured: bool,
    ) -> Answer:
        """The answer. The call's accounting goes into `calls` before any check."""
        bad = BackendError(
            502, "openrouter_bad_response", "The hosted model's answer had an unexpected shape."
        )
        try:
            document = _decode(text)
        except ValueError:
            document = None
        if not isinstance(document, dict):
            calls.append(Call(seconds=seconds, structured_output=structured))
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
            structured_output=structured,
        )
        calls.append(call)
        embedded = _embedded_error(document, choice)
        usable = (
            isinstance(choice, dict)
            and embedded is None
            and isinstance(choice.get("message"), dict)
        )
        if not usable and call.provider is None:
            # An error reported with HTTP 200 before any provider answered.
            raise embedded or _upstream_failed()
        self._verify_provider(call, catalogue)
        if not usable:
            raise embedded or _upstream_failed()
        assert isinstance(choice, dict)
        logprobs = choice.get("logprobs")
        content = logprobs.get("content") if isinstance(logprobs, dict) else None
        return Answer(
            text=_text_of(choice["message"].get("content")),
            logprobs=content if isinstance(content, list) else None,
        )


class OpenRouterBackend(Backend):
    name = "openrouter"

    def __init__(
        self,
        settings: Settings | None = None,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        super().__init__(settings)
        self._client = OpenRouterClient(
            self.settings, OCR_MODEL_SETTING, needs_images=True, transport=transport, clock=clock
        )
        self._model = self._client.model
        self.model_name = self._client.model_name

    @property
    def model_version(self) -> str:  # type: ignore[override]
        return self._client.model_version

    # Start-up -----------------------------------------------------------------

    def start(self) -> None:
        """Check the settings and read the catalogue (`OpenRouterClient.start`)."""
        self._client.start()

    def stop(self) -> None:
        self._client.stop()

    @property
    def catalogue(self) -> Catalogue | None:
        """The last catalogue read (the allowed endpoints), or None before the first."""
        return self._client.catalogue

    def _transport_or_new(self) -> Transport:
        return self._client.transport_or_new()

    # One receipt ----------------------------------------------------------------

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

    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        """Read one receipt within `OPENROUTER_TIMEOUT` seconds, catalogue and repair included."""
        deadline = time.perf_counter() + self.settings.openrouter_timeout
        self._client.api_key()
        self._client.check_not_halted()
        catalogue = self._client.current_catalogue(
            timeout=min(CATALOGUE_TIMEOUT_SECONDS, self.settings.openrouter_timeout)
        )
        pictures = prepare_images(images, self.settings.openrouter_ocr_image_max_side)
        calls: list[Call] = []
        structured = bool(catalogue.structured_endpoints)

        def ask(repair: Repair | None) -> str:
            body = self.request_body(catalogue, build_messages(len(pictures), repair), pictures)
            return self._client.call(body, catalogue, calls, deadline, structured=structured).text

        try:
            parsed = read_with_repair(ask)
        except OcrParseError as error:
            error.diagnostics.update(accounting(calls))
            raise
        except BackendError as error:
            error.diagnostics = accounting(calls)
            raise
        receipt, report = postprocess(parsed.receipt)
        return Extraction(
            receipt=receipt,
            prompt_version=PROMPT_VERSION,
            repaired=parsed.repaired,
            diagnostics={**accounting(calls), "postprocess": report.as_dict()},
        )


def _provider_preferences(catalogue: Catalogue) -> dict[str, Any]:
    """The OCR routing: the structured-output endpoints when there are any, else all."""
    structured = bool(catalogue.structured_endpoints)
    endpoints = catalogue.structured_endpoints if structured else catalogue.endpoints
    return provider_preferences(endpoints)


def provider_preferences(endpoints: Sequence[str]) -> dict[str, Any]:
    """The routing preferences: the privacy constants plus the allowed endpoints.

    `endpoints` must come from a `Catalogue` (strict zero-retention endpoints only).
    """
    # No `require_parameters`: `only` already names endpoints that support what is
    # asked for, and the flag would also exclude any endpoint that does not list
    # `temperature` or `max_tokens`.
    preferences: dict[str, Any] = {"only": list(endpoints), "allow_fallbacks": True}
    # Applied last, so nothing above can replace them.
    preferences.update(PRIVACY_PREFERENCES)
    return preferences


def accounting(calls: Sequence[Call]) -> dict[str, Any]:
    """Totals and per-call accounting of the model calls. Never the answer text.

    `cost_usd` is the sum of the costs OpenRouter reported, as a decimal
    string; None when any call did not report one (a partial sum would
    understate the cost).
    """
    costs = [call.cost_usd for call in calls]
    known = [cost for cost in costs if cost is not None]
    total = exact_sum(known) if calls and len(known) == len(costs) else None

    def tokens(values: list[int | None]) -> int | None:
        # Unknown, not zero, when a call did not report its count.
        return None if any(value is None for value in values) else sum(values)  # type: ignore[arg-type]

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
