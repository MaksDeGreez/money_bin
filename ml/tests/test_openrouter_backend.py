"""The openrouter backend against a fake transport: no network, no key, no model.

The key below is an obvious fake. The catalogue (OpenRouter's public model and
zero-retention endpoint lists) and every chat answer are invented.
"""

import base64
import json
import logging
from collections.abc import Mapping
from decimal import Decimal
from io import BytesIO
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.backends import BackendConfigError, BackendError, ImageInput
from app.backends.openrouter import (
    CATALOGUE_TTL_SECONDS,
    CHAT_URL,
    MODELS_URL,
    PRIVACY_PREFERENCES,
    USER_AGENT,
    ZDR_ENDPOINTS_URL,
    HttpResponse,
    HttpxTransport,
    OpenRouterBackend,
    encode_jpeg,
    key_is_valid,
    read_catalogue,
    upstream_error,
)
from app.config import Settings
from app.main import create_app
from app.ocr.parsing import OcrParseError
from app.ocr.prompt import ANSWER_SCHEMA, build_messages
from tests.conftest import encoded_image

FAKE_KEY = "sk-or-test-not-a-real-key-0000"
MODEL = "example/vision-model"
DATED_MODEL = "example/vision-model-20260101"

ANSWER = """{"kind": "fiscal", "merchant": "Example Market", "fiscal_number": "4000000001",
"receipt_number": "000123", "date": "2026-01-15", "time": "12:34", "total": "71,40",
"currency": "UAH", "card_last4": null, "items": [
{"name": "Milk", "quantity": "1", "unit_price": "42,50", "amount": "42,50", "discount": null},
{"name": "Bread", "quantity": "1", "unit_price": "28,90", "amount": "28,90", "discount": null}
]}"""

STRUCTURED = ["temperature", "max_tokens", "response_format", "structured_outputs"]


def endpoint(tag: str, provider: str, *, model: str = MODEL, **extra: Any) -> dict[str, Any]:
    entry = {
        "name": f"{provider} | {model}",
        "model_id": model,
        "tag": tag,
        "provider_name": provider,
        "supported_parameters": ["temperature", "max_tokens"],
        "safety_retention": False,
    }
    entry.update(extra)
    return entry


MODELS = {
    "data": [
        {
            "id": MODEL,
            "canonical_slug": DATED_MODEL,
            "architecture": {"input_modalities": ["text", "image"]},
        },
        {
            "id": "example/text-only",
            "canonical_slug": "example/text-only-20260101",
            "architecture": {"input_modalities": ["text"]},
        },
    ]
}

ZDR = {
    "data": [
        endpoint("alpha", "Alpha", supported_parameters=STRUCTURED),
        endpoint("beta/fp8", "Beta"),
        # May keep prompts its classifiers flag: never used.
        endpoint("gamma", "Gamma", supported_parameters=STRUCTURED, safety_retention=True),
        # No flag at all is not proof of zero retention: never used.
        {
            key: value
            for key, value in endpoint("delta", "Delta").items()
            if key != "safety_retention"
        },
        endpoint("alpha", "Alpha", model="example/other-model"),
    ]
}


def chat_answer(
    content: Any = ANSWER,
    *,
    provider: Any = "Alpha",
    cost: str | None = "0.000123456789",
    finish_reason: str = "stop",
    **extra: Any,
) -> str:
    usage = '"prompt_tokens": 2500, "completion_tokens": 1500'
    if cost is not None:
        # The cost is a JSON number in the raw text, so the test sees whether it stays exact.
        usage += f', "cost": {cost}'
    document = {
        "id": "gen-1",
        "model": DATED_MODEL,
        "provider": provider,
        "choices": [
            {"finish_reason": finish_reason, "message": {"role": "assistant", "content": content}}
        ],
        **extra,
    }
    if provider is None:
        del document["provider"]
    text = json.dumps(document)
    return text[:-1] + f', "usage": {{{usage}}}}}'


class FakeTransport:
    """Answers GETs from the catalogue and POSTs from a list; records every call."""

    def __init__(
        self,
        *answers: HttpResponse | Exception,
        models: Any = MODELS,
        zdr: Any = ZDR,
        catalogue_status: int = 200,
    ) -> None:
        self.answers = list(answers) or [HttpResponse(200, chat_answer())]
        self.models = models
        self.zdr = zdr
        self.catalogue_status = catalogue_status
        self.gets: list[str] = []
        self.posts: list[dict[str, Any]] = []
        self.closed = False

    def get(self, url: str, *, timeout: float) -> HttpResponse:
        self.gets.append(url)
        if isinstance(self.catalogue_status, Exception):
            raise self.catalogue_status
        document = self.models if url == MODELS_URL else self.zdr
        text = document if isinstance(document, str) else json.dumps(document)
        return HttpResponse(self.catalogue_status, text)

    def post_json(
        self, url: str, body: Mapping[str, Any], *, api_key: str, timeout: float
    ) -> HttpResponse:
        self.posts.append({"url": url, "body": body, "api_key": api_key, "timeout": timeout})
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def close(self) -> None:
        self.closed = True


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "ocr_backend": "openrouter",
        "openrouter_api_key": FAKE_KEY,
        "openrouter_ocr_model": MODEL,
    }
    values.update(overrides)
    return Settings(**values)


def make_backend(
    transport: FakeTransport | None = None, clock: Clock | None = None, **overrides: Any
) -> tuple[OpenRouterBackend, FakeTransport]:
    transport = transport or FakeTransport()
    backend = OpenRouterBackend(settings(**overrides), transport=transport, clock=clock or Clock())
    return backend, transport


def jpeg(width: int = 400, height: int = 900, name: str = "rcpt_000123_1.jpg") -> ImageInput:
    return ImageInput(
        content=encoded_image(width, height), content_type="image/jpeg", filename=name
    )


def sent_images(body: Mapping[str, Any]) -> list[Image.Image]:
    parts = body["messages"][1]["content"]
    images = []
    for part in parts:
        if part["type"] != "image_url":
            continue
        prefix = "data:image/jpeg;base64,"
        url = part["image_url"]["url"]
        assert url.startswith(prefix)
        images.append(Image.open(BytesIO(base64.b64decode(url[len(prefix) :]))))
    return images


def api_client(backend: OpenRouterBackend) -> TestClient:
    return TestClient(create_app(settings(), backend=backend), raise_server_exceptions=False)


def ocr(client: TestClient, *images: tuple[str, bytes]) -> httpx.Response:
    files = [("images", (name, content, "image/jpeg")) for name, content in images]
    return client.post(
        "/ocr", files=files or [("images", ("r.jpg", encoded_image(), "image/jpeg"))]
    )


# The request -----------------------------------------------------------------------


def test_the_request_for_one_image() -> None:
    backend, transport = make_backend()

    extraction = backend.extract_receipt([jpeg()])

    (post,) = transport.posts
    assert post["url"] == CHAT_URL
    assert post["api_key"] == FAKE_KEY
    # What is left of the receipt's 100 seconds.
    assert 90 < post["timeout"] <= 100
    body = post["body"]
    assert set(body) == {
        "model",
        "messages",
        "temperature",
        "max_tokens",
        "stream",
        "provider",
        "response_format",
    }
    assert body["model"] == MODEL
    assert body["temperature"] == 0
    assert body["max_tokens"] == 3072
    assert body["stream"] is False
    system, user = body["messages"]
    expected = build_messages(1)
    assert system == {"role": "system", "content": expected[0]["content"]}
    assert user["role"] == "user"
    image, text = user["content"]
    assert image["type"] == "image_url"
    assert set(image) == {"type", "image_url"}
    assert set(image["image_url"]) == {"url"}
    assert text == {"type": "text", "text": expected[1]["content"]}
    assert body["provider"] == {
        "only": ["alpha"],
        "allow_fallbacks": True,
        "zdr": True,
        "data_collection": "deny",
    }
    assert body["response_format"] == {
        "type": "json_schema",
        "json_schema": {"name": "receipt", "strict": True, "schema": ANSWER_SCHEMA},
    }
    assert extraction.receipt.total == Decimal("71.40")
    assert extraction.repaired is False
    assert extraction.diagnostics["structured_output"] is True


def test_the_request_for_three_images_keeps_their_order() -> None:
    backend, transport = make_backend()

    backend.extract_receipt([jpeg(300, 900), jpeg(301, 900), jpeg(302, 900)])

    body = transport.posts[0]["body"]
    parts = body["messages"][1]["content"]
    assert [part["type"] for part in parts] == ["image_url"] * 3 + ["text"]
    assert [image.size[0] for image in sent_images(body)] == [300, 301, 302]
    assert parts[-1]["text"] == build_messages(3)[1]["content"]


def test_nothing_but_the_photos_and_the_prompt_is_sent() -> None:
    backend, transport = make_backend()

    backend.extract_receipt([jpeg(name="rcpt_000123_1.jpg"), jpeg(name="secret-name.jpg")])

    text = json.dumps(transport.posts[0]["body"])
    for absent in ("rcpt_000123", "secret-name", FAKE_KEY, "session_id", "metadata"):
        assert absent not in text
    body = transport.posts[0]["body"]
    assert not {"user", "trace", "session_id", "metadata", "plugins", "models"} & set(body)


def test_photos_are_scaled_to_the_setting() -> None:
    backend, transport = make_backend(openrouter_ocr_image_max_side=512)

    backend.extract_receipt([jpeg(400, 2000)])

    (image,) = sent_images(transport.posts[0]["body"])
    assert max(image.size) == 512


def test_no_exif_or_gps_survives_in_what_is_sent() -> None:
    original = Image.new("RGB", (120, 80), "white")
    exif = Image.Exif()
    exif[0x010F] = "ExampleMaker"  # Make
    exif[0x0110] = "ExamplePhone"  # Model
    exif[0x0112] = 6  # Orientation: turn 90 degrees
    gps = exif.get_ifd(0x8825)
    gps[1] = "N"
    gps[2] = (50.0, 27.0, 0.0)
    gps[3] = "E"
    gps[4] = (30.0, 31.0, 0.0)
    buffer = BytesIO()
    original.save(buffer, "JPEG", exif=exif, comment=b"example comment")
    content = buffer.getvalue()
    assert b"ExampleMaker" in content
    assert Image.open(BytesIO(content)).getexif().get_ifd(0x8825)
    backend, transport = make_backend()

    backend.extract_receipt([ImageInput(content=content, content_type="image/jpeg")])

    url = transport.posts[0]["body"]["messages"][1]["content"][0]["image_url"]["url"]
    sent = base64.b64decode(url.split(",", 1)[1])
    for marker in (b"Exif", b"ExampleMaker", b"ExamplePhone", b"example comment", b"ICC_PROFILE"):
        assert marker not in sent
    image = Image.open(BytesIO(sent))
    assert dict(image.getexif()) == {}
    assert not set(image.info) & {"exif", "comment", "icc_profile", "xmp"}
    # Turned upright from the orientation before the tag was dropped.
    assert image.size == (80, 120)


def test_encode_jpeg_ignores_metadata_kept_in_the_image() -> None:
    image = Image.new("RGB", (10, 10))
    image.info["exif"] = b"Exif\x00\x00not-real"
    image.info["icc_profile"] = b"profile"
    image.info["comment"] = b"note"

    sent = encode_jpeg(image)

    assert b"not-real" not in sent and b"profile" not in sent and b"note" not in sent


def test_without_structured_endpoints_the_answer_is_plain_json() -> None:
    zdr = {"data": [endpoint("beta/fp8", "Beta")]}
    backend, transport = make_backend(
        FakeTransport(HttpResponse(200, chat_answer(provider="Beta")), zdr=zdr)
    )

    extraction = backend.extract_receipt([jpeg()])

    body = transport.posts[0]["body"]
    assert "response_format" not in body
    assert body["provider"] == {
        "only": ["beta/fp8"],
        "allow_fallbacks": True,
        "zdr": True,
        "data_collection": "deny",
    }
    assert extraction.diagnostics["structured_output"] is False
    assert extraction.receipt.total == Decimal("71.40")


def test_structured_output_can_be_turned_off() -> None:
    backend, transport = make_backend(openrouter_structured_output=False)

    backend.extract_receipt([jpeg()])

    body = transport.posts[0]["body"]
    assert "response_format" not in body
    assert body["provider"]["only"] == ["alpha", "beta/fp8"]
    assert "require_parameters" not in body["provider"]


@pytest.mark.parametrize(
    "overrides",
    [
        {},
        {"openrouter_structured_output": False},
        {
            "openrouter_timeout": 30,
            "openrouter_max_tokens": 10,
            "openrouter_ocr_image_max_side": 256,
        },
    ],
)
def test_the_privacy_preferences_are_in_every_request(overrides: dict[str, Any]) -> None:
    backend, transport = make_backend(
        FakeTransport(HttpResponse(200, chat_answer("not json")), HttpResponse(200, chat_answer())),
        **overrides,
    )

    backend.extract_receipt([jpeg()])

    assert len(transport.posts) == 2
    for post in transport.posts:
        provider = post["body"]["provider"]
        assert provider["zdr"] is True
        assert provider["data_collection"] == "deny"
        assert provider["only"]
        assert "gamma" not in provider["only"] and "delta" not in provider["only"]


def test_the_privacy_preferences_are_fixed_constants() -> None:
    assert dict(PRIVACY_PREFERENCES) == {"zdr": True, "data_collection": "deny"}
    names = set(Settings.model_fields)
    assert not {name for name in names if "zdr" in name or "data_collection" in name}


# The catalogue ---------------------------------------------------------------------


def test_the_catalogue_keeps_only_endpoints_without_any_retention() -> None:
    catalogue = read_catalogue(FakeTransport(), MODEL, structured=True, now=0.0)

    assert catalogue.endpoints == ("alpha", "beta/fp8")
    assert catalogue.structured_endpoints == ("alpha",)
    assert catalogue.providers == frozenset({"alpha", "beta"})
    assert catalogue.model_version == DATED_MODEL


def test_the_catalogue_is_read_without_the_key() -> None:
    backend, transport = make_backend()

    backend.start()

    assert transport.gets == [MODELS_URL, ZDR_ENDPOINTS_URL]
    assert backend.model_version == DATED_MODEL
    assert backend.model_name == MODEL


def test_the_model_can_be_named_by_its_dated_slug() -> None:
    catalogue = read_catalogue(FakeTransport(), DATED_MODEL, structured=True, now=0.0)

    assert catalogue.endpoints == ("alpha", "beta/fp8")


@pytest.mark.parametrize(
    ("model", "zdr", "code"),
    [
        ("example/unknown", ZDR, "openrouter_model_unknown"),
        ("example/text-only", ZDR, "openrouter_model_without_images"),
        (
            MODEL,
            {"data": [endpoint("gamma", "Gamma", safety_retention=True)]},
            "openrouter_no_zdr_endpoint",
        ),
        (MODEL, {"data": []}, "openrouter_no_zdr_endpoint"),
    ],
)
def test_a_model_without_a_strict_zero_retention_endpoint_does_not_start(
    model: str, zdr: Any, code: str
) -> None:
    backend, transport = make_backend(FakeTransport(zdr=zdr), openrouter_ocr_model=model)

    with pytest.raises(BackendConfigError) as error:
        backend.start()

    assert error.value.code == code
    assert error.value.status_code == 501
    with pytest.raises(BackendConfigError):
        backend.extract_receipt([jpeg()])
    assert transport.posts == []


@pytest.mark.parametrize(
    ("transport", "detail"),
    [
        (FakeTransport(catalogue_status=500), "HTTP 500"),
        (FakeTransport(models="not json"), "not JSON"),
        (FakeTransport(zdr={"endpoints": []}), "unexpected shape"),
        (FakeTransport(catalogue_status=httpx.ConnectTimeout("slow")), "timeout"),  # type: ignore[arg-type]
        (FakeTransport(catalogue_status=httpx.ConnectError("down")), "network error"),  # type: ignore[arg-type]
    ],
)
def test_without_the_catalogue_nothing_is_sent(transport: FakeTransport, detail: str) -> None:
    backend, _ = make_backend(transport)

    backend.start()  # logged only; the next call reads it again
    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_catalogue_unavailable"
    assert error.value.status_code == 503
    assert detail in error.value.message
    assert transport.posts == []


def test_the_catalogue_is_read_again_after_an_hour() -> None:
    clock = Clock()
    backend, transport = make_backend(clock=clock)

    backend.extract_receipt([jpeg()])
    backend.extract_receipt([jpeg()])
    clock.now += CATALOGUE_TTL_SECONDS
    backend.extract_receipt([jpeg()])

    assert transport.gets == [MODELS_URL, ZDR_ENDPOINTS_URL] * 2


def test_an_endpoint_that_starts_retaining_is_dropped_at_the_next_read() -> None:
    clock = Clock()
    transport = FakeTransport()
    backend, _ = make_backend(transport, clock=clock)
    backend.extract_receipt([jpeg()])

    transport.zdr = {"data": [endpoint("alpha", "Alpha", safety_retention=True)]}
    clock.now += CATALOGUE_TTL_SECONDS
    with pytest.raises(BackendConfigError):
        backend.extract_receipt([jpeg()])

    assert len(transport.posts) == 1


# Start-up and settings ---------------------------------------------------------------


def test_without_a_model_the_service_does_not_start() -> None:
    backend = OpenRouterBackend(Settings(ocr_backend="openrouter"), transport=FakeTransport())

    with pytest.raises(BackendConfigError) as error:
        backend.start()

    assert error.value.code == "openrouter_model_missing"
    assert "OPENROUTER_OCR_MODEL and OPENROUTER_API_KEY" in error.value.message
    with pytest.raises(BackendConfigError), TestClient(create_app(backend=backend)):
        pass  # pragma: no cover - the lifespan refuses to start


def test_without_a_key_the_service_starts_and_ocr_answers_501(
    caplog: pytest.LogCaptureFixture,
) -> None:
    transport = FakeTransport()
    backend = OpenRouterBackend(
        Settings(ocr_backend="openrouter", openrouter_ocr_model=MODEL), transport=transport
    )

    with TestClient(create_app(backend=backend)) as client:
        health = client.get("/health").json()
        response = ocr(client)

    assert health["model_version"] == DATED_MODEL
    assert response.status_code == 501
    assert response.json()["error"] == {
        "code": "openrouter_key_missing",
        "message": "The openrouter backend is not configured: set OPENROUTER_API_KEY "
        "(OPENROUTER_OCR_MODEL is a model id from openrouter.ai/models; see ml/README.md).",
    }
    assert "OPENROUTER_API_KEY" in caplog.text
    assert transport.posts == []
    assert transport.closed


def test_a_blank_key_counts_as_missing() -> None:
    backend, transport = make_backend(openrouter_api_key="  ")

    with pytest.raises(BackendConfigError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_key_missing"
    assert transport.posts == []


def test_the_key_never_reaches_a_repr_a_log_an_error_or_the_diagnostics(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    answers = [
        HttpResponse(401, json.dumps({"error": {"message": f"bad key {FAKE_KEY}"}})),
        HttpResponse(200, chat_answer("not json")),
        HttpResponse(200, chat_answer(provider="Elsewhere")),
    ]
    backend, _ = make_backend(FakeTransport(*answers))
    texts = [repr(backend.settings), str(backend.settings.model_dump())]
    client = api_client(backend)
    for _ in answers:
        response = ocr(client)
        texts.append(response.text)
    backend2, _ = make_backend()
    texts.append(json.dumps(backend2.extract_receipt([jpeg()]).diagnostics))

    texts.append(caplog.text)
    for text in texts:
        assert FAKE_KEY not in text


def test_health_reports_the_dated_slug_once_started() -> None:
    backend, _ = make_backend()

    assert backend.model_version == "not-started"
    with TestClient(create_app(backend=backend)) as client:
        body = client.get("/health").json()

    assert body == {
        "status": "ok",
        "backend": "openrouter",
        "model_name": MODEL,
        "model_version": DATED_MODEL,
    }


def test_categorise_is_not_implemented() -> None:
    backend, _ = make_backend()

    with pytest.raises(NotImplementedError):
        backend.categorise(["milk"])


def test_stop_closes_the_transport_and_is_safe_twice() -> None:
    backend, transport = make_backend()
    backend.start()

    backend.stop()
    backend.stop()

    assert transport.closed
    assert backend.catalogue is None


# Repair and errors ---------------------------------------------------------------------


def test_the_repair_pass_sends_the_problems_and_the_photos_again() -> None:
    first = chat_answer("I cannot see a receipt.", cost="0.1")
    backend, transport = make_backend(
        FakeTransport(HttpResponse(200, first), HttpResponse(200, chat_answer()))
    )

    extraction = backend.extract_receipt([jpeg()])

    assert extraction.repaired is True
    first_body, second_body = (post["body"] for post in transport.posts)
    repair_text = second_body["messages"][1]["content"][-1]["text"]
    assert "Your previous answer could not be used" in repair_text
    assert "no JSON object" in repair_text
    assert len(sent_images(second_body)) == 1
    assert second_body["provider"] == first_body["provider"]
    assert extraction.diagnostics["model_calls"] == 2
    assert extraction.diagnostics["cost_usd"] == "0.100123456789"


def test_a_parse_failure_after_the_repair_pass_keeps_the_accounting() -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer("[]"))))

    with pytest.raises(OcrParseError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.diagnostics["model_calls"] == 2
    assert error.value.diagnostics["cost_usd"] == "0.000246913578"


def test_a_parse_failure_is_a_422_through_the_api() -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer("nothing"))))

    response = ocr(api_client(backend))

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "ocr_parse_failed"


def test_an_unreadable_image_is_refused_before_any_call() -> None:
    backend, transport = make_backend()

    response = ocr(api_client(backend), ("r.jpg", b"\xff\xd8\xff\xe0broken"))

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "image_unreadable"
    assert transport.posts == []


@pytest.mark.parametrize(
    ("status", "service_status", "code"),
    [
        (429, 503, "openrouter_rate_limited"),
        (408, 502, "openrouter_upstream_error"),
        (500, 502, "openrouter_upstream_error"),
        (502, 502, "openrouter_upstream_error"),
        (503, 502, "openrouter_upstream_error"),
        (524, 502, "openrouter_upstream_error"),
        (529, 502, "openrouter_upstream_error"),
        (401, 424, "openrouter_auth_failed"),
        (402, 424, "openrouter_payment_required"),
        (403, 424, "openrouter_refused"),
        (404, 424, "openrouter_no_matching_endpoint"),
        (400, 424, "openrouter_bad_request"),
        (413, 424, "openrouter_bad_request"),
        (422, 424, "openrouter_bad_request"),
    ],
)
def test_upstream_errors_map_to_the_service_contract(
    status: int, service_status: int, code: str
) -> None:
    echo = json.dumps({"error": {"code": status, "message": "ECHO of the request: Milk 42,50"}})
    backend, _ = make_backend(FakeTransport(HttpResponse(status, echo)))

    response = ocr(api_client(backend))

    assert response.status_code == service_status
    error = response.json()["error"]
    assert error["code"] == code
    assert "ECHO" not in error["message"] and "Milk" not in error["message"]
    # 5xx other than 501 is retried by the Rails job; 4xx is permanent.
    assert upstream_error(status).transient == (service_status >= 500)


@pytest.mark.parametrize(
    ("failure", "status", "code"),
    [
        (httpx.ReadTimeout("slow"), 504, "openrouter_timeout"),
        (httpx.ConnectError("refused"), 502, "openrouter_unreachable"),
    ],
)
def test_network_failures_are_transient(failure: Exception, status: int, code: str) -> None:
    backend, _ = make_backend(FakeTransport(failure))

    response = ocr(api_client(backend))

    assert response.status_code == status
    assert response.json()["error"]["code"] == code


@pytest.mark.parametrize(
    ("text", "status", "code"),
    [
        ("<html>gateway</html>", 502, "openrouter_bad_response"),
        ("[1, 2]", 502, "openrouter_bad_response"),
        (chat_answer(provider="Gamma"), 424, "openrouter_provider_unverified"),
        (chat_answer(provider=None), 424, "openrouter_provider_unverified"),
        (chat_answer(provider=7), 424, "openrouter_provider_unverified"),
        (
            json.dumps({"provider": "Alpha", "choices": [{"error": {"code": 502}}]}),
            502,
            "openrouter_upstream_error",
        ),
        (json.dumps({"provider": "Alpha", "choices": []}), 502, "openrouter_upstream_error"),
        (json.dumps({"error": {"code": 502, "message": "x"}}), 502, "openrouter_upstream_error"),
        (
            json.dumps({"provider": "Gamma", "choices": [{"error": {"code": 502}}]}),
            424,
            "openrouter_provider_unverified",
        ),
    ],
)
def test_odd_answers(text: str, status: int, code: str) -> None:
    backend, transport = make_backend(FakeTransport(HttpResponse(200, text)))

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert (error.value.status_code, error.value.code) == (status, code)
    assert len(transport.posts) == 1


def test_an_answer_from_an_unexpected_provider_keeps_its_accounting() -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer(provider="Gamma"))))

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.diagnostics["model_calls"] == 1
    assert error.value.diagnostics["providers"] == ["Gamma"]
    assert error.value.diagnostics["cost_usd"] == "0.000123456789"


def test_an_answer_in_parts_is_joined() -> None:
    parts = [{"type": "text", "text": ANSWER[:40]}, {"type": "text", "text": ANSWER[40:]}, 3]
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer(parts))))

    extraction = backend.extract_receipt([jpeg()])

    assert extraction.receipt.total == Decimal("71.40")


def test_an_empty_answer_goes_to_the_repair_pass() -> None:
    backend, transport = make_backend(
        FakeTransport(HttpResponse(200, chat_answer(None)), HttpResponse(200, chat_answer()))
    )

    assert backend.extract_receipt([jpeg()]).repaired is True
    assert len(transport.posts) == 2


# Accounting ------------------------------------------------------------------------


def test_the_accounting_of_one_call() -> None:
    backend, _ = make_backend()

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert diagnostics["model_calls"] == 1
    assert diagnostics["prompt_tokens"] == 2500
    assert diagnostics["generation_tokens"] == 1500
    assert diagnostics["cost_usd"] == "0.000123456789"
    assert diagnostics["providers"] == ["Alpha"]
    assert diagnostics["finish_reasons"] == ["stop"]
    (call,) = diagnostics["calls"]
    assert call["model"] == DATED_MODEL
    assert call["structured_output"] is True
    assert call["seconds"] >= 0
    assert "postprocess" in diagnostics
    json.dumps(diagnostics)  # everything is plain JSON


@pytest.mark.parametrize(
    ("costs", "expected"),
    [
        (["0.1", "0.2"], "0.3"),
        (["0.000000001", "1e-9"], "0.000000002"),
        (["0", "0"], "0"),
        (["0.25", None], None),
    ],
)
def test_costs_are_added_as_decimals(costs: list[str | None], expected: str | None) -> None:
    answers = [HttpResponse(200, chat_answer("bad", cost=costs[0]))]
    answers.append(HttpResponse(200, chat_answer(cost=costs[1])))
    backend, _ = make_backend(FakeTransport(*answers))

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert diagnostics["cost_usd"] == expected
    if expected is not None:
        assert Decimal(diagnostics["cost_usd"]) == sum(
            (Decimal(cost) for cost in costs if cost), Decimal(0)
        )


def test_a_string_cost_is_read_and_junk_is_ignored() -> None:
    answers = [
        HttpResponse(200, chat_answer("bad", cost='"0.5"')),
        HttpResponse(200, chat_answer(cost='"lots"')),
    ]
    backend, _ = make_backend(FakeTransport(*answers))

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert [call["cost_usd"] for call in diagnostics["calls"]] == ["0.5", None]
    assert diagnostics["cost_usd"] is None


def test_odd_usage_values_are_ignored() -> None:
    text = json.dumps(
        {
            "provider": "Alpha",
            "choices": [{"message": {"content": ANSWER}}],
            "usage": {"prompt_tokens": True, "completion_tokens": "9", "cost": [1]},
        }
    )
    backend, _ = make_backend(FakeTransport(HttpResponse(200, text)))

    (call,) = backend.extract_receipt([jpeg()]).diagnostics["calls"]

    assert (call["prompt_tokens"], call["completion_tokens"], call["cost_usd"]) == (
        None,
        None,
        None,
    )
    assert call["finish_reason"] is None


# The real HTTP client, against httpx's mock transport ---------------------------------


class Recorder:
    def __init__(self, chat_status: int = 200) -> None:
        self.requests: list[httpx.Request] = []
        self.chat_status = chat_status

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url)
        if url == MODELS_URL:
            return httpx.Response(200, json=MODELS)
        if url == ZDR_ENDPOINTS_URL:
            return httpx.Response(200, json=ZDR)
        return httpx.Response(self.chat_status, text=chat_answer())


def test_the_real_client_sends_only_these_headers(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HTTPS_PROXY", "http://127.0.0.1:9")
    recorder = Recorder()
    transport = HttpxTransport(httpx.MockTransport(recorder))
    backend = OpenRouterBackend(settings(), transport=transport)

    backend.extract_receipt([jpeg()])
    backend.stop()

    catalogue_requests, chat = recorder.requests[:2], recorder.requests[2]
    for request in catalogue_requests:
        assert request.method == "GET"
        assert "authorization" not in request.headers
        assert request.headers["user-agent"] == USER_AGENT
    assert chat.method == "POST"
    assert str(chat.url) == CHAT_URL
    assert set(chat.headers) == {
        "host",
        "accept",
        "accept-encoding",
        "connection",
        "user-agent",
        "content-length",
        "content-type",
        "authorization",
    }
    assert chat.headers["authorization"] == f"Bearer {FAKE_KEY}"
    assert chat.headers["user-agent"] == USER_AGENT
    assert chat.headers["content-type"] == "application/json"
    assert 90 < chat.extensions["timeout"]["read"] <= 100
    assert chat.extensions["timeout"]["connect"] == 10.0
    body = json.loads(chat.content)
    assert body["provider"]["zdr"] is True
    assert b"rcpt_000123" not in chat.content


def test_the_real_client_reads_nothing_from_the_environment() -> None:
    backend = OpenRouterBackend(settings())

    transport = backend._transport_or_new()

    assert isinstance(transport, HttpxTransport)
    assert transport._client.trust_env is False
    assert transport._client.follow_redirects is False
    backend.stop()


def test_the_real_client_does_not_follow_a_redirect() -> None:
    def redirect(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return Recorder()(request)
        return httpx.Response(307, headers={"location": "https://elsewhere.example/"})

    backend = OpenRouterBackend(settings(), transport=HttpxTransport(httpx.MockTransport(redirect)))

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_bad_request"


# Review fixes ----------------------------------------------------------------------


def test_a_slug_that_would_also_reach_a_retaining_endpoint_is_not_used() -> None:
    zdr = {
        "data": [
            endpoint("alpha", "Alpha", supported_parameters=STRUCTURED),
            endpoint("alpha/eu", "Alpha", safety_retention=True),
            endpoint("beta/fp8", "Beta"),
            # Another model's retaining endpoint does not matter.
            endpoint("beta/fp8/flex", "Beta", model="example/other-model", safety_retention=True),
        ]
    }

    catalogue = read_catalogue(FakeTransport(zdr=zdr), MODEL, structured=True, now=0.0)

    assert catalogue.endpoints == ("beta/fp8",)
    assert catalogue.structured_endpoints == ()
    assert catalogue.providers == frozenset({"beta"})


def test_a_slug_shared_with_a_retaining_endpoint_is_not_used() -> None:
    zdr = {"data": [endpoint("alpha", "Alpha"), endpoint("alpha", "Alpha", safety_retention=None)]}

    with pytest.raises(BackendConfigError):
        read_catalogue(FakeTransport(zdr=zdr), MODEL, structured=True, now=0.0)


@pytest.mark.parametrize(
    "architecture", [None, "text+image", {"input_modalities": "text+image"}, {}]
)
def test_odd_model_entries_are_refused(architecture: Any) -> None:
    models = {"data": [{"id": MODEL, "architecture": architecture}]}

    with pytest.raises(BackendConfigError) as error:
        read_catalogue(FakeTransport(models=models), MODEL, structured=True, now=0.0)

    assert error.value.code == "openrouter_model_without_images"


def test_provider_names_are_compared_without_case() -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer(provider=" alpha "))))

    assert backend.extract_receipt([jpeg()]).receipt.total == Decimal("71.40")


def test_after_an_unverified_provider_nothing_more_is_sent() -> None:
    transport = FakeTransport(
        HttpResponse(200, chat_answer(provider="Gamma")), HttpResponse(200, chat_answer())
    )
    backend, _ = make_backend(transport)

    with pytest.raises(BackendError):
        backend.extract_receipt([jpeg()])
    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_provider_unverified"
    assert error.value.status_code == 424
    assert "restarted" in error.value.message
    assert len(transport.posts) == 1


def test_a_receipt_has_one_time_budget() -> None:
    backend, transport = make_backend(openrouter_timeout=4)

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert (error.value.status_code, error.value.code) == (504, "openrouter_timeout")
    assert transport.posts == []


def test_the_repair_pass_is_skipped_without_time_for_it(monkeypatch: pytest.MonkeyPatch) -> None:
    import app.backends.openrouter as module

    ticks = iter([0.0, 1.0, 1.0, 98.0])
    monkeypatch.setattr(module.time, "perf_counter", lambda: next(ticks))
    backend, transport = make_backend(FakeTransport(HttpResponse(200, chat_answer("bad"))))

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_timeout"
    assert len(transport.posts) == 1
    assert transport.posts[0]["timeout"] == 99.0
    assert error.value.diagnostics["model_calls"] == 1


def test_unknown_token_counts_stay_unknown() -> None:
    text = json.dumps({"provider": "Alpha", "choices": [{"message": {"content": ANSWER}}]})
    backend, _ = make_backend(FakeTransport(HttpResponse(200, text)))

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert diagnostics["prompt_tokens"] is None
    assert diagnostics["generation_tokens"] is None
    assert diagnostics["cost_usd"] is None


def test_cookies_from_the_catalogue_never_reach_the_chat_request() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        response = Recorder()(request)
        response.headers["set-cookie"] = "tracker=abc; Domain=openrouter.ai; Path=/"
        recorded.append(request)
        return response

    recorded: list[httpx.Request] = []
    backend = OpenRouterBackend(settings(), transport=HttpxTransport(httpx.MockTransport(handler)))

    backend.extract_receipt([jpeg()])
    backend.extract_receipt([jpeg()])
    backend.stop()

    assert len(recorded) == 4
    assert all("cookie" not in request.headers for request in recorded)


@pytest.mark.parametrize(
    ("failure", "status", "code", "lost_calls"),
    [
        (httpx.ConnectTimeout("slow"), 504, "openrouter_timeout", 0),
        (httpx.ReadTimeout("slow"), 504, "openrouter_timeout", 1),
        (httpx.ConnectError("refused"), 502, "openrouter_unreachable", 0),
        (httpx.RemoteProtocolError("cut"), 502, "openrouter_unreachable", 1),
    ],
)
def test_a_call_that_may_have_been_paid_makes_the_cost_unknown(
    failure: Exception, status: int, code: str, lost_calls: int
) -> None:
    transport = FakeTransport(HttpResponse(200, chat_answer("bad", cost="0.5")), failure)
    backend, _ = make_backend(transport)

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert (error.value.status_code, error.value.code) == (status, code)
    diagnostics = error.value.diagnostics
    assert diagnostics["model_calls"] == 1 + lost_calls
    assert diagnostics["cost_usd"] == (None if lost_calls else "0.5")


def test_an_unreadable_answer_makes_the_cost_unknown() -> None:
    transport = FakeTransport(
        HttpResponse(200, chat_answer("bad", cost="0.5")), HttpResponse(200, "<html>")
    )
    backend, _ = make_backend(transport)

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_bad_response"
    assert error.value.diagnostics["model_calls"] == 2
    assert error.value.diagnostics["cost_usd"] is None


@pytest.mark.parametrize(
    ("document", "status", "code"),
    [
        ({"error": {"code": 503, "message": "unavailable"}}, 502, "openrouter_upstream_error"),
        ({"error": {"code": 429, "message": "slow down"}}, 503, "openrouter_rate_limited"),
        ({"error": {"code": 403, "message": "flagged"}}, 424, "openrouter_refused"),
        ({"error": {"code": "x"}}, 502, "openrouter_upstream_error"),
        ({"choices": [{"error": {"code": 429}}]}, 503, "openrouter_rate_limited"),
        (
            {"provider": "Alpha", "choices": [{"error": {"code": 402}}]},
            424,
            "openrouter_payment_required",
        ),
    ],
)
def test_errors_inside_a_200_answer_are_mapped_by_their_code(
    document: dict[str, Any], status: int, code: str
) -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, json.dumps(document))))

    with pytest.raises(BackendError) as error:
        backend.extract_receipt([jpeg()])

    assert (error.value.status_code, error.value.code) == (status, code)
    assert "unavailable" not in error.value.message and "flagged" not in error.value.message


def test_costs_keep_every_digit() -> None:
    long_cost = "0.12345678901234567890123456789"
    answers = [
        HttpResponse(200, chat_answer("bad", cost=long_cost)),
        HttpResponse(200, chat_answer(cost="1000000.000000000000000000000001")),
    ]
    backend, _ = make_backend(FakeTransport(*answers))

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert diagnostics["calls"][0]["cost_usd"] == long_cost
    assert diagnostics["cost_usd"] == "1000000.12345678901234567890123556789"


@pytest.mark.parametrize("cost", ["1" + "0" * 60, "1e-60", "1e60"])
def test_an_absurd_cost_counts_as_unknown(cost: str) -> None:
    backend, _ = make_backend(FakeTransport(HttpResponse(200, chat_answer(cost=f'"{cost}"'))))

    assert backend.extract_receipt([jpeg()]).diagnostics["cost_usd"] is None


@pytest.mark.parametrize("key", ["sk-or-v1-abc\nINJECTED", "two words", "ключ"])
def test_a_malformed_key_is_refused_before_it_reaches_the_http_client(
    key: str, caplog: pytest.LogCaptureFixture
) -> None:
    transport = FakeTransport()
    backend, _ = make_backend(transport, openrouter_api_key=key)

    backend.start()
    with pytest.raises(BackendConfigError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.code == "openrouter_key_invalid"
    assert key not in error.value.message and key not in caplog.text
    assert "OPENROUTER_API_KEY" in caplog.text
    assert transport.posts == []


def test_a_key_is_valid_only_when_set() -> None:
    assert not key_is_valid(Settings())
    assert key_is_valid(settings())


def test_a_waiting_request_sends_nothing_after_an_unverified_provider() -> None:
    import threading

    release = threading.Event()
    entered = threading.Event()

    class Slow(FakeTransport):
        def post_json(self, url: str, body: Mapping[str, Any], **kwargs: Any) -> HttpResponse:
            entered.set()
            release.wait(5)
            return super().post_json(url, body, **kwargs)

    transport = Slow(HttpResponse(200, chat_answer(provider="Gamma")))
    backend, _ = make_backend(transport)
    errors: list[str] = []

    def read() -> None:
        try:
            backend.extract_receipt([jpeg()])
        except BackendError as error:
            errors.append(error.code)

    first = threading.Thread(target=read)
    first.start()
    assert entered.wait(5)
    second = threading.Thread(target=read)
    second.start()
    second.join(0.2)
    assert second.is_alive()  # waiting for the first call to be checked
    release.set()
    first.join(5)
    second.join(5)

    assert errors == ["openrouter_provider_unverified"] * 2
    assert len(transport.posts) == 1


def test_a_receipt_cost_longer_than_one_call_cost_is_kept_by_the_summary() -> None:
    from evaluation.common import cost_summary

    answers = [
        HttpResponse(200, chat_answer("bad", cost='"0.5"')),
        HttpResponse(200, chat_answer(cost='"0.' + "0" * 48 + '1"')),
    ]
    backend, _ = make_backend(FakeTransport(*answers))

    diagnostics = backend.extract_receipt([jpeg()]).diagnostics

    assert diagnostics["cost_usd"] == "0.5" + "0" * 47 + "1"
    summary = cost_summary([{"diagnostics": diagnostics}])
    assert summary is not None
    assert summary["total_usd"] == diagnostics["cost_usd"]
    assert summary["complete"] is True


def test_exact_sum_keeps_every_digit() -> None:
    from app.decimals import exact_sum

    big = Decimal("9" * 50 + "E+50")
    tiny = Decimal("1E-50")

    assert exact_sum([big, tiny, Decimal("0")]) - big == tiny
    assert exact_sum([]) == 0
    assert exact_sum([Decimal("0"), Decimal("0.00")]) == 0


def test_bounded_refuses_what_is_not_a_price() -> None:
    from app.decimals import bounded

    assert bounded(Decimal("0.25")) == Decimal("0.25")
    for value in ("NaN", "Infinity", "1E+51", "1E-51", "1" * 51):
        assert bounded(Decimal(value)) is None
