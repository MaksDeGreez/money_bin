"""Request and response models of the HTTP API.

Money and quantity values use `Decimal`. Pydantic writes them to JSON as
strings (for example "123.45"), so no precision is lost on the way to the
Rails app.
"""

from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, Field

MAX_TEXTS = 200
MAX_TEXT_LENGTH = 300
MAX_CATEGORIES = 100
CANDIDATES_PER_TEXT = 3

ReceiptKind = Literal["fiscal", "card_slip"]


class ReceiptItem(BaseModel):
    """One line of a receipt.

    `amount` is the final price of the line, after the discount. `quantity` and
    `unit_price` are null when the model could not read them; the keys are
    always present in the JSON.
    """

    name: str
    quantity: Decimal | None
    unit_price: Decimal | None
    amount: Decimal
    discount: Decimal = Decimal("0.00")


class Receipt(BaseModel):
    """The data read from a receipt.

    A real model will not always find every field, so most of them may be null.
    Every key is always present in the JSON, null or not.

    - `kind`: `fiscal` (a shop's fiscal receipt with items) or `card_slip` (a
      card terminal slip: merchant, date and time, total, masked card number,
      no items), or null when unknown.
    - `card_last4`: the last four digits of the card on a slip.
    - `sum_matches_total`: whether the item amounts add up exactly to
      `total`; null when there is no total, no item, or an item without an amount.
    """

    kind: ReceiptKind | None = None
    merchant: str | None = None
    fiscal_number: str | None = None
    receipt_number: str | None = None
    issued_at: datetime | None = None
    total: Decimal | None = None
    currency: str | None = Field(
        default=None, pattern=r"^[A-Z]{3}$", description="ISO 4217 code, e.g. UAH."
    )
    card_last4: str | None = Field(default=None, pattern=r"^[0-9]{4}$")
    sum_matches_total: bool | None = None
    items: list[ReceiptItem] = Field(default_factory=list)


class BackendInfo(BaseModel):
    """Which backend and model produced a response."""

    backend: str
    model_name: str
    model_version: str


class HealthResponse(BackendInfo):
    """The service is up. `backend`, `model_name` and `model_version` are the OCR backend's."""

    status: str = "ok"
    categoriser: "CategoriserInfo"


class OcrResponse(BackendInfo):
    """The answer of `/ocr`.

    `prompt_version` identifies the prompt and answer schema a model was given
    (null for the stub, which has none). `repaired` says the model's first
    answer was invalid and a second pass fixed it. `elapsed_seconds` is the
    time the backend took, as a decimal string.
    """

    receipt: Receipt
    prompt_version: str | None
    repaired: bool
    elapsed_seconds: Decimal


def _not_blank(text: str) -> str:
    if not text.strip():
        raise ValueError("text must not be empty")
    return text


ItemText = Annotated[str, AfterValidator(_not_blank), Field(max_length=MAX_TEXT_LENGTH)]
# A category slug as the Rails app builds it: "group-part/category-part" (a category, not a group).
CATEGORY_SLUG = r"^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$"
NotBlank = Annotated[str, AfterValidator(_not_blank)]


class CategoryIn(BaseModel):
    """One category the answer may name. The Rails app owns the list and its slugs."""

    slug: str = Field(pattern=CATEGORY_SLUG, max_length=120)
    name: NotBlank = Field(max_length=120)
    description: str = Field(default="", max_length=500)
    group: NotBlank = Field(max_length=120)


def _unique_slugs(categories: list[CategoryIn]) -> list[CategoryIn]:
    slugs = [category.slug for category in categories]
    if len(set(slugs)) != len(slugs):
        raise ValueError("category slugs must be unique")
    return categories


class CategoriseRequest(BaseModel):
    """The items of ONE receipt, the categories to choose from and, optionally, the shop.

    `merchant` is context for a local model; a hosted categoriser never sends it.
    """

    texts: list[ItemText] = Field(min_length=1, max_length=MAX_TEXTS)
    categories: Annotated[
        list[CategoryIn],
        Field(min_length=2, max_length=MAX_CATEGORIES),
        AfterValidator(_unique_slugs),
    ]
    merchant: str | None = Field(default=None, max_length=MAX_TEXT_LENGTH)


class CategoryCandidate(BaseModel):
    category_slug: str = Field(description="One of the request's category slugs.")
    score: float = Field(ge=0.0, le=1.0)


class CategoriseResult(BaseModel):
    """The suggestions for one text: 1 to 3 candidates, best first, scores adding up to <= 1."""

    text: str
    candidates: list[CategoryCandidate] = Field(min_length=1, max_length=CANDIDATES_PER_TEXT)


class CategoriseResponse(BackendInfo):
    """The answer of `/categorise`.

    - `score_kind`: where the scores come from (ml/README.md, "How confidence is computed").
    - `calibrated`: the best candidate's score went through a calibration fitted on labelled
      items for this backend, model, prompt and score kind; otherwise it is the raw score.
    - `prompt_version`: the hash of the prompt (null for the stub); `categories_version`: the
      hash of the request's category list.
    - `cost_usd`: what a hosted call cost (a decimal string; null for a local model, or when a
      call reported no cost).
    """

    results: list[CategoriseResult]
    score_kind: Literal["label_probability", "token_logprobs", "fixed", "stub"]
    calibrated: bool
    prompt_version: str | None
    categories_version: str
    elapsed_seconds: Decimal
    cost_usd: Decimal | None


class CategoriserInfo(BackendInfo):
    """Which categoriser `/categorise` uses, and whether a calibration is loaded."""

    calibration: bool


class ErrorDetail(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    """The one error shape used by every endpoint."""

    error: ErrorDetail


HealthResponse.model_rebuild()
