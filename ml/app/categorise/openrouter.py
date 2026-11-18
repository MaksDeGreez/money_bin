"""The hosted item categoriser: the same prompt on a model reached through OpenRouter.

It is there for comparison with the local model. Its privacy rules are those
of the hosted OCR backend (`docs/decisions/0012-hosted-ocr-backend.md`) and use
the same code (`app.backends.openrouter.OpenRouterClient`): strict
zero-retention endpoints only, fixed provider preferences, the provider of
every answer checked, a halt after a wrong one, no attribution headers.

What is sent: the fixed instructions with the category list (the app's
taxonomy) and the receipt's item names, numbered. Nothing else: the request
body is built from the categories and the item texts only
(`hosted_messages`); the shop's name, amounts, dates and ids are not
parameters of anything here, so they cannot be added by mistake.

The answer is asked for as a JSON object restricted to the listed slugs
(structured output) where the endpoints support it, and with token
log-probabilities where they return them (`app.categorise.logprobs`).
Without log-probabilities the chosen slug gets `FALLBACK_SCORE`, with
`score_kind` `fixed`: not a confidence, only a marker; a calibration fitted
on such answers turns it into the model's measured precision.
"""

import json
import time
from collections.abc import Sequence
from typing import Any

from app.backends.base import BackendError
from app.backends.openrouter import (
    CATALOGUE_TIMEOUT_SECONDS,
    Call,
    Catalogue,
    OpenRouterClient,
    Transport,
    accounting,
    provider_preferences,
)
from app.categorise.base import (
    Candidate,
    Categorisation,
    CategoriseInput,
    Categoriser,
    slugs_of,
)
from app.categorise.logprobs import item_scores
from app.categorise.prompt import PROMPT_VERSION, CategoryOption, answer_schema, hosted_messages
from app.config import Settings

MODEL_SETTING = "OPENROUTER_CATEGORISE_MODEL"
SCHEMA_NAME = "item_categories"
# The score of an answer without log-probabilities. Below any sensible acceptance threshold.
FALLBACK_SCORE = 0.5
# How many alternatives per token are asked for.
TOP_LOGPROBS = 5
# Room for the JSON around the slugs, per item and in all.
TOKENS_PER_ITEM = 32
TOKENS_EXTRA = 64


def _parse_failed() -> BackendError:
    return BackendError(
        422,
        "categorise_parse_failed",
        "The hosted model's answer did not name one listed category for every item.",
    )


def read_answer(text: str, count: int, slugs: Sequence[str]) -> list[str]:
    """The slug the answer names for each item, in order, or a 422 error."""
    try:
        document = json.loads(text)
    except ValueError:
        raise _parse_failed() from None
    keys = [str(number) for number in range(1, count + 1)]
    if not isinstance(document, dict) or sorted(document) != sorted(keys):
        raise _parse_failed()
    allowed = set(slugs)
    chosen = [document[key] for key in keys]
    if not all(isinstance(slug, str) and slug in allowed for slug in chosen):
        raise _parse_failed()
    return chosen


class OpenRouterCategoriser(Categoriser):
    name = "openrouter"

    def __init__(
        self,
        settings: Settings | None = None,
        transport: Transport | None = None,
        clock: Any = time.monotonic,
    ) -> None:
        super().__init__(settings)
        self._client = OpenRouterClient(
            self.settings, MODEL_SETTING, needs_images=False, transport=transport, clock=clock
        )
        self.model_name = self._client.model_name

    @property
    def model_version(self) -> str:  # type: ignore[override]
        return self._client.model_version

    @property
    def catalogue(self) -> Catalogue | None:
        return self._client.catalogue

    def start(self) -> None:
        self._client.start()

    def stop(self) -> None:
        self._client.stop()

    def route(self, catalogue: Catalogue) -> tuple[tuple[str, ...], bool, bool]:
        """The endpoints to allow, and whether to ask for structured output and log-probabilities.

        Preferred: endpoints with both; then structured output alone; then
        log-probabilities alone; then any strict zero-retention endpoint.
        """
        structured = catalogue.structured_endpoints
        logprobs = set(catalogue.logprob_endpoints)
        both = tuple(tag for tag in structured if tag in logprobs)
        if both:
            return both, True, True
        if structured:
            return structured, True, False
        if logprobs:
            return tuple(sorted(logprobs)), False, True
        return catalogue.endpoints, False, False

    def request_body(
        self, catalogue: Catalogue, categories: Sequence[CategoryOption], texts: Sequence[str]
    ) -> dict[str, Any]:
        """The chat request: the instructions, the categories, the item names. Nothing else."""
        endpoints, structured, logprobs = self.route(catalogue)
        system, user = hosted_messages(categories, texts)
        body: dict[str, Any] = {
            "model": self._client.model,
            "messages": [
                {"role": "system", "content": system["content"]},
                {"role": "user", "content": user["content"]},
            ],
            "temperature": 0,
            "max_tokens": min(
                self.settings.openrouter_max_tokens, TOKENS_EXTRA + TOKENS_PER_ITEM * len(texts)
            ),
            "stream": False,
            "provider": provider_preferences(endpoints),
        }
        if structured:
            schema = answer_schema(slugs_of(categories), len(texts))
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": SCHEMA_NAME, "strict": True, "schema": schema},
            }
        if logprobs:
            body["logprobs"] = True
            body["top_logprobs"] = TOP_LOGPROBS
        return body

    def categorise(self, request: CategoriseInput) -> Categorisation:
        """One call for the receipt's items, within `OPENROUTER_TIMEOUT` seconds."""
        deadline = time.perf_counter() + self.settings.openrouter_timeout
        self._client.api_key()
        self._client.check_not_halted()
        catalogue = self._client.current_catalogue(
            timeout=min(CATALOGUE_TIMEOUT_SECONDS, self.settings.openrouter_timeout)
        )
        # Only the categories and the item names: `request.merchant` is never read here.
        body = self.request_body(catalogue, request.categories, request.texts)
        calls: list[Call] = []
        structured = "response_format" in body
        try:
            answer = self._client.call(body, catalogue, calls, deadline, structured=structured)
            slugs = slugs_of(request.categories)
            chosen = read_answer(answer.text, len(request.texts), slugs)
        except BackendError as error:
            error.diagnostics = accounting(calls)
            raise
        scored = item_scores(answer.text, answer.logprobs, chosen, slugs)
        if scored is None:
            candidates = [[Candidate(slug, FALLBACK_SCORE)] for slug in chosen]
            kind = "fixed"
        else:
            candidates, kind = scored, "token_logprobs"
        return Categorisation(
            candidates=candidates,
            score_kind=kind,  # type: ignore[arg-type]
            prompt_version=PROMPT_VERSION,
            diagnostics={**accounting(calls), "logprobs_requested": "logprobs" in body},
        )
