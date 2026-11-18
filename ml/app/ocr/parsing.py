"""Reading the model's text as a raw receipt, with one repair pass.

The model should answer with the JSON object of `app.ocr.prompt.ANSWER_SCHEMA`.
Constrained decoding makes that likely but not certain (the answer can be cut
off at the token limit, and a backend may run without it), so the text is
checked here:

1. the JSON object is taken from the text (a code fence or words around it
   are ignored) and checked against `RawReceipt`;
2. when that fails, the model is asked once more, with its previous answer and
   the problems found (`app.ocr.prompt.Repair`);
3. when the second answer fails too, `OcrParseError` is raised. The API turns
   it into HTTP 422 `ocr_parse_failed`.

The checks are about the shape only: a missing key counts as null and an extra
key is ignored. Whether a value makes sense is `app.ocr.postprocess`'s job.
Problem descriptions name fields and error types, never values, so they can be
logged and returned without receipt content.
"""

import json
from collections.abc import Callable
from dataclasses import dataclass
from decimal import Decimal
from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, ConfigDict, ValidationError

from app.ocr.prompt import Repair

MAX_PROBLEMS = 5


class OcrParseError(Exception):
    """The model's answer was not a usable receipt, even after the repair pass.

    `problems` describes what was wrong without quoting the answer.
    `diagnostics` is filled in by the backend (token counts, timings).
    """

    def __init__(self, problems: str) -> None:
        super().__init__(f"The model's answer was not valid receipt JSON: {problems}")
        self.problems = problems
        self.diagnostics: dict[str, Any] = {}


class AnswerError(ValueError):
    """One answer could not be read. `problems` never quotes the answer."""

    def __init__(self, problems: str) -> None:
        super().__init__(problems)
        self.problems = problems


def _as_text(value: Any) -> Any:
    """Numbers become their exact text; a bool or a container is left to fail."""
    if isinstance(value, bool):
        return value
    if isinstance(value, int | Decimal):
        return str(value)
    return value


Text = Annotated[str | None, BeforeValidator(_as_text)]


class RawItem(BaseModel):
    """One item as the model wrote it. Every value is text, as printed."""

    model_config = ConfigDict(extra="ignore")

    name: Text = None
    quantity: Text = None
    unit_price: Text = None
    amount: Text = None
    discount: Text = None


class RawReceipt(BaseModel):
    """The receipt as the model wrote it (`app.ocr.prompt.ANSWER_SCHEMA`)."""

    model_config = ConfigDict(extra="ignore")

    kind: Text = None
    merchant: Text = None
    fiscal_number: Text = None
    receipt_number: Text = None
    date: Text = None
    time: Text = None
    total: Text = None
    currency: Text = None
    card_last4: Text = None
    items: list[RawItem] | None = None


def _json_object_text(text: str) -> str:
    """The text from the first `{` to the last `}`."""
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end < start:
        raise AnswerError("the answer contains no JSON object")
    return text[start : end + 1]


def _describe(error: ValidationError) -> str:
    problems = []
    for detail in error.errors()[:MAX_PROBLEMS]:
        location = ".".join(str(part) for part in detail.get("loc", ())) or "answer"
        problems.append(f"{location}: {detail.get('type', 'invalid')}")
    hidden = error.error_count() - len(problems)
    if hidden > 0:
        problems.append(f"{hidden} more")
    return "; ".join(problems)


def parse_answer(text: str) -> RawReceipt:
    """Read one answer. Raises `AnswerError` when it is not a receipt object."""
    try:
        data = json.loads(_json_object_text(text), parse_float=Decimal)
    except json.JSONDecodeError as error:
        # The decoder's message names the position, not the content.
        raise AnswerError(f"not valid JSON ({error.msg} at character {error.pos})") from None
    if not isinstance(data, dict):  # pragma: no cover - `{...}` always decodes to a dict
        raise AnswerError("the answer is not a JSON object")
    try:
        return RawReceipt.model_validate(data)
    except ValidationError as error:
        raise AnswerError(_describe(error)) from None


@dataclass(frozen=True)
class ParsedAnswer:
    """A readable answer, and whether the repair pass was needed for it."""

    receipt: RawReceipt
    repaired: bool


def read_with_repair(ask: Callable[[Repair | None], str]) -> ParsedAnswer:
    """Ask the model, and ask once more with the problems if the answer is unreadable.

    `ask(None)` returns the model's first answer; `ask(repair)` returns its
    answer to the repair prompt. Raises `OcrParseError` when both fail.
    """
    first = ask(None)
    try:
        return ParsedAnswer(receipt=parse_answer(first), repaired=False)
    except AnswerError as error:
        repair = Repair(previous=first, problems=error.problems)
    second = ask(repair)
    try:
        return ParsedAnswer(receipt=parse_answer(second), repaired=True)
    except AnswerError as error:
        raise OcrParseError(
            f"first answer: {repair.problems}; after one repair pass: {error.problems}"
        ) from None
