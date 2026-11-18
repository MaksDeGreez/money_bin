"""Post-processing of the model's raw answer. Every receipt here is invented."""

from datetime import datetime
from decimal import Decimal
from typing import Any

import pytest

from app.ocr.parsing import RawItem, RawReceipt
from app.ocr.postprocess import (
    Report,
    kyiv_datetime,
    parse_card_last4,
    parse_currency,
    parse_fiscal_number,
    parse_identifier,
    parse_issued_at,
    parse_kind,
    parse_money,
    parse_quantity,
    postprocess,
    sum_matches_total,
)
from app.schemas import ReceiptItem


def item(name: str | None, amount: str | None = None, **fields: Any) -> RawItem:
    return RawItem(name=name, amount=amount, **fields)


def receipt(*items: RawItem, **fields: Any) -> RawReceipt:
    return RawReceipt(items=list(items), **fields)


def items_of(raw: RawReceipt) -> list[dict[str, Any]]:
    result, _ = postprocess(raw)
    return [entry.model_dump(mode="json") for entry in result.items]


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("12.50", "12.50"),
        ("12,50", "12.50"),
        ("12.5", "12.50"),
        ("12", "12.00"),
        ("0,99", "0.99"),
        (".5", "0.50"),
        ("1 234,56", "1234.56"),
        ("1 234,56", "1234.56"),
        ("1.234,56", "1234.56"),
        ("1,234.56", "1234.56"),
        ("12,50 А", "12.50"),
        ("12.50Б", "12.50"),
        ("12,50 A", "12.50"),
        ("12,50 грн", "12.50"),
        ("12,50 грн.", "12.50"),
        ("₴ 12,50", "12.50"),
        ("UAH 12.50", "12.50"),
        ("-5,00", "-5.00"),
        ("−5,00", "-5.00"),
        ("–5.00", "-5.00"),
        ("  7.00  ", "7.00"),
    ],
)
def test_money_formats_are_read_exactly(text: str, expected: str) -> None:
    value = parse_money(text, Report())

    assert value == Decimal(expected)
    assert str(value) == expected


@pytest.mark.parametrize("text", ["12.505", "0.001", "1,2345"])
def test_money_with_more_than_two_places_is_refused_not_rounded(text: str) -> None:
    report = Report()

    assert parse_money(text, report) is None
    assert report.too_precise_money == 1


@pytest.mark.parametrize(
    "text",
    [
        "abc",
        "1.2.3",
        "1,2,3",
        "--5",
        "12 50 60,1.2",
        "12 50",
        "1.2,34",
        "1,23.4",
        "12.",
        "1e5",
        "NaN",
    ],
)
def test_unreadable_money_is_null_and_counted(text: str) -> None:
    report = Report()

    assert parse_money(text, report) is None
    assert report.unreadable_values == 1


@pytest.mark.parametrize("text", [None, "", "   "])
def test_missing_money_is_null_without_a_count(text: str | None) -> None:
    report = Report()

    assert parse_money(text, report) is None
    assert report == Report()


def test_the_tax_letter_is_counted() -> None:
    report = Report()

    parse_money("12,50 А", report)
    parse_money("12,50", report)

    assert report.tax_letters_stripped == 1


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("2", "2.000"),
        ("0,850", "0.850"),
        ("0.85 кг", "0.850"),
        ("1 шт", "1.000"),
        ("2,000 шт.", "2.000"),
        ("1.5л", "1.500"),
    ],
)
def test_quantities_keep_three_places_and_drop_units(text: str, expected: str) -> None:
    value = parse_quantity(text, Report())

    assert str(value) == expected


def test_a_quantity_with_four_places_is_refused() -> None:
    report = Report()

    assert parse_quantity("0.8505", report) is None
    assert report.too_precise_quantities == 1


def test_values_are_decimals_never_floats() -> None:
    result, _ = postprocess(
        receipt(item("Bread", "28,90", quantity="1", unit_price="28,90"), total="28,90")
    )

    assert isinstance(result.total, Decimal)
    assert all(isinstance(entry.amount, Decimal) for entry in result.items)


def test_a_full_receipt() -> None:
    raw = receipt(
        item("Milk 2.5%", "42,50 А", quantity="1", unit_price="42,50"),
        item("White bread", "28,90 А", quantity="1", unit_price="28,90"),
        kind="fiscal",
        merchant="  Example   Market ",
        fiscal_number="ФН 4000000001",
        receipt_number="ЧЕК № 000123",
        date="2026-01-15",
        time="12:34:56",
        total="71,40",
        currency="грн",
        card_last4="**** **** **** 4242",
    )

    result, report = postprocess(raw)

    assert result.model_dump(mode="json") == {
        "kind": "fiscal",
        "merchant": "Example Market",
        "fiscal_number": "4000000001",
        "receipt_number": "000123",
        "issued_at": "2026-01-15T12:34:56+02:00",
        "total": "71.40",
        "currency": "UAH",
        "card_last4": "4242",
        "sum_matches_total": True,
        "items": [
            {
                "name": "Milk 2.5%",
                "quantity": "1.000",
                "unit_price": "42.50",
                "amount": "42.50",
                "discount": "0.00",
            },
            {
                "name": "White bread",
                "quantity": "1.000",
                "unit_price": "28.90",
                "amount": "28.90",
                "discount": "0.00",
            },
        ],
    }
    assert report.tax_letters_stripped == 2


def test_a_card_slip_has_no_items_and_no_sum_check() -> None:
    raw = receipt(kind="card_slip", total="250.00", card_last4="XXXXXXXXXXXX1234", currency="UAH")

    result, _ = postprocess(raw)

    assert result.kind == "card_slip"
    assert result.items == []
    assert result.card_last4 == "1234"
    assert result.sum_matches_total is None


def test_a_quantity_line_below_the_name_goes_to_the_item_above() -> None:
    raw = receipt(item("Coffee", "130,00"), item("2,000 шт x 65,00"))

    assert items_of(raw) == [
        {
            "name": "Coffee",
            "quantity": "2.000",
            "unit_price": "65.00",
            "amount": "130.00",
            "discount": "0.00",
        }
    ]


def test_a_quantity_line_with_its_own_amount_fills_the_item_above() -> None:
    raw = receipt(item("Cheese"), item("0,850 x 64.00", "54.40"))
    result, report = postprocess(raw)

    assert [(e.name, str(e.quantity), str(e.amount)) for e in result.items] == [
        ("Cheese", "0.850", "54.40")
    ]
    assert report.quantity_lines_merged == 1


def test_a_quantity_line_with_amount_after_equals_sign() -> None:
    raw = receipt(item("Cheese"), item("0.850 x 64.00 = 54.40"))

    assert items_of(raw)[0]["amount"] == "54.40"


def test_a_quantity_line_above_the_name_goes_to_the_item_below() -> None:
    raw = receipt(
        item("Milk", "42.50", quantity="1", unit_price="42.50"),
        item("2 x 34.50"),
        item("Bread", "69.00 А"),
    )

    assert items_of(raw) == [
        {
            "name": "Milk",
            "quantity": "1.000",
            "unit_price": "42.50",
            "amount": "42.50",
            "discount": "0.00",
        },
        {
            "name": "Bread",
            "quantity": "2.000",
            "unit_price": "34.50",
            "amount": "69.00",
            "discount": "0.00",
        },
    ]


def test_a_quantity_line_takes_the_amount_to_an_item_below_without_one() -> None:
    raw = receipt(item("Milk", "42.50"), item("2 x 34.50", "69.00"), item("Bread"))

    assert items_of(raw)[1]["amount"] == "69.00"


def test_a_quantity_line_that_fits_no_item_is_left_over() -> None:
    raw = receipt(item("Milk", "42.50"), item("2 x 34.50"), item("Bread", "10.00"))
    result, report = postprocess(raw)

    assert [entry.name for entry in result.items] == ["Milk", "Bread"]
    assert report.lines_left_over == 1


def test_a_quantity_line_alone_is_left_over() -> None:
    _, report = postprocess(receipt(item("2 x 34.50")))

    assert report.lines_left_over == 1


def test_two_quantity_lines_in_a_row_do_not_attach_to_each_other() -> None:
    raw = receipt(item("Milk", "42.50"), item("2 x 34.50"), item("3 x 1.00"))
    result, report = postprocess(raw)

    assert [entry.name for entry in result.items] == ["Milk"]
    assert report.lines_left_over == 2


def test_weight_rounding_by_the_shop_still_matches() -> None:
    raw = receipt(item("Cheese", "54.59"), item("0.853 x 64.00"))

    assert items_of(raw)[0]["quantity"] == "0.853"


def test_a_quantity_and_price_in_the_quantity_field_are_split() -> None:
    raw = receipt(item("Juice", "69.00", quantity="2 x 34,50"))

    entry = items_of(raw)[0]
    assert (entry["quantity"], entry["unit_price"]) == ("2.000", "34.50")


def test_a_quantity_and_price_at_the_end_of_the_name_move_to_the_fields() -> None:
    raw = receipt(item("Juice 2 x 34.50", "69.00"))
    result, report = postprocess(raw)

    assert result.items[0].name == "Juice"
    assert result.items[0].quantity == Decimal("2.000")
    assert report.quantities_taken_from_names == 1


def test_a_quantity_and_price_at_the_start_of_the_name_move_to_the_fields() -> None:
    raw = receipt(item("2 x 34.50 Juice", "69.00"))

    assert items_of(raw)[0]["name"] == "Juice"


def test_a_pack_size_in_the_name_stays_when_it_does_not_fit_the_amount() -> None:
    raw = receipt(item("Water 6 x 1.5", "120.00"))
    result, report = postprocess(raw)

    assert result.items[0].name == "Water 6 x 1.5"
    assert result.items[0].quantity is None
    assert report.quantities_taken_from_names == 0


def test_a_quantity_in_the_name_without_an_amount_stays_in_the_name() -> None:
    raw = receipt(item("Water 6 x 1.5"), total="1.00")

    _, report = postprocess(raw)
    assert report.quantities_taken_from_names == 0


def test_a_discount_line_is_folded_into_the_item_above() -> None:
    raw = receipt(
        item("Bananas", "54.40", quantity="0.850", unit_price="64.00"),
        item("Знижка", "-2.35"),
        total="52.05",
    )

    result, report = postprocess(raw)

    assert result.items == [
        ReceiptItem(
            name="Bananas",
            quantity=Decimal("0.850"),
            unit_price=Decimal("64.00"),
            amount=Decimal("52.05"),
            discount=Decimal("2.35"),
        )
    ]
    assert result.sum_matches_total is True
    assert report.discount_lines_folded == 1


@pytest.mark.parametrize("name", ["ЗНИЖКА 10%", "знижка по картці", "Discount", "Акція"])
def test_discount_lines_are_recognised(name: str) -> None:
    raw = receipt(item("Tea", "50.00"), item(name, "5.00"))

    assert items_of(raw)[0]["discount"] == "5.00"
    assert items_of(raw)[0]["amount"] == "45.00"


def test_a_discount_value_in_the_discount_field_of_a_discount_line() -> None:
    raw = receipt(item("Tea", "50.00"), item("Знижка", None, discount="-5,00"))

    assert items_of(raw)[0]["discount"] == "5.00"


def test_a_discount_line_first_is_kept_as_an_item() -> None:
    raw = receipt(item("Знижка", "-5.00"), item("Tea", "50.00"))

    assert [entry["name"] for entry in items_of(raw)] == ["Знижка", "Tea"]


def test_a_discount_line_without_a_readable_value_changes_nothing() -> None:
    raw = receipt(item("Tea", "50.00"), item("Знижка картки", "-"))
    result, report = postprocess(raw)

    assert [(entry.name, entry.discount) for entry in result.items] == [("Tea", Decimal("0.00"))]
    assert report.discount_lines_folded == 0
    assert report.items_without_amount == 1


def test_an_item_discount_is_subtracted_from_the_printed_amount() -> None:
    raw = receipt(item("Tea", "50.00", discount="5.00"))

    entry = items_of(raw)[0]
    assert (entry["amount"], entry["discount"]) == ("45.00", "5.00")


def test_a_negative_item_discount_counts_as_its_size() -> None:
    raw = receipt(item("Tea", "50.00", discount="-5.00"))

    assert items_of(raw)[0]["discount"] == "5.00"


def test_a_returned_deposit_keeps_its_negative_amount() -> None:
    raw = receipt(item("Bottle deposit return", "-2.00"))

    assert items_of(raw)[0]["amount"] == "-2.00"


def test_a_missing_amount_is_derived_when_the_product_is_exact() -> None:
    raw = receipt(item("Juice", None, quantity="2", unit_price="34.50"), total="69.00")

    result, report = postprocess(raw)

    assert result.items[0].amount == Decimal("69.00")
    assert report.amounts_derived == 1
    assert result.sum_matches_total is True


def test_a_missing_amount_is_not_derived_when_it_would_need_rounding() -> None:
    raw = receipt(item("Cheese", None, quantity="0.853", unit_price="64.00"), total="54.59")

    result, report = postprocess(raw)

    assert result.items == []
    assert report.items_without_amount == 1
    assert report.amounts_derived == 0
    assert result.sum_matches_total is None


def test_an_item_without_a_name_is_dropped() -> None:
    result, report = postprocess(receipt(item("   ", "5.00"), item(None, "1.00")))

    assert result.items == []
    assert report.items_without_name == 2


@pytest.mark.parametrize(
    ("amounts", "total", "expected"),
    [
        (["1.10", "2.20"], "3.30", True),
        (["1.10", "2.20"], "3.31", False),
        ([], "3.30", None),
        (["1.10"], None, None),
    ],
)
def test_sum_matches_total(amounts: list[str], total: str | None, expected: bool | None) -> None:
    items = [
        ReceiptItem(name="x", quantity=None, unit_price=None, amount=Decimal(a)) for a in amounts
    ]

    result = sum_matches_total(items, Decimal(total) if total else None, incomplete=False)

    assert result is expected


def test_sum_matches_total_is_unknown_when_an_item_was_dropped() -> None:
    items = [ReceiptItem(name="x", quantity=None, unit_price=None, amount=Decimal("3.30"))]

    assert sum_matches_total(items, Decimal("3.30"), incomplete=True) is None


@pytest.mark.parametrize(
    ("date", "time", "expected"),
    [
        ("2026-01-15", "12:34", "2026-01-15T12:34:00+02:00"),
        ("15.01.2026", "12:34:56", "2026-01-15T12:34:56+02:00"),
        ("15.01.26", "12:34", "2026-01-15T12:34:00+02:00"),
        ("15/01/2026", "12.34", "2026-01-15T12:34:00+02:00"),
        ("2026.07.15", "08:00:00", "2026-07-15T08:00:00+03:00"),
        ("15.01.2026 12:34", None, "2026-01-15T12:34:00+02:00"),
        ("2026-01-15T12:34:56", None, "2026-01-15T12:34:56+02:00"),
    ],
)
def test_dates_and_times_are_kyiv_local_time(date: str, time: str | None, expected: str) -> None:
    value = parse_issued_at(date, time, Report())

    assert value is not None
    assert value.isoformat() == expected


def test_a_date_without_a_time_gives_no_moment() -> None:
    report = Report()

    assert parse_issued_at("2026-01-15", None, report) is None
    assert report.invalid_dates == 0


@pytest.mark.parametrize(
    ("date", "time"), [("31.02.2026", "12:00"), ("yesterday", "12:00"), ("2026-01-15", "25:61")]
)
def test_impossible_dates_and_times_are_null_and_counted(date: str, time: str) -> None:
    report = Report()

    assert parse_issued_at(date, time, report) is None
    assert report.invalid_dates == 1


def test_no_date_gives_no_moment() -> None:
    assert parse_issued_at(None, "12:00", Report()) is None


def test_a_time_skipped_by_the_spring_clock_change_is_refused() -> None:
    report = Report()

    # Kyiv moves from 03:00 to 04:00 on the last Sunday of March.
    assert parse_issued_at("2026-03-29", "03:30", report) is None
    assert report.invalid_dates == 1


def test_the_repeated_autumn_hour_is_summer_time() -> None:
    value = kyiv_datetime(datetime(2026, 10, 25).date(), datetime(2026, 1, 1, 3, 30).time())

    assert value is not None
    assert value.isoformat() == "2026-10-25T03:30:00+03:00"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("fiscal", "fiscal"),
        ("Card_Slip", "card_slip"),
        ("slip", "card_slip"),
        ("x", None),
        (None, None),
    ],
)
def test_kind(text: str | None, expected: str | None) -> None:
    assert parse_kind(text) == expected


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("UAH", "UAH"),
        ("грн", "UAH"),
        ("ГРН.", "UAH"),
        ("₴", "UAH"),
        ("eur", "EUR"),
        ("гривень", "UAH"),
        ("euro", None),
        (None, None),
    ],
)
def test_currency(text: str | None, expected: str | None) -> None:
    assert parse_currency(text) == expected


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("**** 1234", "1234"),
        ("1234", "1234"),
        ("XXXX XXXX XXXX 9876", "9876"),
        ("*12", None),
        (None, None),
    ],
)
def test_card_last4(text: str | None, expected: str | None) -> None:
    assert parse_card_last4(text) == expected


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("ФН 4000000001", "4000000001"),
        ("ФН ПРРО: 4000000001", "4000000001"),
        ("4000 000 001", "4000000001"),
        ("ФН чека 98765", "98765"),
        ("ЧЕК № 000123", "000123"),
        ("№123", "123"),
        ("AbC-12_x", "AbC-12_x"),
        ("  ", None),
        (None, None),
    ],
)
def test_identifiers_lose_their_label_and_spaces(text: str | None, expected: str | None) -> None:
    assert parse_identifier(text) == expected


@pytest.mark.parametrize("text", ["ПН 201234567890", "123", "40000000012", "ФН 40000O0001"])
def test_a_fiscal_number_that_is_not_ten_digits_is_refused(text: str) -> None:
    report = Report()

    assert parse_fiscal_number(text, report) is None
    assert report.fiscal_numbers_refused == 1


def test_a_receipt_with_no_items_key() -> None:
    result, _ = postprocess(RawReceipt(total="5.00"))

    assert result.items == []
    assert result.total == Decimal("5.00")


def test_the_report_lists_its_counts() -> None:
    _, report = postprocess(receipt(item("Tea", "1.005")))

    counts = report.as_dict()
    assert counts["too_precise_money"] == 1
    assert counts["items_without_amount"] == 1
    assert set(counts.values()) <= {0, 1}


def test_a_quantity_line_with_unreadable_numbers_stays_an_ordinary_line() -> None:
    raw = receipt(item("Tea", "50.00"), item("1.2345 x 1.005", "1.24"))
    result, report = postprocess(raw)

    assert [entry.name for entry in result.items] == ["Tea", "1.2345 x 1.005"]
    assert report.quantity_lines_merged == 0
