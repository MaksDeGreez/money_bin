"""The stub backend: fixed, invented data in the final response shapes.

It never looks at the images. It lets the Rails app and the tests work
before a real model is connected.
"""

import hashlib
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from app.backends.base import Backend, Extraction, ImageInput
from app.schemas import (
    CANDIDATES_PER_TEXT,
    CategoriseResult,
    CategoryCandidate,
    Receipt,
    ReceiptItem,
)

STUB_CATEGORY_SLUGS: tuple[str, ...] = (
    "groceries/groceries",
    "household-shopping/household-supplies",
    "eating-out/takeaway-fast-food",
    "transport/local-transport",
    "health/health-pharmacy",
    "car/fuel",
)

_STUB_ITEMS: tuple[ReceiptItem, ...] = (
    ReceiptItem(
        name="Milk 2.5% 900 g",
        quantity=Decimal("1.000"),
        unit_price=Decimal("42.50"),
        amount=Decimal("42.50"),
    ),
    ReceiptItem(
        name="White bread",
        quantity=Decimal("1.000"),
        unit_price=Decimal("28.90"),
        amount=Decimal("28.90"),
    ),
    ReceiptItem(
        name="Bananas",
        quantity=Decimal("0.850"),
        unit_price=Decimal("64.00"),
        amount=Decimal("52.05"),
        discount=Decimal("2.35"),
    ),
)


def stub_receipt() -> Receipt:
    """Return the fixed example receipt. The item amounts add up to the total."""
    return Receipt(
        kind="fiscal",
        merchant="Example Market",
        fiscal_number="0000000000",
        receipt_number="000123",
        issued_at=datetime(2026, 1, 15, 12, 34, tzinfo=timezone(timedelta(hours=2))),
        total=Decimal("123.45"),
        currency="UAH",
        sum_matches_total=True,
        items=[item.model_copy() for item in _STUB_ITEMS],
    )


def _weight(text: str, slug: str) -> float:
    """A positive weight that depends only on the text and the slug.

    The power makes the weights uneven, so one slug usually wins clearly,
    as with a real classifier.
    """
    digest = hashlib.sha256(f"{text}\x00{slug}".encode()).digest()
    return ((int.from_bytes(digest[:4], "big") + 1) / 2**32) ** 4


def stub_candidates(text: str) -> list[CategoryCandidate]:
    """Score every slug from a hash of the text and return the top three.

    The scores are shares of one distribution over all slugs, so they are in
    0..1 and their sum is at most 1. A hash (not `random`) keeps the answer
    the same for the same text.
    """
    weights = {slug: _weight(text, slug) for slug in STUB_CATEGORY_SLUGS}
    total = sum(weights.values())
    ranked = sorted(weights.items(), key=lambda pair: pair[1], reverse=True)
    return [
        CategoryCandidate(category_slug=slug, score=round(weight / total, 4))
        for slug, weight in ranked[:CANDIDATES_PER_TEXT]
    ]


class StubBackend(Backend):
    name = "stub"
    model_name = "stub-ocr"
    model_version = "0.1.0"
    categoriser_model_name = "stub-categoriser"

    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        return Extraction(receipt=stub_receipt())

    def categorise(self, texts: Sequence[str]) -> list[CategoriseResult]:
        return [CategoriseResult(text=text, candidates=stub_candidates(text)) for text in texts]
