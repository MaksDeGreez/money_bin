"""Batch mode against a fake transport: no network, no key, no model.

The key is an obvious fake; the catalogue, every batch document and every
answer are invented.
"""

import base64
import json
from collections.abc import Callable
from decimal import Decimal
from io import BytesIO
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

import app.batch.openrouter as batch_module
import app.batch.routes as routes_module
from app.backends import BackendConfigError, BackendError, ImageInput
from app.backends.openrouter import (
    _HALT,
    MODELS_URL,
    HttpResponse,
    OpenRouterBackend,
)
from app.batch.base import BatchReceipt
from app.batch.openrouter import (
    BATCHES_URL,
    NOT_ALLOWED_MESSAGE,
    HttpxBatchTransport,
    OpenRouterBatches,
    parse_providers,
)
from app.config import Settings
from app.main import create_app
from app.ocr.parsing import parse_answer
from app.ocr.postprocess import postprocess
from app.ocr.prompt import PROMPT_VERSION, SYSTEM_PROMPT, build_messages
from tests.conftest import encoded_image
from tests.test_openrouter_backend import ANSWER, FakeTransport, chat_answer

FAKE_KEY = "sk-or-test-not-a-real-key-0000"
MODEL = "example/vision-model"
DATED = "example/vision-model-20260101"
KEY_A = "AAAAAAAAAAAAAAAAAAAAAAAA"
KEY_B = "BBBBBBBBBBBBBBBBBBBBBBBB"
KEY_C = "CCCCCCCCCCCCCCCCCCCCCCCC"

MODELS = {
    "data": [
        {
            "id": MODEL + ":batch",
            "canonical_slug": DATED,
            "architecture": {"input_modalities": ["text", "image"]},
            "pricing": {"prompt": "0.0000005", "completion": "0.0000025"},
        },
        {"id": MODEL, "canonical_slug": DATED, "architecture": {"input_modalities": ["image"]}},
        {
            "id": "example/text-only:batch",
            "canonical_slug": "example/text-only-20260101",
            "architecture": {"input_modalities": ["text"]},
        },
    ]
}

STRUCTURED = ["max_tokens", "response_format", "structured_outputs"]


def batch_endpoint(tag: str, provider: str, prompt: str = "0.0000005", **extra: Any) -> dict:
    entry = {
        "name": f"{provider} | {DATED}:batch",
        "model_id": MODEL + ":batch",
        "tag": tag,
        "provider_name": provider,
        "pricing": {"prompt": prompt, "completion": "0.0000025"},
        "supported_parameters": STRUCTURED,
    }
    entry.update(extra)
    return entry


ENDPOINTS = {
    "data": {
        "id": MODEL + ":batch",
        "endpoints": [
            batch_endpoint("anthropic", "Anthropic"),
            batch_endpoint("openai", "OpenAI", prompt="0.0000006"),
            batch_endpoint("fireworks", "Fireworks"),
        ],
    }
}


def chat_body(content: Any = ANSWER, provider: str | None = "Anthropic", cost: str = "1") -> dict:
    document = json.loads(chat_answer(content, provider=provider))
    document["usage"]["cost"] = f"@@{cost}@@"
    return document


def batch_document(
    status: str = "validating",
    *,
    results: list[dict] | None = None,
    provider: str | None = "Anthropic",
    cost: str | None = None,
    error: dict | None = None,
    batch_id: str = "batch_abc123",
) -> str:
    document = {
        "id": batch_id,
        "object": "batch",
        "endpoint": "/v1/chat/completions",
        "model": MODEL,
        "status": status,
        "provider": provider,
        "created_at": 1767225600,
        "expires_at": "2026-01-02T00:00:00Z",
        "finalized_at": 1767229200 if status in ("completed", "failed", "expired") else None,
        "request_counts": {"total": 2, "completed": 1, "failed": 1},
        "usage": None if cost is None else {"cost": f"@@{cost}@@", "prompt_tokens": 10},
        "results": results,
        "error": error,
    }
    text = json.dumps(document)
    # Costs are JSON numbers in the raw text, so a test sees whether they stay exact.
    return text.replace('"@@', "").replace('@@"', "")


def result(key: str, body: Any = None, *, status_code: int = 200, error: Any = None) -> dict:
    if error is not None:
        return {"id": "r", "custom_id": key, "response": None, "error": error}
    return {
        "id": "r",
        "custom_id": key,
        "response": {"status_code": status_code, "request_id": "q", "body": body or chat_body()},
        "error": None,
    }


class FakeBatchTransport:
    """Public catalogue reads from fixed documents; keyed calls answered from a list, in order."""

    def __init__(
        self, *answers: HttpResponse | Exception, models: Any = MODELS, endpoints: Any = ENDPOINTS
    ) -> None:
        self.answers = list(answers)
        self.models = models
        self.endpoints = endpoints
        self.calls: list[dict[str, Any]] = []
        self.closed = False

    def request(
        self,
        method: str,
        url: str,
        *,
        api_key: str | None,
        body: bytes | None = None,
        timeout: float,
    ) -> HttpResponse:
        self.calls.append(
            {"method": method, "url": url, "api_key": api_key, "body": body, "timeout": timeout}
        )
        if api_key is None:
            assert method == "GET"
            if url == MODELS_URL:
                return HttpResponse(200, json.dumps(self.models))
            if url == f"{MODELS_URL}/{MODEL}:batch/endpoints":
                return HttpResponse(200, json.dumps(self.endpoints))
            return HttpResponse(404, '{"error": {"code": 404, "message": "not found"}}')
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    @property
    def keyed(self) -> list[dict[str, Any]]:
        return [call for call in self.calls if call["api_key"] is not None]

    def close(self) -> None:
        self.closed = True


def settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "ocr_backend": "openrouter",
        "openrouter_api_key": FAKE_KEY,
        "openrouter_ocr_model": MODEL,
        "openrouter_batch_allow_retention": True,
        "openrouter_batch_model": MODEL,
        "openrouter_batch_providers": "anthropic",
    }
    values.update(overrides)
    return Settings(**values)


def make(
    *answers: HttpResponse | Exception, **overrides: Any
) -> tuple[OpenRouterBatches, FakeBatchTransport]:
    transport = FakeBatchTransport(*answers)
    return OpenRouterBatches(settings(**overrides), transport=transport), transport


def photo(name: str = "rcpt_000777_1.jpg", **kwargs: Any) -> ImageInput:
    return ImageInput(
        content=encoded_image(300, 700, **kwargs), content_type="image/jpeg", filename=name
    )


def receipts(*keys: str) -> list[BatchReceipt]:
    return [BatchReceipt(key=key, images=[photo()]) for key in keys]


def accepted() -> HttpResponse:
    return HttpResponse(202, batch_document())


# The opt-in ------------------------------------------------------------------------


def test_every_method_refuses_without_the_opt_in() -> None:
    batches, transport = make(openrouter_batch_allow_retention=False)

    calls: list[Callable[[], Any]] = [
        lambda: batches.submit(receipts(KEY_A)),
        lambda: batches.status("batch_abc123"),
        lambda: batches.results("batch_abc123"),
        lambda: batches.delete("batch_abc123"),
        lambda: batches.estimate(1, 1),
    ]
    for call in calls:
        with pytest.raises(BackendConfigError) as raised:
            call()
        assert raised.value.code == "openrouter_batch_not_allowed"
        assert raised.value.status_code == 501
        assert "30 days" in raised.value.message
    capability = batches.capability()
    assert capability.available is False
    assert capability.code == "openrouter_batch_not_allowed"
    # Nothing was sent anywhere, not even a catalogue read.
    assert transport.calls == []


def test_only_true_opens_it_and_no_synchronous_setting_does() -> None:
    # Every synchronous setting at its most permissive, the opt-in left at its default.
    plain = Settings(
        ocr_backend="openrouter",
        openrouter_api_key=FAKE_KEY,
        openrouter_ocr_model=MODEL,
        openrouter_batch_model=MODEL,
        openrouter_batch_providers="anthropic",
        openrouter_structured_output=False,
        openrouter_timeout=600,
    )
    assert plain.openrouter_batch_allow_retention is False
    batches = OpenRouterBatches(plain, transport=FakeBatchTransport())
    assert batches.capability().code == "openrouter_batch_not_allowed"


def test_the_opt_in_is_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENROUTER_BATCH_ALLOW_RETENTION", "true")
    assert Settings().openrouter_batch_allow_retention is True
    monkeypatch.setenv("OPENROUTER_BATCH_ALLOW_RETENTION", "false")
    assert Settings().openrouter_batch_allow_retention is False


def test_http_endpoints_refuse_without_the_opt_in() -> None:
    backend = OpenRouterBackend(
        settings(openrouter_batch_allow_retention=False),
        transport=FakeTransport(),
        batch_transport=FakeBatchTransport(),
    )
    client = TestClient(create_app(settings(), backend=backend))

    capability = client.get("/ocr/batches/capability").json()
    assert capability["available"] is False
    assert capability["code"] == "openrouter_batch_not_allowed"
    for response in (
        client.get("/ocr/batches/batch_abc123"),
        client.get("/ocr/batches/batch_abc123/results"),
        client.delete("/ocr/batches/batch_abc123"),
        client.post("/ocr/batches/estimate", json={"receipts": 1, "images": 1}),
        client.post(
            "/ocr/batches",
            data={"manifest": json.dumps([{"key": KEY_A, "images": 1}])},
            files=[("images", ("a.jpg", encoded_image(), "image/jpeg"))],
        ),
    ):
        assert response.status_code == 501
        assert response.json()["error"] == {
            "code": "openrouter_batch_not_allowed",
            "message": NOT_ALLOWED_MESSAGE,
        }


def test_other_backends_answer_501(make_client: Callable[..., TestClient]) -> None:
    client = make_client("stub")

    capability = client.get("/ocr/batches/capability").json()
    assert capability["available"] is False
    assert capability["code"] == "backend_not_implemented"
    response = client.get("/ocr/batches/batch_abc123")
    assert response.status_code == 501
    assert response.json()["error"]["code"] == "backend_not_implemented"
    assert "OCR_BACKEND=openrouter" in response.json()["error"]["message"]


@pytest.mark.parametrize(
    ("overrides", "code"),
    [
        ({"openrouter_batch_model": None}, "openrouter_batch_model_missing"),
        ({"openrouter_batch_providers": " , "}, "openrouter_batch_providers_missing"),
        ({"openrouter_batch_providers": "fireworks"}, "openrouter_batch_provider_unsupported"),
        ({"openrouter_api_key": None}, "openrouter_key_missing"),
        ({"openrouter_api_key": "sk-or bad"}, "openrouter_key_invalid"),
        ({"openrouter_batch_model": "example/text-only"}, "openrouter_batch_model_unsupported"),
        ({"openrouter_batch_model": "example/no-batch"}, "openrouter_batch_model_unsupported"),
        ({"openrouter_batch_providers": "mistral"}, "openrouter_batch_no_provider"),
    ],
)
def test_settings_that_make_batches_unavailable(overrides: dict[str, Any], code: str) -> None:
    batches, transport = make(**overrides)

    capability = batches.capability()
    assert capability.available is False
    assert capability.code == code
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert raised.value.code == code
    assert transport.keyed == []


def test_a_model_without_a_batch_variant_is_refused_from_its_listing() -> None:
    # The plain model exists and takes images; only `:batch` is missing.
    models = {"data": [entry for entry in MODELS["data"] if entry["id"] != MODEL + ":batch"]}
    transport = FakeBatchTransport(models=models)
    batches = OpenRouterBatches(settings(), transport=transport)

    with pytest.raises(BackendConfigError) as raised:
        batches.estimate(1, 1)
    assert raised.value.code == "openrouter_batch_model_unsupported"


def test_a_halt_of_the_synchronous_path_stops_batches_too() -> None:
    _batches, transport = make(accepted())
    backend = OpenRouterBackend(settings(), transport=FakeTransport(), batch_transport=transport)
    _HALT.set()

    with pytest.raises(BackendError) as raised:
        backend.batches().submit(receipts(KEY_A))
    assert raised.value.code == "openrouter_provider_unverified"
    assert transport.keyed == []


def test_capability_when_available() -> None:
    batches, transport = make()

    capability = batches.capability()

    assert capability.available is True
    assert capability.model_name == MODEL
    assert capability.model_version == DATED
    assert capability.providers == ("anthropic",)
    assert capability.prompt_price_usd == Decimal("0.0000005")
    assert capability.retention_days == 30
    # Only the public lists were read, without the key.
    assert {call["api_key"] for call in transport.calls} == {None}


def test_parse_providers() -> None:
    assert parse_providers(" Anthropic, openai ,,anthropic") == ("anthropic", "openai")
    assert parse_providers(None) == ()


# What is sent ----------------------------------------------------------------------


def test_the_batch_holds_only_the_photos_and_the_fixed_prompt() -> None:
    batches, transport = make(accepted(), openrouter_batch_providers="anthropic,openai")
    secret_name = "rcpt_999999_private-name.jpg"
    two = BatchReceipt(
        key=KEY_B,
        images=[photo(secret_name, orientation=6), photo("second.jpg")],
    )

    status = batches.submit([BatchReceipt(key=KEY_A, images=[photo()]), two])

    assert status.id == "batch_abc123"
    assert status.state == "running"
    (call,) = transport.keyed
    assert call["method"] == "POST"
    assert call["url"] == BATCHES_URL
    assert call["api_key"] == FAKE_KEY
    text = call["body"].decode()
    assert secret_name not in text
    assert "rcpt_" not in text
    document = json.loads(text)
    # `requests` must come last: OpenRouter reads the body as a stream.
    assert list(document) == ["endpoint", "model", "provider", "completion_window", "requests"]
    assert document["endpoint"] == "/v1/chat/completions"
    assert document["model"] == MODEL
    assert document["provider"] == {"only": ["anthropic", "openai"], "allow_fallbacks": False}
    assert document["completion_window"] == "24h"
    assert [request["custom_id"] for request in document["requests"]] == [KEY_A, KEY_B]
    for request, count in zip(document["requests"], (1, 2), strict=True):
        assert set(request) == {"custom_id", "body"}
        body = request["body"]
        # The synchronous request without its routing: no provider, user, metadata, trace.
        assert set(body) == {
            "model",
            "messages",
            "temperature",
            "max_tokens",
            "stream",
            "response_format",
        }
        assert body["model"] == MODEL
        assert body["temperature"] == 0
        assert body["stream"] is False
        system, user = body["messages"]
        expected = build_messages(count)
        assert system == {"role": "system", "content": SYSTEM_PROMPT}
        *images, prompt = user["content"]
        assert prompt == {"type": "text", "text": expected[1]["content"]}
        assert len(images) == count
        for part in images:
            assert set(part) == {"type", "image_url"}
            url = part["image_url"]["url"]
            assert url.startswith("data:image/jpeg;base64,")
            picture = Image.open(BytesIO(base64.b64decode(url.split(",", 1)[1])))
            assert picture.format == "JPEG"
            # Re-encoded from the pixels: no EXIF (the orientation was applied, then dropped).
            assert "exif" not in picture.info
            assert not picture.getexif()
    # Turned upright from EXIF orientation 6: the 300 x 700 photo is now 700 x 300.
    first = document["requests"][1]["body"]["messages"][1]["content"][0]["image_url"]["url"]
    assert Image.open(BytesIO(base64.b64decode(first.split(",", 1)[1]))).size == (700, 300)


def test_the_estimate_is_returned_with_the_submission() -> None:
    batches, _transport = make(accepted())

    status = batches.submit(receipts(KEY_A, KEY_B))

    assert status.estimated_cost_usd == batches.estimate(2, 2).cost_usd


def test_without_structured_output_no_schema_is_asked_for() -> None:
    batches, transport = make(accepted(), openrouter_structured_output=False)
    batches.submit(receipts(KEY_A))
    body = json.loads(transport.keyed[0]["body"])["requests"][0]["body"]
    assert "response_format" not in body


def test_endpoints_without_structured_output_are_left_out_when_some_have_it() -> None:
    endpoints = {
        "data": {
            "endpoints": [
                batch_endpoint("anthropic", "Anthropic"),
                batch_endpoint("openai", "OpenAI", supported_parameters=["max_tokens"]),
            ]
        }
    }
    transport = FakeBatchTransport(accepted(), endpoints=endpoints)
    batches = OpenRouterBatches(
        settings(openrouter_batch_providers="anthropic,openai"), transport=transport
    )
    batches.submit(receipts(KEY_A))
    assert json.loads(transport.keyed[0]["body"])["provider"]["only"] == ["anthropic"]


# Limits ------------------------------------------------------------------------------


def test_receipt_count_and_keys_are_checked() -> None:
    batches, transport = make()
    for bad, code in (
        ([], "batch_too_many_receipts"),
        (receipts(*[f"{i:024d}" for i in range(101)]), "batch_too_many_receipts"),
        (receipts(KEY_A, KEY_A), "batch_invalid_key"),
        (receipts("short"), "batch_invalid_key"),
        (receipts("a/b" + "x" * 20), "batch_invalid_key"),
    ):
        with pytest.raises(BackendError) as raised:
            batches.submit(bad)
        assert raised.value.code == code
        assert raised.value.status_code == 422
    assert transport.keyed == []


def test_a_body_over_the_limit_is_not_sent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(batch_module, "MAX_BODY_BYTES", 1000)
    batches, transport = make()
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert (raised.value.status_code, raised.value.code) == (413, "batch_too_large")
    assert transport.keyed == []


def test_a_photo_over_the_providers_inline_limit_is_not_sent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(batch_module.INLINE_IMAGE_LIMITS, "anthropic", (100, None))
    batches, transport = make()
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert raised.value.code == "batch_image_too_large"
    assert KEY_A in raised.value.message
    assert transport.keyed == []


def test_the_providers_cap_on_requests_is_a_413() -> None:
    batches, _ = make(
        HttpResponse(413, '{"error": {"code": 413, "message": "at most 50 requests"}}')
    )
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert (raised.value.status_code, raised.value.code) == (413, "batch_too_large")
    assert "50" not in raised.value.message


# Refusals at submission ------------------------------------------------------------------

ZDR_REFUSAL = json.dumps(
    {
        "error": {
            "message": "Batch and other async APIs retain submitted data regardless of the "
            "provider's advertised retention policy, so this endpoint cannot be used with your "
            "Zero Data Retention settings. Update your privacy settings at "
            "https://openrouter.ai/settings/privacy.",
            "code": 422,
        }
    }
)


@pytest.mark.parametrize(
    ("answer", "status", "code"),
    [
        (HttpResponse(422, ZDR_REFUSAL), 424, "openrouter_batch_zdr_required"),
        (
            HttpResponse(
                400, '{"error": {"message": "Only public http(s) image URLs are supported"}}'
            ),
            424,
            "openrouter_batch_inline_images_refused",
        ),
        (HttpResponse(402, "{}"), 424, "openrouter_payment_required"),
        (HttpResponse(404, "{}"), 404, "batch_not_found"),
        (HttpResponse(429, "{}"), 503, "openrouter_rate_limited"),
        (HttpResponse(500, "{}"), 504, "openrouter_batch_submit_unknown"),
        (HttpResponse(502, "{}"), 504, "openrouter_batch_submit_unknown"),
        (HttpResponse(202, "not json"), 504, "openrouter_batch_submit_unknown"),
        (HttpResponse(408, "{}"), 502, "openrouter_upstream_error"),
        (httpx.ConnectError("refused"), 502, "openrouter_unreachable"),
        (httpx.ConnectTimeout("slow"), 502, "openrouter_unreachable"),
        (httpx.ReadTimeout("lost"), 504, "openrouter_batch_submit_unknown"),
        (httpx.RemoteProtocolError("cut"), 504, "openrouter_batch_submit_unknown"),
    ],
)
def test_submission_failures(answer: Any, status: int, code: str) -> None:
    batches, _ = make(answer)
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert (raised.value.status_code, raised.value.code) == (status, code)
    # Never the upstream text.
    assert "privacy settings at" not in raised.value.message
    assert "http(s)" not in raised.value.message


# Status ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("provider_status", "results", "state"),
    [
        ("validating", None, "running"),
        ("in_progress", None, "running"),
        ("finalizing", None, "running"),
        ("cancelling", None, "running"),
        ("something_new", None, "running"),
        ("completed", None, "running"),
        ("completed", [], "completed"),
        ("failed", None, "failed"),
        ("expired", None, "expired"),
        ("cancelled", None, "cancelled"),
    ],
)
def test_provider_states_map_to_the_services(
    provider_status: str, results: Any, state: str
) -> None:
    batches, _ = make(HttpResponse(200, batch_document(provider_status, results=results)))
    status = batches.status("batch_abc123")
    assert status.state == state
    assert status.provider_status == provider_status


def test_status_fields_and_exact_cost() -> None:
    batches, transport = make(
        HttpResponse(200, batch_document("in_progress", cost="0.000000123456789012345678"))
    )

    status = batches.status("batch_abc123")

    assert transport.keyed[0]["url"] == f"{BATCHES_URL}/batch_abc123"
    assert transport.keyed[0]["method"] == "GET"
    assert status.cost_usd == Decimal("0.000000123456789012345678")
    assert (status.request_total, status.request_completed, status.request_failed) == (2, 1, 1)
    assert (
        status.created_at is not None
        and status.created_at.isoformat() == "2026-01-01T00:00:00+00:00"
    )
    assert (
        status.expires_at is not None
        and status.expires_at.isoformat() == "2026-01-02T00:00:00+00:00"
    )
    assert status.finished_at is None
    assert status.provider == "Anthropic"


def test_failed_and_expired_batches_say_why_in_the_services_words() -> None:
    inline = {"message": "Request 'x' uses base64 images; only public image URLs are supported"}
    batches, _ = make(
        HttpResponse(200, batch_document("failed", error=inline)),
        HttpResponse(200, batch_document("failed", error={"message": "something odd"})),
        HttpResponse(200, batch_document("expired")),
        HttpResponse(200, batch_document("cancelled")),
    )
    codes = [batches.status("batch_abc123") for _ in range(4)]
    assert [status.error_code for status in codes] == [
        "openrouter_batch_inline_images_refused",
        "openrouter_batch_failed",
        "batch_expired",
        "batch_cancelled",
    ]
    assert "public URL" in (codes[0].error_message or "")
    assert "something odd" not in (codes[1].error_message or "")


def test_a_batch_id_is_checked_before_it_reaches_a_url() -> None:
    batches, transport = make()
    for bad in ("../models", "a?b=c", "", "x" * 129):
        with pytest.raises(BackendError) as raised:
            batches.status(bad)
        assert raised.value.code == "batch_invalid_id"
    assert transport.keyed == []


@pytest.mark.parametrize(
    ("answer", "code"),
    [
        (
            HttpResponse(404, '{"error": {"code": 404, "message": "Batch job x not found."}}'),
            "batch_not_found",
        ),
        (HttpResponse(410, "{}"), "batch_not_found"),
        (httpx.ReadTimeout("slow"), "openrouter_timeout"),
        (httpx.ConnectError("down"), "openrouter_unreachable"),
    ],
)
def test_status_failures(answer: Any, code: str) -> None:
    batches, _ = make(answer)
    with pytest.raises(BackendError) as raised:
        batches.status("batch_abc123")
    assert raised.value.code == code


# Results ------------------------------------------------------------------------------------


def completed(*results: dict, provider: str | None = "Anthropic") -> HttpResponse:
    return HttpResponse(
        200, batch_document("completed", results=list(results), provider=provider, cost="0.004")
    )


def test_a_batch_result_is_the_synchronous_result_of_the_same_answer() -> None:
    batches, _ = make(completed(result(KEY_A)))
    sync = OpenRouterBackend(settings(), transport=FakeTransport())

    (item,) = batches.results("batch_abc123").items
    expected = sync.extract_receipt([photo()])

    assert item.error is None
    assert item.extraction is not None
    assert item.extraction.receipt == expected.receipt
    assert item.extraction.receipt == postprocess(parse_answer(ANSWER))[0]
    assert item.extraction.prompt_version == PROMPT_VERSION == expected.prompt_version
    assert item.extraction.repaired is False
    assert item.provider == "Anthropic"
    assert item.cost_usd == Decimal("1")
    assert item.prompt_tokens == 2500
    assert item.completion_tokens == 1500
    assert item.model_version == "example/vision-model-20260101"


def test_partial_failure_per_key() -> None:
    batches, _ = make(
        completed(
            result(KEY_A),
            result(KEY_B, chat_body("this is not json")),
            result(KEY_C, error={"type": "invalid_request_error", "message": "max_tokens too big"}),
            result("DDDDDDDDDDDDDDDDDDDDDDDD", status_code=500),
            result(
                "EEEEEEEEEEEEEEEEEEEEEEEE",
                error={"message": "This request contains prohibited content."},
            ),
            result(
                "FFFFFFFFFFFFFFFFFFFFFFFF", error={"message": "Only public image URLs; no base64"}
            ),
            # Not a key: ignored and counted. A repeated key: the first one counts.
            result("../escape"),
            result(KEY_A, chat_body("{}")),
        )
    )

    found = batches.results("batch_abc123")

    by_key = {item.key: item for item in found.items}
    assert found.ignored == 2
    assert by_key[KEY_A].extraction is not None
    assert by_key[KEY_B].error is not None
    assert (by_key[KEY_B].error.code, by_key[KEY_B].error.retry_sync) == ("ocr_parse_failed", True)
    assert "repair pass" in by_key[KEY_B].error.message
    # A parse failure was paid for: its accounting is kept.
    assert by_key[KEY_B].cost_usd == Decimal("1")
    assert by_key[KEY_C].error is not None
    assert by_key[KEY_C].error.code == "openrouter_batch_request_failed"
    assert "max_tokens" not in by_key[KEY_C].error.message
    assert by_key["DDDDDDDDDDDDDDDDDDDDDDDD"].error.code == "openrouter_batch_request_failed"  # type: ignore[union-attr]
    refused = by_key["EEEEEEEEEEEEEEEEEEEEEEEE"].error
    assert refused is not None and (refused.code, refused.retry_sync) == (
        "openrouter_batch_refused",
        False,
    )
    inline = by_key["FFFFFFFFFFFFFFFFFFFFFFFF"].error
    assert inline is not None and inline.code == "openrouter_batch_inline_images_refused"


def test_answers_from_another_provider_are_not_used() -> None:
    batches, _ = make(
        completed(result(KEY_A), provider="Elsewhere"),
        completed(result(KEY_A, chat_body(provider="Elsewhere"))),
        completed(result(KEY_A, chat_body(provider=None)), provider=None),
    )
    for _ in range(3):
        (item,) = batches.results("batch_abc123").items
        assert item.error is not None
        assert item.error.code == "openrouter_batch_provider_unverified"
        assert item.extraction is None


def test_results_of_an_unfinished_batch_are_refused() -> None:
    batches, _ = make(HttpResponse(200, batch_document("in_progress")))
    with pytest.raises(BackendError) as raised:
        batches.results("batch_abc123")
    assert (raised.value.status_code, raised.value.code) == (409, "batch_not_finished")


# Delete -------------------------------------------------------------------------------------


def test_delete_reports_what_was_removed() -> None:
    answer = {
        "id": "batch_abc123",
        "object": "batch.deleted",
        "deletion": {
            "openrouter": "deleted",
            "upstream": {"provider": "Anthropic", "status": "deleted"},
        },
    }
    batches, transport = make(HttpResponse(200, json.dumps(answer)))

    deletion = batches.delete("batch_abc123")

    assert transport.keyed[0]["method"] == "DELETE"
    assert transport.keyed[0]["url"] == f"{BATCHES_URL}/batch_abc123"
    assert (deletion.openrouter, deletion.upstream_provider, deletion.upstream_status) == (
        "deleted",
        "Anthropic",
        "deleted",
    )


@pytest.mark.parametrize(
    ("status", "code"),
    [(409, "batch_running"), (404, "batch_not_found"), (503, "openrouter_upstream_error")],
)
def test_delete_failures(status: int, code: str) -> None:
    batches, _ = make(HttpResponse(status, "{}"))
    with pytest.raises(BackendError) as raised:
        batches.delete("batch_abc123")
    assert raised.value.code == code


# Cost ------------------------------------------------------------------------------------------


def test_the_estimate_is_exact_decimal_arithmetic() -> None:
    batches, _ = make(openrouter_batch_providers="anthropic,openai")

    estimate = batches.estimate(3, 5)

    prompt_text = sum(len(message["content"]) for message in build_messages(1))
    prompt_tokens = 3 * -(-prompt_text // 3) + 5 * 1600
    # The highest price of the allowed endpoints (openai's prompt price here).
    assert estimate.prompt_tokens == prompt_tokens
    assert estimate.cost_usd == prompt_tokens * Decimal("0.0000006") + 3 * 1200 * Decimal(
        "0.0000025"
    )
    assert estimate.cost_usd_max == prompt_tokens * Decimal("0.0000006") + 3 * 3072 * Decimal(
        "0.0000025"
    )
    assert estimate.cost_usd < estimate.cost_usd_max
    assert "Rough" in estimate.basis


# HTTP --------------------------------------------------------------------------------------------


def api(
    *answers: HttpResponse | Exception, **overrides: Any
) -> tuple[TestClient, FakeBatchTransport]:
    transport = FakeBatchTransport(*answers)
    backend = OpenRouterBackend(
        settings(**overrides), transport=FakeTransport(), batch_transport=transport
    )
    return TestClient(
        create_app(settings(), backend=backend), raise_server_exceptions=False
    ), transport


def create(client: TestClient, manifest: Any, images: list[bytes]) -> httpx.Response:
    return client.post(
        "/ocr/batches",
        data={"manifest": manifest if isinstance(manifest, str) else json.dumps(manifest)},
        files=[
            ("images", (f"p{i}.jpg", content, "image/jpeg")) for i, content in enumerate(images)
        ],
    )


def test_http_life_of_a_batch() -> None:
    deletion = {
        "id": "batch_abc123",
        "deletion": {
            "openrouter": "deleted",
            "upstream": {"provider": "Anthropic", "status": "unsupported"},
        },
    }
    client, transport = api(
        accepted(),
        HttpResponse(200, batch_document("in_progress", cost="0.001")),
        completed(result(KEY_A), result(KEY_B, chat_body("nope"))),
        HttpResponse(200, json.dumps(deletion)),
    )

    capability = client.get("/ocr/batches/capability").json()
    assert capability["available"] is True
    assert capability["prompt_price_usd"] == "0.0000005"
    estimate = client.post("/ocr/batches/estimate", json={"receipts": 2, "images": 3}).json()
    assert Decimal(estimate["cost_usd"]) < Decimal(estimate["cost_usd_max"])

    created = create(
        client, [{"key": KEY_A, "images": 2}, {"key": KEY_B, "images": 1}], [encoded_image()] * 3
    )
    assert created.status_code == 202, created.text
    body = created.json()
    assert body["id"] == "batch_abc123"
    assert body["state"] == "running"
    assert Decimal(body["estimated_cost_usd"]) > 0
    sent = json.loads(transport.keyed[0]["body"])
    assert [len(r["body"]["messages"][1]["content"]) - 1 for r in sent["requests"]] == [2, 1]

    status = client.get("/ocr/batches/batch_abc123").json()
    assert status["state"] == "running"
    assert status["cost_usd"] == "0.001"
    assert status["requests"] == {"total": 2, "completed": 1, "failed": 1}

    results = client.get("/ocr/batches/batch_abc123/results").json()
    assert results["counts"] == {"ok": 1, "parse_failed": 1, "failed": 0, "ignored": 0}
    assert results["batch"]["cost_usd"] == "0.004"
    ok, failed = sorted(results["results"], key=lambda item: item["key"])
    assert ok["status"] == "ok"
    ocr = ok["ocr"]
    assert ocr["receipt"]["total"] == "71.40"
    assert ocr["receipt"]["items"][0]["amount"] == "42.50"
    assert ocr["backend"] == "openrouter"
    assert ocr["model_name"] == MODEL
    assert ocr["model_version"] == DATED
    assert ocr["prompt_version"] == PROMPT_VERSION
    assert ocr["mode"] == "batch"
    assert ocr["batch_id"] == "batch_abc123"
    assert ocr["repaired"] is False
    assert ocr["elapsed_seconds"] is None
    assert ocr["cost_usd"] == "1"
    assert failed["status"] == "error"
    assert failed["error"]["code"] == "ocr_parse_failed"
    assert failed["error"]["retry_sync"] is True

    deleted = client.delete("/ocr/batches/batch_abc123").json()
    assert deleted == {
        "id": "batch_abc123",
        "deleted": True,
        "openrouter": "deleted",
        "upstream_provider": "Anthropic",
        "upstream_status": "unsupported",
    }


def test_http_create_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    client, transport = api()
    image = encoded_image()

    for manifest, images, status, code in (
        ("not json", [image], 422, "validation_error"),
        ([{"key": "short", "images": 1}], [image], 422, "validation_error"),
        ([{"key": KEY_A, "images": 4}], [image] * 4, 422, "validation_error"),
        ([{"key": KEY_A, "images": 2}], [image], 422, "batch_manifest_mismatch"),
        ([], [image], 422, "batch_too_many_receipts"),
        (
            [{"key": KEY_A, "images": 1}],
            [b"\x89PNG\r\n\x1a\n" + b"0" * 8],
            415,
            "unsupported_media_type",
        ),
    ):
        response = create(client, manifest, images)
        assert response.status_code == status, response.text
        assert response.json()["error"]["code"] == code
    monkeypatch.setattr(routes_module, "MAX_UPLOAD_BYTES", 10)
    response = create(client, [{"key": KEY_A, "images": 1}], [image])
    assert (response.status_code, response.json()["error"]["code"]) == (
        413,
        "batch_upload_too_large",
    )
    assert transport.keyed == []


def test_http_estimate_checks_the_counts() -> None:
    client, _ = api()
    response = client.post("/ocr/batches/estimate", json={"receipts": 2, "images": 7})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


# The real transport ---------------------------------------------------------------------------


def test_httpx_transport_sends_the_key_only_on_keyed_calls() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"id": "x"}, headers={"Set-Cookie": "a=b"})

    transport = HttpxBatchTransport(httpx.MockTransport(handler))
    transport.request("GET", MODELS_URL, api_key=None, timeout=5)
    transport.request("POST", BATCHES_URL, api_key=FAKE_KEY, body=b"{}", timeout=5)
    transport.request("DELETE", f"{BATCHES_URL}/x", api_key=FAKE_KEY, timeout=5)
    transport.close()

    public, post, delete = seen
    assert "authorization" not in public.headers
    assert post.headers["authorization"] == f"Bearer {FAKE_KEY}"
    assert post.headers["content-type"] == "application/json"
    assert delete.method == "DELETE"
    for request in seen:
        assert "cookie" not in request.headers
        assert request.headers["user-agent"] == "ocr-client"
        assert "http-referer" not in request.headers
        assert "x-title" not in request.headers


# Fixes after review ------------------------------------------------------------------------------


def test_the_opt_in_takes_only_true_or_false(monkeypatch: pytest.MonkeyPatch) -> None:
    for loose in ("1", "yes", "on", "y", ""):
        monkeypatch.setenv("OPENROUTER_BATCH_ALLOW_RETENTION", loose)
        with pytest.raises(ValueError):
            Settings()
    monkeypatch.setenv("OPENROUTER_BATCH_ALLOW_RETENTION", " TRUE ")
    assert Settings().openrouter_batch_allow_retention is True


def test_long_prices_are_multiplied_exactly() -> None:
    long_price = "0." + "0" * 6 + "1234567890123456789012345678901234567"
    endpoints = {
        "data": {"endpoints": [batch_endpoint("anthropic", "Anthropic", prompt=long_price)]}
    }
    models = json.loads(json.dumps(MODELS))
    models["data"][0]["pricing"] = {"prompt": long_price, "completion": long_price}
    transport = FakeBatchTransport(models=models, endpoints=endpoints)
    for item in transport.endpoints["data"]["endpoints"]:
        item["pricing"]["completion"] = long_price
    batches = OpenRouterBatches(settings(), transport=transport)

    estimate = batches.estimate(7, 9)

    # Computed from the digits, outside any decimal context: the integer and the exponent.
    digits = (estimate.prompt_tokens + 7 * 1200) * int(long_price.replace("0.", "", 1))
    expected = Decimal((0, tuple(int(d) for d in str(digits)), -(len(long_price) - 2)))
    assert estimate.cost_usd == expected
    assert len(estimate.cost_usd.as_tuple().digits) > 28


def test_results_are_read_after_the_model_left_the_catalogue() -> None:
    gone = {"data": [entry for entry in MODELS["data"] if entry["id"] != MODEL + ":batch"]}
    transport = FakeBatchTransport(completed(result(KEY_A)), models=gone)
    batches = OpenRouterBatches(settings(), transport=transport)

    (item,) = batches.results("batch_abc123").items

    assert item.extraction is not None
    assert item.provider == "Anthropic"


def test_answers_are_still_checked_against_the_setting_without_a_catalogue() -> None:
    gone = {"data": []}
    transport = FakeBatchTransport(completed(result(KEY_A), provider="Elsewhere"), models=gone)
    batches = OpenRouterBatches(settings(), transport=transport)

    (item,) = batches.results("batch_abc123").items

    assert item.error is not None and item.error.code == "openrouter_batch_provider_unverified"


def test_an_accepted_batch_whose_answer_breaks_the_reader_is_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    batches, _ = make(accepted())

    def broken(*_args: Any, **_kwargs: Any) -> Any:
        raise KeyError("a bug")

    monkeypatch.setattr(batches, "_status_of", broken)
    with pytest.raises(BackendError) as raised:
        batches.submit(receipts(KEY_A))
    assert (raised.value.status_code, raised.value.code) == (504, "openrouter_batch_submit_unknown")


def test_the_fallback_check_compares_providers_not_endpoint_slugs() -> None:
    transport = FakeBatchTransport(completed(result(KEY_A)), models={"data": []})
    batches = OpenRouterBatches(
        settings(openrouter_batch_providers="anthropic/eu"), transport=transport
    )

    (item,) = batches.results("batch_abc123").items

    assert item.extraction is not None
