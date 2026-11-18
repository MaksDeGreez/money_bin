"""The Decisions API client: zero retention, the exact request, checked answers, accounting."""

import json
import time
from decimal import Decimal
from typing import Any

import httpx
import pytest

from app.backends import BackendConfigError, BackendError, OpenRouterBackend
from app.backends.openrouter import (
    ALL_MODELS_URL,
    DECISIONS_URL,
    PRIVACY_PREFERENCES,
    ZDR_ENDPOINTS_URL,
    HttpResponse,
    reset_halt,
)
from app.decisions import (
    Choice,
    ChoiceAnswer,
    DecisionsClient,
    Noul,
    NoulAnswer,
    Refusal,
    parse_answers,
)
from tests.decisions_helpers import (
    ALIAS,
    CHAT_MODEL,
    DATED_DECIDER,
    DECIDER,
    ZDR,
    FakeDecisions,
    decision_response,
    decision_settings,
)
from tests.test_openrouter_backend import FAKE_KEY, Clock, FakeTransport, endpoint, jpeg

QUESTIONS = {
    "line_1": Choice("Which?", {"A": "first", "B": "second", "C": "third"}),
    "line_2": Noul("Is it?"),
}


def client(transport: Any, **overrides: Any) -> DecisionsClient:
    return DecisionsClient(decision_settings(**overrides), transport=transport, clock=Clock())


def deadline() -> float:
    return time.perf_counter() + 60


def answer(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "line_1": {
            "type": "choice",
            "choice": "B",
            "probabilities": {"C": 0.05, "A": 0.15, "B": 0.8},
            "confidence": 0.7,
        },
        "line_2": {"type": "noul", "noul": 0.91},
    }
    base.update(overrides)
    return base


def test_the_request_is_the_model_the_state_the_questions_and_the_privacy_preferences() -> None:
    transport = FakeDecisions(lambda body: answer())
    calls: list[Any] = []

    decision = client(transport).decide(
        {"line_1": "Хліб", "line_2": "Молоко"}, QUESTIONS, deadline(), calls
    )

    (post,) = transport.posts
    assert post["url"] == DECISIONS_URL
    assert post["api_key"] == FAKE_KEY
    assert post["body"] == {
        "model": DECIDER,
        "state": {"line_1": "Хліб", "line_2": "Молоко"},
        "questions": {
            "line_1": {
                "type": "choice",
                "instructions": "Which?",
                "criteria": {"A": "first", "B": "second", "C": "third"},
            },
            "line_2": {"type": "noul", "instructions": "Is it?"},
        },
        "provider": {"only": ["decider"], "allow_fallbacks": True, **PRIVACY_PREFERENCES},
    }
    assert FAKE_KEY not in json.dumps(post["body"])
    assert transport.gets == [ALL_MODELS_URL, ZDR_ENDPOINTS_URL]
    first = decision.answers["line_1"]
    assert isinstance(first, ChoiceAnswer)
    assert first.choice == "B"
    assert list(first.probabilities) == ["A", "B", "C"]
    assert first.probabilities == {"A": 0.15, "B": 0.8, "C": 0.05}
    assert decision.answers["line_2"] == NoulAnswer(0.91)
    assert decision.call.cost_usd == Decimal("0.000018")
    assert decision.call.prompt_tokens == 424
    assert decision.call.model == DATED_DECIDER
    assert calls == [decision.call]


def test_the_catalogue_names_the_dated_model() -> None:
    decider = client(FakeDecisions())
    decider.start()
    assert decider.model_version == DATED_DECIDER
    assert decider.catalogue is not None and decider.catalogue.endpoints == ("decider",)


@pytest.mark.parametrize(
    ("model", "code"),
    [
        (CHAT_MODEL, "openrouter_not_a_decision_model"),
        (ALIAS, "openrouter_moving_alias"),
        ("example/unknown", "openrouter_model_unknown"),
    ],
)
def test_only_a_listed_decision_model_with_a_strict_endpoint_is_used(model: str, code: str) -> None:
    transport = FakeDecisions()

    with pytest.raises(BackendConfigError) as raised:
        client(transport, decisions_model=model).decide({"line_1": "x"}, QUESTIONS, deadline(), [])

    assert raised.value.code == code
    assert transport.posts == []


def test_a_safety_retention_endpoint_is_never_used() -> None:
    zdr = {"data": [endpoint("decider", "Decider", model=DECIDER, safety_retention=True)]}
    transport = FakeDecisions(zdr=zdr)

    with pytest.raises(BackendConfigError, match="no endpoint with zero data retention"):
        client(transport).decide({"line_1": "x"}, QUESTIONS, deadline(), [])
    assert transport.posts == []


def test_without_the_lists_nothing_is_sent() -> None:
    transport = FakeDecisions()
    transport.get = lambda url, timeout: HttpResponse(503, "")  # type: ignore[method-assign]

    with pytest.raises(BackendError) as raised:
        client(transport).decide({"line_1": "x"}, QUESTIONS, deadline(), [])

    assert raised.value.code == "openrouter_catalogue_unavailable"
    assert transport.posts == []


def test_without_a_key_or_a_model_nothing_is_sent() -> None:
    transport = FakeDecisions()
    with pytest.raises(BackendConfigError) as raised:
        client(transport, openrouter_api_key=None).decide({"a": "x"}, QUESTIONS, deadline(), [])
    assert raised.value.code == "openrouter_key_missing"
    with pytest.raises(BackendConfigError) as raised:
        client(transport, decisions_model=None).decide({"a": "x"}, QUESTIONS, deadline(), [])
    assert raised.value.code == "openrouter_model_missing"
    assert "DECISIONS_MODEL" in raised.value.message
    assert transport.posts == []


def test_an_answer_from_another_provider_halts_every_hosted_call() -> None:
    transport = FakeDecisions(lambda body: answer(), provider="Elsewhere")
    decider = client(transport)

    with pytest.raises(BackendError) as raised:
        decider.decide({"line_1": "x"}, QUESTIONS, deadline(), [])
    assert raised.value.code == "openrouter_provider_unverified"

    with pytest.raises(BackendError):
        decider.decide({"line_1": "x"}, QUESTIONS, deadline(), [])
    assert len(transport.posts) == 1
    ocr = OpenRouterBackend(
        decision_settings(openrouter_ocr_model="example/vision-model"),
        transport=FakeTransport(),
        clock=Clock(),
    )
    with pytest.raises(BackendError) as raised:
        ocr.extract_receipt([jpeg()])
    assert raised.value.code == "openrouter_provider_unverified"
    reset_halt()


def test_an_answer_without_a_provider_halts_too() -> None:
    transport = FakeDecisions(FakeDecisions().responder, decision_response(answer(), provider=None))
    with pytest.raises(BackendError) as raised:
        client(transport).decide({"line_1": "x"}, QUESTIONS, deadline(), [])
    assert raised.value.code == "openrouter_provider_unverified"
    reset_halt()


@pytest.mark.parametrize(
    ("status", "code", "transient"),
    [
        (429, "openrouter_rate_limited", True),
        (502, "openrouter_upstream_error", True),
        (401, "openrouter_auth_failed", False),
        (400, "openrouter_bad_request", False),
    ],
)
def test_error_statuses_map_to_the_service_errors(status: int, code: str, transient: bool) -> None:
    transport = FakeDecisions(FakeDecisions().responder, HttpResponse(status, '{"error": "echo"}'))

    with pytest.raises(BackendError) as raised:
        client(transport).decide({"line_1": "x"}, QUESTIONS, deadline(), [])

    assert (raised.value.code, raised.value.transient) == (code, transient)
    assert "echo" not in raised.value.message


def test_a_timeout_is_transient_and_its_cost_unknown() -> None:
    transport = FakeDecisions(FakeDecisions().responder, httpx.ReadTimeout("slow"))
    calls: list[Any] = []

    with pytest.raises(BackendError) as raised:
        client(transport).decide({"line_1": "x"}, QUESTIONS, deadline(), calls)

    assert raised.value.code == "openrouter_timeout"
    assert raised.value.transient
    assert len(calls) == 1 and calls[0].cost_usd is None


def test_an_error_inside_a_200_answer_is_mapped() -> None:
    body = HttpResponse(
        200, json.dumps({"error": {"code": 429, "message": "x"}, "provider": "Decider"})
    )
    with pytest.raises(BackendError) as raised:
        client(FakeDecisions(FakeDecisions().responder, body)).decide(
            {"line_1": "x"}, QUESTIONS, deadline(), []
        )
    assert raised.value.code == "openrouter_rate_limited"


def test_an_answer_that_is_not_json_is_a_bad_response() -> None:
    calls: list[Any] = []
    with pytest.raises(BackendError) as raised:
        client(FakeDecisions(FakeDecisions().responder, HttpResponse(200, "nope"))).decide(
            {"line_1": "x"}, QUESTIONS, deadline(), calls
        )
    assert raised.value.code == "openrouter_bad_response"
    assert len(calls) == 1


@pytest.mark.parametrize(
    ("answers", "code"),
    [
        ({"line_1": answer()["line_1"]}, "decisions_answer_missing"),
        ({**answer(), "line_3": {"type": "noul", "noul": 0.5}}, "decisions_bad_answer"),
        (
            answer(line_1={"type": "choice", "choice": "Z", "probabilities": {}}),
            "decisions_bad_answer",
        ),
        (
            answer(line_1={"type": "choice", "choice": "A", "probabilities": {"A": 0.5, "B": 0.5}}),
            "decisions_bad_answer",
        ),
        (
            answer(
                line_1={
                    "type": "choice",
                    "choice": "A",
                    "probabilities": {"A": 0.5, "B": 0.5, "D": 0.0},
                }
            ),
            "decisions_bad_answer",
        ),
        (
            answer(
                line_1={
                    "type": "choice",
                    "choice": "A",
                    "probabilities": {"A": 1.5, "B": 0.0, "C": 0.0},
                }
            ),
            "decisions_bad_answer",
        ),
        (
            answer(
                line_1={
                    "type": "choice",
                    "choice": "A",
                    "probabilities": {"A": 0.5, "B": 0.2, "C": 0.1},
                }
            ),
            "decisions_bad_answer",
        ),
        (
            answer(
                line_1={
                    "type": "choice",
                    "choice": "A",
                    "probabilities": {"A": True, "B": 0.0, "C": 0.0},
                }
            ),
            "decisions_bad_answer",
        ),
        (answer(line_2={"type": "noul", "noul": 1.2}), "decisions_bad_answer"),
        (answer(line_2={"type": "choice", "choice": "A"}), "decisions_bad_answer"),
        (answer(line_1={"type": "noul", "noul": 0.5}), "decisions_bad_answer"),
        (answer(line_1="A"), "decisions_bad_answer"),
    ],
)
def test_an_answer_off_its_question_is_an_error(answers: dict[str, Any], code: str) -> None:
    with pytest.raises(BackendError) as raised:
        parse_answers(answers, QUESTIONS)
    assert raised.value.code == code
    assert raised.value.transient


def test_no_answers_object_is_an_error() -> None:
    with pytest.raises(BackendError, match="no answers object"):
        parse_answers(None, QUESTIONS)


def test_a_refusal_is_an_answer() -> None:
    parsed = parse_answers(answer(line_2={"type": "refusal"}), QUESTIONS)
    assert parsed["line_2"] == Refusal()


def test_probabilities_within_the_tolerance_are_normalised() -> None:
    parsed = parse_answers(
        answer(
            line_1={
                "type": "choice",
                "choice": "A",
                "probabilities": {"A": 0.6, "B": 0.2, "C": 0.21},
            }
        ),
        QUESTIONS,
    )
    first = parsed["line_1"]
    assert isinstance(first, ChoiceAnswer)
    assert sum(first.normalised().values()) == pytest.approx(1.0)
    assert first.confidence is None


def test_a_request_needs_questions_with_short_keys() -> None:
    decider = client(FakeDecisions())
    decider.start()
    assert decider.catalogue is not None
    with pytest.raises(ValueError):
        decider.request_body(decider.catalogue, {}, {})
    with pytest.raises(ValueError):
        decider.request_body(decider.catalogue, {}, {"x" * 65: Noul("?")})


def test_the_zdr_fixture_lists_the_decider() -> None:
    assert any(entry["model_id"] == DECIDER for entry in ZDR["data"])


def test_answers_with_an_error_and_no_provider_halt() -> None:
    body = HttpResponse(
        200, json.dumps({"error": {"code": 500, "message": "x"}, "answers": answer()})
    )
    decider = client(FakeDecisions(FakeDecisions().responder, body))
    with pytest.raises(BackendError) as raised:
        decider.decide({"line_1": "x"}, QUESTIONS, deadline(), [])
    assert raised.value.code == "openrouter_provider_unverified"
    reset_halt()
