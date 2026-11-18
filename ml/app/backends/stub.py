"""The stub OCR backend: fixed, invented data in the final response shapes.

It never looks at the images. It lets the Rails app and the tests work
before a real model is connected.
"""

from collections.abc import Sequence
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from app.backends.base import Backend, Extraction, ImageInput
from app.schemas import Receipt, ReceiptItem

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


class StubBackend(Backend):
    name = "stub"
    model_name = "stub-ocr"
    model_version = "0.1.0"

    def extract_receipt(self, images: Sequence[ImageInput]) -> Extraction:
        return Extraction(receipt=stub_receipt())
