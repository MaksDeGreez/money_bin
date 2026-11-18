"""A fake OpenRouter for the Decisions API tests: the public lists and a scripted decision model."""

import json
from collections.abc import Callable, Mapping
from typing import Any

from app.backends.openrouter import ALL_MODELS_URL, ZDR_ENDPOINTS_URL, HttpResponse
from app.config import Settings
from tests.test_openrouter_backend import FAKE_KEY, endpoint

DECIDER = "example/decider-1"
DATED_DECIDER = "example/decider-1-20261001"
ALIAS = "~example/decider-latest"
CHAT_MODEL = "example/chat-model"

MODELS_ALL = {
    "data": [
        {
            "id": DECIDER,
            "canonical_slug": DATED_DECIDER,
            "architecture": {"input_modalities": ["text"], "output_modalities": ["decisions"]},
        },
        {
            "id": ALIAS,
            "canonical_slug": ALIAS,
            "architecture": {"input_modalities": ["text"], "output_modalities": ["decisions"]},
        },
        {
            "id": CHAT_MODEL,
            "canonical_slug": f"{CHAT_MODEL}-20260101",
            "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
        },
    ]
}

ZDR = {
    "data": [
        endpoint("decider", "Decider", model=DECIDER, supported_parameters=[]),
        endpoint("chat", "Chatty", model=CHAT_MODEL),
    ]
}

Responder = Callable[[Mapping[str, Any]], dict[str, Any]]


def even_answer(question: Mapping[str, Any], best: str | None = None) -> dict[str, Any]:
    """A choice answer: `best` (default the first option) 0.7, the rest sharing 0.3."""
    options = list(question["criteria"])
    best = best or options[0]
    rest = (1 - 0.7) / (len(options) - 1) if len(options) > 1 else 0.0
    probabilities = {o: (0.7 if o == best else rest) for o in options}
    if len(options) == 1:
        probabilities = {best: 1.0}
    # The key order of an answer is not stable: give them reversed.
    return {
        "type": "choice",
        "choice": best,
        "probabilities": dict(reversed(list(probabilities.items()))),
        "confidence": 0.6,
    }


def default_responder(body: Mapping[str, Any]) -> dict[str, Any]:
    answers = {}
    for key, question in body["questions"].items():
        if question["type"] == "noul":
            answers[key] = {"type": "noul", "noul": 0.8}
        else:
            answers[key] = even_answer(question)
    return answers


def decision_response(
    answers: Mapping[str, Any],
    *,
    provider: Any = "Decider",
    cost: str | None = "0.000018",
    model: str = "example/decider-1-20261001",
) -> HttpResponse:
    usage = '"input_tokens": 424, "output_tokens": 60'
    if cost is not None:
        usage += f', "cost": {cost}'
    document: dict[str, Any] = {"model": model, "answers": answers, "id": "gen-dec-1"}
    if provider is not None:
        document["provider"] = provider
    text = json.dumps(document, ensure_ascii=False)
    return HttpResponse(200, text[:-1] + f', "usage": {{{usage}}}}}')


class FakeDecisions:
    """Answers the public lists; answers each decisions POST from `responses` or `responder`."""

    def __init__(
        self,
        responder: Responder = default_responder,
        *responses: HttpResponse | Exception,
        models: Any = MODELS_ALL,
        zdr: Any = ZDR,
        provider: str = "Decider",
    ) -> None:
        self.responder = responder
        self.responses = list(responses)
        self.models = models
        self.zdr = zdr
        self.provider = provider
        self.gets: list[str] = []
        self.posts: list[dict[str, Any]] = []
        self.closed = False

    def get(self, url: str, *, timeout: float) -> HttpResponse:
        self.gets.append(url)
        if url == ALL_MODELS_URL:
            return HttpResponse(200, json.dumps(self.models))
        if url == ZDR_ENDPOINTS_URL:
            return HttpResponse(200, json.dumps(self.zdr))
        return HttpResponse(404, "{}")

    def post_json(
        self, url: str, body: Mapping[str, Any], *, api_key: str, timeout: float
    ) -> HttpResponse:
        self.posts.append({"url": url, "body": body, "api_key": api_key, "timeout": timeout})
        if self.responses:
            response = self.responses.pop(0)
            if isinstance(response, Exception):
                raise response
            return response
        return decision_response(self.responder(body), provider=self.provider)

    def close(self) -> None:
        self.closed = True


def decision_settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "categorise_backend": "decisions",
        "openrouter_api_key": FAKE_KEY,
        "decisions_model": DECIDER,
    }
    values.update(overrides)
    return Settings(**values)
