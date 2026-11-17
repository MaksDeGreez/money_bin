"""Request and response models of the HTTP API.

Money and quantity values use `Decimal`. Pydantic writes them to JSON as
strings (for example "123.45"), so no precision is lost on the way to the
Rails app.
"""

from datetime import datetime
from decimal import Decimal
from typing import Annotated

from pydantic import AfterValidator, BaseModel, Field

MAX_TEXTS = 200
CANDIDATES_PER_TEXT = 3


class ReceiptItem(BaseModel):
    """One line of a receipt.

    `amount` is the final price of the line, after the discount.
    """

    name: str
    quantity: Decimal
    unit_price: Decimal
    amount: Decimal
    discount: Decimal = Decimal("0.00")


class Receipt(BaseModel):
    """The data read from a receipt.

    A real model will not always find every field, so most of them may be null.
    """

    merchant: str | None = None
    fiscal_number: str | None = None
    receipt_number: str | None = None
    issued_at: datetime | None = None
    total: Decimal
    currency: str = Field(pattern=r"^[A-Z]{3}$", description="ISO 4217 code, e.g. UAH.")
    items: list[ReceiptItem] = Field(default_factory=list)


class BackendInfo(BaseModel):
    """Which backend and model produced a response."""

    backend: str
    model_name: str
    model_version: str


class HealthResponse(BackendInfo):
    status: str = "ok"


class OcrResponse(BackendInfo):
    receipt: Receipt


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
