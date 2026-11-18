"""OpenRouter's Decisions API: typed questions to a decision model, typed and checked answers.

A decision model (TypeSafe's Jev and a few dozen others on OpenRouter) does not write text. It
takes a `state` and named, typed questions, and answers each with a typed value: a `choice`
question with the chosen option and a probability for every option, a `noul` question with the
probability that a proposition holds. All the questions of a request are answered in one pass.

    client = DecisionsClient(settings)                       # DECISIONS_MODEL, OPENROUTER_API_KEY
    decision = client.decide({"line_1": "..."}, {"line_1": Choice("Which ...?", {...})}, deadline)
    decision.answers["line_1"].probabilities                 # {"Groceries": 0.91, ...}

The call goes through `app.backends.openrouter.OpenRouterClient` (`decisions=True`), so the
zero-retention rules are the hosted OCR backend's, in the same code: the model's strict
zero-retention endpoints only, named in every request with `zdr: true` and
`data_collection: "deny"`; nothing sent when the lists cannot be read or the model has no such
endpoint; the provider of every answer checked, and a halt of every hosted call after a wrong one.
The request body is `model`, `state`, `questions` and `provider`, nothing else (no `user`,
`session_id`, `trace` or `assets`). What `state` and the questions hold is the caller's
responsibility; `app.categorise.decisions` puts item names and public category text there only.
This client is for receipt item names: never for transactions, payees or bank descriptions
(`docs/decisions/0016-decision-model-categoriser.md`).

Every answer is checked against its question: a missing answer, an answer to a question not asked,
an option not offered, a missing or extra probability, a value outside 0..1 and probabilities that
do not add up to 1 (within `SUM_TOLERANCE`) are errors (502 `decisions_bad_answer`, or
`decisions_answer_missing`), never dropped or guessed. A refusal is an answer (`Refusal`). The
client never retries.
"""

import math
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from app.backends.base import BackendError
from app.backends.openrouter import (
    CATALOGUE_TIMEOUT_SECONDS,
    Call,
    Catalogue,
    OpenRouterClient,
    Transport,
    provider_preferences,
)
from app.config import Settings

MODEL_SETTING = "DECISIONS_MODEL"
# The probabilities of a choice answer must add up to 1 within this much.
SUM_TOLERANCE = 0.02
MAX_KEY_LENGTH = 64


# Questions ---------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Choice:
    """Which one of the options applies. `criteria`: option label -> what the option means."""

    instructions: str
    criteria: Mapping[str, str]

    def as_json(self) -> dict[str, Any]:
        criteria = dict(self.criteria)
        return {"type": "choice", "instructions": self.instructions, "criteria": criteria}


@dataclass(frozen=True)
class Noul:
    """Whether a proposition holds. The answer is the probability that it does."""

    instructions: str

    def as_json(self) -> dict[str, Any]:
        return {"type": "noul", "instructions": self.instructions}


Question = Choice | Noul


# Answers -----------------------------------------------------------------------------------------


@dataclass(frozen=True)
class ChoiceAnswer:
    """The model's pick and a probability for every option, in the order they were offered.

    `confidence` describes how concentrated the probabilities are, not how likely the pick is right.
    """

    choice: str
    probabilities: Mapping[str, float]
    confidence: float | None

    def normalised(self) -> dict[str, float]:
        """The probabilities divided by their sum (checked to be within `SUM_TOLERANCE` of 1)."""
        total = math.fsum(self.probabilities.values())
        return {option: value / total for option, value in self.probabilities.items()}


@dataclass(frozen=True)
class NoulAnswer:
    """The probability that the proposition holds."""

    probability: float


@dataclass(frozen=True)
class Refusal:
    """The model declined this question; the other questions of the request may be answered."""


Answer = ChoiceAnswer | NoulAnswer | Refusal


@dataclass(frozen=True)
class Decision:
    """Every question's answer, by question key, and the request's accounting."""

    answers: Mapping[str, Answer]
    call: Call


def bad_answer(detail: str) -> BackendError:
    """An answer of the wrong shape. `detail` names question keys and rules, never state values."""
    return BackendError(502, "decisions_bad_answer", f"The decision model's answer {detail}.")


def _probability(value: Any) -> float | None:
    """A probability as a float, or None when it is not a number between 0 and 1."""
    if isinstance(value, bool) or not isinstance(value, int | float | Decimal):
        return None
    number = float(value)
    return number if math.isfinite(number) and 0.0 <= number <= 1.0 else None


def parse_answers(raw: Any, questions: Mapping[str, Question]) -> dict[str, Answer]:
    """Every question's answer, checked against its question. Anything off is an error."""
    if not isinstance(raw, dict):
        raise bad_answer("has no answers object")
    missing = [key for key in questions if key not in raw]
    if missing:
        raise BackendError(
            502,
            "decisions_answer_missing",
            f"The decision model's answer lacks {len(missing)} of {len(questions)} questions.",
        )
    if any(key not in questions for key in raw):
        raise bad_answer("answers a question that was not asked")
    return {key: _parse_answer(key, raw[key], question) for key, question in questions.items()}


def _parse_answer(key: str, raw: Any, question: Question) -> Answer:
    if not isinstance(raw, dict):
        raise bad_answer(f"to {key} is not an object")
    kind = raw.get("type")
    if kind == "refusal":
        return Refusal()
    if isinstance(question, Noul):
        if kind != "noul":
            raise bad_answer(f"to {key} is not a noul answer")
        probability = _probability(raw.get("noul"))
        if probability is None:
            raise bad_answer(f"to {key} has no probability between 0 and 1")
        return NoulAnswer(probability)
    if kind != "choice":
        raise bad_answer(f"to {key} is not a choice answer")
    options = list(question.criteria)
    choice = raw.get("choice")
    if not isinstance(choice, str) or choice not in question.criteria:
        raise bad_answer(f"to {key} picks an option that was not offered")
    probabilities = raw.get("probabilities")
    if not isinstance(probabilities, dict) or set(probabilities) != set(options):
        raise bad_answer(f"to {key} does not give a probability for exactly the options offered")
    values = {option: _probability(probabilities[option]) for option in options}
    if any(value is None for value in values.values()):
        raise bad_answer(f"to {key} has a probability outside 0..1")
    checked = {option: float(value) for option, value in values.items() if value is not None}
    if abs(math.fsum(checked.values()) - 1.0) > SUM_TOLERANCE:
        raise bad_answer(f"to {key} has probabilities that do not add up to 1")
    confidence = raw.get("confidence")
    return ChoiceAnswer(
        choice=choice,
        # Indexed by option, in the order offered: the answer's own key order is not stable.
        probabilities=checked,
        confidence=None if confidence is None else _probability(confidence),
    )


class DecisionsClient:
    """One decision model (`DECISIONS_MODEL`) through its strict zero-retention endpoints only."""

    def __init__(
        self,
        settings: Settings,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self._client = OpenRouterClient(
            settings,
            MODEL_SETTING,
            needs_images=False,
            decisions=True,
            transport=transport,
            clock=clock,
        )

    @property
    def model(self) -> str | None:
        return self._client.model

    @property
    def model_name(self) -> str:
        return self._client.model_name

    @property
    def model_version(self) -> str:
        return self._client.model_version

    @property
    def catalogue(self) -> Catalogue | None:
        return self._client.catalogue

    def start(self) -> None:
        self._client.start()

    def stop(self) -> None:
        self._client.stop()

    def ready(self, deadline: float) -> Catalogue:
        """Check the key and the halt, and read the catalogue (when due) within `deadline`."""
        self._client.api_key()
        self._client.check_not_halted()
        remaining = max(1.0, deadline - time.perf_counter())
        return self._client.current_catalogue(timeout=min(CATALOGUE_TIMEOUT_SECONDS, remaining))

    def request_body(
        self, catalogue: Catalogue, state: Mapping[str, Any], questions: Mapping[str, Question]
    ) -> dict[str, Any]:
        """The request: the model, the state, the questions and the privacy preferences only."""
        if not questions:
            raise ValueError("a request needs at least one question")
        if any(not 0 < len(key) <= MAX_KEY_LENGTH for key in questions):
            raise ValueError("question keys are short, non-empty strings")
        return {
            "model": self._client.model,
            "state": dict(state),
            "questions": {key: question.as_json() for key, question in questions.items()},
            "provider": provider_preferences(catalogue.endpoints),
        }

    def decide(
        self,
        state: Mapping[str, Any],
        questions: Mapping[str, Question],
        deadline: float,
        calls: list[Call],
    ) -> Decision:
        """Ask every question about `state` in one request; check every answer.

        The request's accounting goes into `calls` (also when it fails). Raises `BackendError`.
        """
        catalogue = self.ready(deadline)
        body = self.request_body(catalogue, state, questions)
        document = self._client.decide(body, catalogue, calls, deadline)
        return Decision(parse_answers(document.get("answers"), questions), calls[-1])
