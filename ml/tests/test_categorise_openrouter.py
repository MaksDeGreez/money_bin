"""The hosted categoriser: only item names leave, through zero-retention endpoints only."""

import json
import math
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.backends import BackendConfigError, BackendError
from app.backends.openrouter import CHAT_URL, PRIVACY_PREFERENCES, HttpResponse, OpenRouterBackend
from app.categorise.base import CategoriseInput
from app.categorise.openrouter import FALLBACK_SCORE, OpenRouterCategoriser, read_answer
from app.categorise.prompt import PROMPT_VERSION
from app.config import Settings
from app.main import create_app
from tests.categorise_helpers import CATEGORIES, OPTIONS, SLUGS
from tests.test_openrouter_backend import (
    FAKE_KEY,
    MODELS,
    STRUCTURED,
    Clock,
    FakeTransport,
    endpoint,
    jpeg,
)

TEXT_MODEL = "example/text-only"
LOGPROBS = ["temperature", "max_tokens", "logprobs", "top_logprobs"]
BOTH = [*STRUCTURED, "logprobs", "top_logprobs"]

ZDR_TEXT = {
    "data": [
        endpoint("alpha", "Alpha", model=TEXT_MODEL, supported_parameters=BOTH),
        endpoint("beta", "Beta", model=TEXT_MODEL, supported_parameters=STRUCTURED),
        endpoint("eta", "Eta", model=TEXT_MODEL, supported_parameters=LOGPROBS),
        endpoint("zeta", "Zeta", model=TEXT_MODEL),
        endpoint(
            "gamma", "Gamma", model=TEXT_MODEL, supported_parameters=BOTH, safety_retention=True
        ),
    ]
}

MERCHANT = "Магазин Секретний"
TEXTS = ("Мол2,5%900г", "Парацетамол №10")


def answer_text(*slugs: str) -> str:
    return json.dumps({str(n): slug for n, slug in enumerate(slugs, 1)})


def token_logprobs(
    text: str, alternatives: dict[int, list[tuple[str, float]]] | None = None
) -> list[dict[str, Any]]:
    """One token per character, each with log-probability log(0.9) unless given."""
    alternatives = alternatives or {}
    return [
        {
            "token": char,
            "logprob": math.log(0.99),
            "top_logprobs": [{"token": t, "logprob": lp} for t, lp in alternatives.get(index, [])],
        }
        for index, char in enumerate(text)
    ]


def chat(
    text: str, *, logprobs: Any = None, provider: str = "Alpha", cost: str = "0.0001"
) -> HttpResponse:
    choice: dict[str, Any] = {
        "finish_reason": "stop",
        "message": {"role": "assistant", "content": text},
    }
    if logprobs is not None:
        choice["logprobs"] = {"content": logprobs}
    document = {"id": "gen-1", "model": TEXT_MODEL, "provider": provider, "choices": [choice]}
    raw = json.dumps(document)
    return HttpResponse(
        200,
        raw[:-1]
        + f', "usage": {{"prompt_tokens": 900, "completion_tokens": 30, "cost": {cost}}}}}',
    )


def make(
    *answers: HttpResponse, zdr: Any = ZDR_TEXT, **overrides: Any
) -> tuple[OpenRouterCategoriser, FakeTransport]:
    transport = FakeTransport(*answers, models=MODELS, zdr=zdr)
    values: dict[str, Any] = {
        "categorise_backend": "openrouter",
        "openrouter_api_key": FAKE_KEY,
        "openrouter_categorise_model": TEXT_MODEL,
    }
    values.update(overrides)
    return OpenRouterCategoriser(Settings(**values), transport=transport, clock=Clock()), transport


def request(merchant: str | None = MERCHANT) -> CategoriseInput:
    return CategoriseInput(OPTIONS, TEXTS, merchant)


def test_only_the_categories_and_the_item_names_are_sent() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, transport = make(chat(text, logprobs=token_logprobs(text)))

    categoriser.categorise(request())

    (post,) = transport.posts
    body = post["body"]
    sent = json.dumps(body, ensure_ascii=False)
    assert post["url"] == CHAT_URL
    assert MERCHANT not in sent
    assert "Секретний" not in sent
    assert "shop" not in body["messages"][1]["content"].lower()
    assert set(body) == {
        "model",
        "messages",
        "temperature",
        "max_tokens",
        "stream",
        "provider",
        "response_format",
        "logprobs",
        "top_logprobs",
    }
    assert [m["role"] for m in body["messages"]] == ["system", "user"]
    user = body["messages"][1]["content"]
    assert user.endswith("1. Мол2,5%900г\n2. Парацетамол №10")
    assert body["model"] == TEXT_MODEL
    assert body["temperature"] == 0
    assert body["stream"] is False


def test_every_request_carries_the_privacy_preferences() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, transport = make(chat(text))

    categoriser.categorise(request())

    provider = transport.posts[0]["body"]["provider"]
    for key, value in PRIVACY_PREFERENCES.items():
        assert provider[key] == value
    # Never the retaining endpoint, never one outside the list.
    assert "gamma" not in provider["only"]


@pytest.mark.parametrize(
    ("zdr_params", "only", "structured", "logprobs"),
    [
        ({"alpha": BOTH, "beta": STRUCTURED, "eta": LOGPROBS}, ["alpha"], True, True),
        ({"beta": STRUCTURED, "eta": LOGPROBS}, ["beta"], True, False),
        ({"eta": LOGPROBS, "zeta": ["temperature"]}, ["eta"], False, True),
        ({"zeta": ["temperature"]}, ["zeta"], False, False),
    ],
)
def test_the_route_prefers_structured_output_with_log_probabilities(
    zdr_params: dict[str, list[str]], only: list[str], structured: bool, logprobs: bool
) -> None:
    zdr = {
        "data": [
            endpoint(tag, tag.capitalize(), model=TEXT_MODEL, supported_parameters=params)
            for tag, params in zdr_params.items()
        ]
    }
    provider = only[0].capitalize()
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, transport = make(chat(text, provider=provider), zdr=zdr)

    categoriser.categorise(request())

    body = transport.posts[0]["body"]
    assert body["provider"]["only"] == only
    assert ("response_format" in body) is structured
    assert ("logprobs" in body) is logprobs
    if structured:
        schema = body["response_format"]["json_schema"]["schema"]
        assert schema["required"] == ["1", "2"]
        assert schema["properties"]["1"]["enum"] == SLUGS
        assert schema["additionalProperties"] is False


def test_structured_output_can_be_turned_off() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, transport = make(chat(text, provider="Eta"), openrouter_structured_output=False)

    categoriser.categorise(request())

    body = transport.posts[0]["body"]
    assert "response_format" not in body
    assert body["provider"]["only"] == ["alpha", "eta"]


def test_scores_come_from_the_token_log_probabilities() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    start = text.index("health/")  # the first character of item 2's value
    alternatives = {start: [("o", math.log(0.05))]}  # "o" can only lead to other/other-spending
    categoriser, _ = make(chat(text, logprobs=token_logprobs(text, alternatives)))

    answer = categoriser.categorise(request())

    assert answer.score_kind == "token_logprobs"
    assert answer.prompt_version == PROMPT_VERSION
    first, second = answer.candidates
    assert first[0].slug == "groceries/groceries"
    assert math.isclose(first[0].score, 0.99 ** len("groceries/groceries"))
    assert [c.slug for c in second] == ["health/health-pharmacy", "other/other-spending"]
    assert math.isclose(second[1].score, 0.05)
    assert answer.diagnostics["cost_usd"] == "0.0001"
    assert answer.diagnostics["providers"] == ["Alpha"]


def test_without_log_probabilities_the_score_is_the_fixed_marker() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, _ = make(chat(text))

    answer = categoriser.categorise(request())

    assert answer.score_kind == "fixed"
    assert [[(c.slug, c.score) for c in item] for item in answer.candidates] == [
        [("groceries/groceries", FALLBACK_SCORE)],
        [("health/health-pharmacy", FALLBACK_SCORE)],
    ]


@pytest.mark.parametrize(
    "text",
    [
        "not json",
        "[]",
        answer_text("groceries/groceries"),
        answer_text("groceries/groceries", "made/up"),
        json.dumps(
            {"1": "groceries/groceries", "2": "health/health-pharmacy", "3": "other/other-spending"}
        ),
        json.dumps({"1": "groceries/groceries", "2": 7}),
    ],
)
def test_an_answer_without_a_listed_slug_for_every_item_is_a_422(text: str) -> None:
    with pytest.raises(BackendError) as error:
        read_answer(text, 2, SLUGS)

    assert error.value.status_code == 422
    assert error.value.code == "categorise_parse_failed"


def test_a_parse_failure_keeps_the_accounting() -> None:
    categoriser, _ = make(chat("{}"))

    with pytest.raises(BackendError) as error:
        categoriser.categorise(request())

    assert error.value.code == "categorise_parse_failed"
    assert error.value.diagnostics["model_calls"] == 1


def test_a_text_only_model_is_allowed_for_categorisation() -> None:
    categoriser, _ = make()

    categoriser.start()

    assert categoriser.model_version == "example/text-only-20260101"
    assert categoriser.catalogue is not None
    assert categoriser.catalogue.logprob_endpoints == ("alpha", "eta")


def test_without_a_model_the_service_does_not_start() -> None:
    categoriser, _ = make(openrouter_categorise_model=None)

    with pytest.raises(BackendConfigError) as error:
        categoriser.start()

    assert error.value.code == "openrouter_model_missing"
    assert "OPENROUTER_CATEGORISE_MODEL" in error.value.message


def test_without_a_key_nothing_is_sent() -> None:
    categoriser, transport = make(openrouter_api_key=None)

    with pytest.raises(BackendConfigError) as error:
        categoriser.categorise(request())

    assert error.value.code == "openrouter_key_missing"
    assert transport.posts == []


def test_an_answer_from_an_unexpected_provider_halts_ocr_too() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, _ = make(chat(text, provider="Elsewhere"))

    with pytest.raises(BackendError) as error:
        categoriser.categorise(request())
    assert error.value.code == "openrouter_provider_unverified"

    ocr_transport = FakeTransport()
    ocr = OpenRouterBackend(
        Settings(openrouter_api_key=FAKE_KEY, openrouter_ocr_model="example/vision-model"),
        transport=ocr_transport,
        clock=Clock(),
    )
    with pytest.raises(BackendError) as halted:
        ocr.extract_receipt([jpeg()])
    assert halted.value.code == "openrouter_provider_unverified"
    assert ocr_transport.posts == []


def test_through_the_api_the_merchant_never_leaves() -> None:
    text = answer_text("groceries/groceries", "health/health-pharmacy")
    categoriser, transport = make(chat(text, logprobs=token_logprobs(text)))
    app = create_app(Settings(categorise_backend="openrouter"), categoriser=categoriser)

    with TestClient(app) as client:
        response = client.post(
            "/categorise",
            json={"texts": list(TEXTS), "categories": CATEGORIES, "merchant": MERCHANT},
        )

    assert response.status_code == 200
    answer = response.json()
    assert answer["backend"] == "openrouter"
    assert answer["score_kind"] == "token_logprobs"
    assert answer["cost_usd"] == "0.0001"
    assert answer["calibrated"] is False
    for post in transport.posts:
        assert MERCHANT not in json.dumps(post["body"], ensure_ascii=False)
