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
    status: str = "ok"


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


ItemText = Annotated[str, AfterValidator(_not_blank)]


class CategoriseRequest(BaseModel):
    texts: list[ItemText] = Field(min_length=1, max_length=MAX_TEXTS)


class CategoryCandidate(BaseModel):
    category_slug: str = Field(description="Opaque slug owned by the Rails app: group/category.")
    score: float = Field(ge=0.0, le=1.0)


class CategoriseResult(BaseModel):
    """The suggestions for one text. Candidates are sorted by score, highest first."""

    text: str
    candidates: list[CategoryCandidate] = Field(
        min_length=CANDIDATES_PER_TEXT, max_length=CANDIDATES_PER_TEXT
    )


class CategoriseResponse(BackendInfo):
    results: list[CategoriseResult]


class ErrorDetail(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    """The one error shape used by every endpoint."""

    error: ErrorDetail
