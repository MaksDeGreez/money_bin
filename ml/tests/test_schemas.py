from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.schemas import CategoriseResult, CategoryCandidate, Receipt, ReceiptItem


def test_decimals_are_written_as_strings_in_json() -> None:
    item = ReceiptItem(
        name="Example item",
        quantity=Decimal("2.000"),
        unit_price=Decimal("10.50"),
        amount=Decimal("21.00"),
    )

    assert item.model_dump(mode="json") == {
        "name": "Example item",
        "quantity": "2.000",
        "unit_price": "10.50",
        "amount": "21.00",
        "discount": "0.00",
    }


def test_decimal_strings_from_json_keep_their_precision() -> None:
    item = ReceiptItem.model_validate_json(
        '{"name": "x", "quantity": "0.333", "unit_price": "0.10", "amount": "0.03"}'
    )

    assert item.quantity == Decimal("0.333")
    assert item.discount == Decimal("0")


def test_receipt_allows_missing_optional_fields_and_no_items() -> None:
    receipt = Receipt(total=Decimal("0.00"), currency="EUR")

    assert receipt.model_dump(mode="json") == {
        "kind": None,
        "merchant": None,
        "fiscal_number": None,
        "receipt_number": None,
        "issued_at": None,
        "total": "0.00",
        "currency": "EUR",
        "card_last4": None,
        "sum_matches_total": None,
        "items": [],
    }


def test_every_receipt_key_is_present_even_when_everything_is_null() -> None:
    dumped = Receipt().model_dump(mode="json")

    assert dumped["total"] is None
    assert dumped["currency"] is None
    assert {"total", "currency", "items"} <= dumped.keys()


def test_item_quantity_and_unit_price_may_be_null_but_are_always_written() -> None:
    item = ReceiptItem(name="x", quantity=None, unit_price=None, amount=Decimal("1.00"))

    assert item.model_dump(mode="json") == {
        "name": "x",
        "quantity": None,
        "unit_price": None,
        "amount": "1.00",
        "discount": "0.00",
    }


@pytest.mark.parametrize("kind", ["receipt", "FISCAL", ""])
def test_kind_is_fiscal_card_slip_or_null(kind: str) -> None:
    with pytest.raises(ValidationError):
        Receipt(kind=kind)  # type: ignore[arg-type]


@pytest.mark.parametrize("last4", ["123", "12345", "12a4"])
def test_card_last4_is_four_digits(last4: str) -> None:
    with pytest.raises(ValidationError):
        Receipt(card_last4=last4)


@pytest.mark.parametrize("currency", ["uah", "UA", "UAHH", "", "U1H"])
def test_currency_must_be_a_three_letter_code(currency: str) -> None:
    with pytest.raises(ValidationError):
        Receipt(total=Decimal("1.00"), currency=currency)


@pytest.mark.parametrize("score", [-0.01, 1.01])
def test_candidate_score_must_be_between_zero_and_one(score: float) -> None:
    with pytest.raises(ValidationError):
        CategoryCandidate(category_slug="groceries/groceries", score=score)


@pytest.mark.parametrize("count", [2, 4])
def test_a_result_needs_exactly_three_candidates(count: int) -> None:
    candidates = [
        CategoryCandidate(category_slug=f"group/category-{n}", score=0.1) for n in range(count)
    ]

    with pytest.raises(ValidationError):
        CategoriseResult(text="milk", candidates=candidates)
