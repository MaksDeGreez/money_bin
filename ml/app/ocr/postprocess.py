"""Turning the model's raw answer into the API's `Receipt`, with plain code.

The model copies values as printed; this module does everything that needs
rules or arithmetic, so no model is trusted with it:

- numbers: a comma or a dot as the decimal separator, spaces as thousands
  separators, a currency sign or word, and the tax letter printed after an
  amount (`12,50 А`) are accepted; units after a quantity (`0,850 кг`) too;
- a quantity line (`2 x 34.50`) that the model listed as an item of its own,
  or left in an item's name, goes into the item it belongs to;
- a discount line (`Знижка -5.00`) is folded into the item above it;
- an item's `amount` is the printed line amount minus its discount;
- `sum_matches_total` compares the item amounts with the total.

Money is never rounded. Everything is `Decimal`, never a float. A money value
with more than 2 decimal places, or a quantity with more than 3, becomes null
and is counted in the report; a value is only rewritten when the new form is
exactly equal (`12.5` becomes `12.50`). An item amount is derived from the
quantity and the unit price only when their product has at most 2 decimal
places.
"""

import re
from dataclasses import asdict, dataclass, field
from datetime import UTC, date, datetime, time
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

from app.ocr.parsing import RawItem, RawReceipt
from app.schemas import Receipt, ReceiptItem, ReceiptKind

KYIV = ZoneInfo("Europe/Kyiv")
MONEY_PLACES = 2
QUANTITY_PLACES = 3
# When a quantity line is matched to an item, quantity x unit price may differ
# from the printed amount by the shop's own rounding (0.853 kg x 64.00 = 54.592,
# printed 54.59). This is only a comparison; nothing is rounded.
MATCH_TOLERANCE = Decimal("0.01")

_SPACES = re.compile("[\\s\u00a0\u2009\u202f]+")
_MINUS_SIGNS = str.maketrans({"\u2212": "-", "\u2013": "-", "\u2014": "-"})
# A currency word or sign before or after a number.
_CURRENCY = re.compile(r"(?i)(грн\.?|uah|₴)")
# One or two letters right after an amount: the tax group (А, Б, В, ... or A, B, ...).
_TAX_LETTER = re.compile(r"(?<=\d)\s*[A-Za-zА-ЯҐЄІЇа-яґєії]{1,2}\s*$")
# A unit after a quantity: шт, кг, г, л, мл, уп, pcs, kg, ... with an optional dot.
_UNIT = re.compile(r"(?<=\d)\s*[A-Za-zА-ЯҐЄІЇа-яґєії.]+\s*$")
_NUMBER = re.compile(r"^-?(\d+(\.\d+)?|\.\d+)$")
# Thousands groups: `1 234,56`, `1,234.56`, `1.234,56`.
_SPACE_GROUPED = re.compile("\\d{1,3}(?:[\\s\u00a0\u2009\u202f]\\d{3})+(?:[.,]\\d+)?")
_COMMA_GROUPED = re.compile(r"\d{1,3}(?:,\d{3})+\.\d+")
_DOT_GROUPED = re.compile(r"\d{1,3}(?:\.\d{3})+,\d+")

_QTY = r"\d+(?:[.,]\d+)?"
_UNIT_WORD = r"(?:\s*(?:шт|кг|г|л|мл|уп|pcs|kg)\.?)?"
_TIMES = r"\s*[xх×*XХ]\s*"
_QTY_PRICE = rf"(?P<quantity>{_QTY}){_UNIT_WORD}{_TIMES}(?P<price>{_QTY})"
# A line that is only a quantity and a price, maybe with "=" and the amount.
_QUANTITY_LINE = re.compile(rf"^\s*{_QTY_PRICE}(?:\s*=?\s*(?P<amount>-?{_QTY}))?\s*[A-ZА-Я]?\s*$")
# A quantity and a price at the start or the end of an item's name.
_LEADING_QTY_PRICE = re.compile(rf"^\s*{_QTY_PRICE}\s+(?P<rest>.*\S)\s*$")
_TRAILING_QTY_PRICE = re.compile(rf"^\s*(?P<rest>.*\S)\s+{_QTY_PRICE}\s*$")
_DISCOUNT_LINE = re.compile(r"(?i)^\s*(знижк|скидк|discount|акці)")

_DATE_FORMATS = ("%Y-%m-%d", "%d.%m.%Y", "%d.%m.%y", "%d/%m/%Y", "%Y.%m.%d", "%d-%m-%Y")
_TIME_FORMATS = ("%H:%M:%S", "%H:%M", "%H.%M.%S", "%H.%M")
_KINDS: dict[str, ReceiptKind] = {
    "fiscal": "fiscal",
    "card_slip": "card_slip",
    "card slip": "card_slip",
    "slip": "card_slip",
}
_CURRENCIES = {"ГРН": "UAH", "ГРН.": "UAH", "₴": "UAH", "ГРИВНЯ": "UAH", "ГРИВЕНЬ": "UAH"}
_IDENTIFIER_LABEL = re.compile(
    r"(?i)^\s*(фн\s*прро|фн\s*чека|фіскальний\s+номер(\s+чека)?|фн|чек|№|n|#)\s*[:№#.]?\s*"
)


@dataclass
class Report:
    """Counts of what post-processing changed or refused. Never receipt content."""

    unreadable_values: int = 0
    too_precise_money: int = 0
    too_precise_quantities: int = 0
    tax_letters_stripped: int = 0
    quantity_lines_merged: int = 0
    quantities_taken_from_names: int = 0
    discount_lines_folded: int = 0
    amounts_derived: int = 0
    items_without_amount: int = 0
    items_without_name: int = 0
    lines_left_over: int = 0
    invalid_dates: int = 0
    fiscal_numbers_refused: int = 0

    def as_dict(self) -> dict[str, int]:
        return asdict(self)


@dataclass
class _Item:
    """An item while it is being put together."""

    name: str
    quantity: Decimal | None = None
    unit_price: Decimal | None = None
    gross: Decimal | None = None
    discount: Decimal = field(default_factory=lambda: Decimal("0"))


def _squish(value: str | None) -> str | None:
    if value is None:
        return None
    text = _SPACES.sub(" ", value).strip()
    return text or None


def _number_text(value: str, report: Report, *, quantity: bool) -> str | None:
    """The plain decimal text of a printed number (`-1234.5`), or None."""
    text = value.translate(_MINUS_SIGNS)
    text = _CURRENCY.sub(" ", text).strip()
    if quantity:
        text = _UNIT.sub("", text)
    else:
        stripped = _TAX_LETTER.sub("", text)
        if stripped != text:
            report.tax_letters_stripped += 1
        text = stripped
    text = text.strip()
    sign = ""
    if text.startswith("-"):
        sign, text = "-", text[1:].strip()
    # A space, or the second kind of separator, only ever groups thousands:
    # anything else (`12 50`, `1.2,3`) is too ambiguous to read as money.
    if _SPACES.search(text):
        if not _SPACE_GROUPED.fullmatch(text):
            return None
        text = _SPACES.sub("", text)
    if "," in text and "." in text:
        if _COMMA_GROUPED.fullmatch(text):
            text = text.replace(",", "")
        elif _DOT_GROUPED.fullmatch(text):
            text = text.replace(".", "").replace(",", ".")
        else:
            return None
    elif text.count(",") == 1:
        text = text.replace(",", ".")
    text = sign + text
    return text if _NUMBER.match(text) else None


def parse_decimal(value: str | None, places: int, report: Report) -> Decimal | None:
    """A printed number as a `Decimal` with exactly `places` decimal places, or None.

    Never rounds: a number with more places than `places` is refused (None) and
    counted. Fewer places are padded with zeros, which keeps the value exact.
    """
    if value is None or not value.strip():
        return None
    quantity = places == QUANTITY_PLACES
    text = _number_text(value, report, quantity=quantity)
    if text is None:
        report.unreadable_values += 1
        return None
    try:
        number = Decimal(text)
    except InvalidOperation:  # pragma: no cover - the pattern above only lets decimals through
        report.unreadable_values += 1
        return None
    exponent = number.as_tuple().exponent
    assert isinstance(exponent, int)  # a finite decimal, never NaN or Infinity
    if -exponent > places:
        if quantity:
            report.too_precise_quantities += 1
        else:
            report.too_precise_money += 1
        return None
    return number.quantize(Decimal(1).scaleb(-places))


def parse_money(value: str | None, report: Report) -> Decimal | None:
    return parse_decimal(value, MONEY_PLACES, report)


def parse_quantity(value: str | None, report: Report) -> Decimal | None:
    return parse_decimal(value, QUANTITY_PLACES, report)


def _parse_date(value: str) -> date | None:
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    return None


def _parse_time(value: str) -> time | None:
    for fmt in _TIME_FORMATS:
        try:
            return datetime.strptime(value, fmt).time()
        except ValueError:
            continue
    return None


def kyiv_datetime(day: date, moment: time) -> datetime | None:
    """A Kyiv local date and time with its offset, or None when it never existed.

    In the hour that happens twice in autumn the first occurrence (summer time)
    is taken. A time skipped when the clocks go forward gives None.
    """
    local = datetime.combine(day, moment, tzinfo=KYIV)
    round_trip = local.astimezone(UTC).astimezone(KYIV)
    if round_trip.replace(tzinfo=None) != local.replace(tzinfo=None):
        return None
    return local


def parse_issued_at(
    date_text: str | None, time_text: str | None, report: Report
) -> datetime | None:
    """The purchase time from the printed date and time, in Kyiv time.

    The model may put both into `date` ("16.12.2025 12:52"). Without a readable
    time the result is None: a midnight that was never printed would be wrong.
    """
    date_part = _squish(date_text)
    time_part = _squish(time_text)
    if date_part is None:
        return None
    pieces = date_part.replace("T", " ").split(" ")
    if len(pieces) == 2 and time_part is None:
        date_part, time_part = pieces
    day = _parse_date(date_part)
    moment = _parse_time(time_part) if time_part else None
    if day is None or (time_part is not None and moment is None):
        report.invalid_dates += 1
        return None
    if moment is None:
        return None
    issued_at = kyiv_datetime(day, moment)
    if issued_at is None:
        report.invalid_dates += 1
    return issued_at


def parse_kind(value: str | None) -> ReceiptKind | None:
    text = _squish(value)
    return _KINDS.get(text.lower()) if text else None


def parse_currency(value: str | None) -> str | None:
    text = _squish(value)
    if text is None:
        return None
    code = _CURRENCIES.get(text.upper(), text.upper())
    return code if re.fullmatch(r"[A-Z]{3}", code) else None


def parse_card_last4(value: str | None) -> str | None:
    """The last four digits of a masked card number (`**** 1234`), or None."""
    if value is None:
        return None
    digits = re.findall(r"[0-9]", value)
    return "".join(digits[-4:]) if len(digits) >= 4 else None


def parse_identifier(value: str | None) -> str | None:
    """A fiscal number or receipt number without its label and spaces."""
    text = _squish(value)
    if text is None:
        return None
    text = _IDENTIFIER_LABEL.sub("", text)
    text = _SPACES.sub("", text)
    return text or None


def parse_fiscal_number(value: str | None, report: Report) -> str | None:
    """The cash register's fiscal number: exactly 10 digits, or None.

    The usual mistake is the 12-digit tax number printed at the top; anything
    that is not 10 digits is refused and counted, never trimmed to fit.
    """
    text = parse_identifier(value)
    if text is None:
        return None
    if re.fullmatch(r"[0-9]{10}", text) is None:
        report.fiscal_numbers_refused += 1
        return None
    return text


def _close(left: Decimal, right: Decimal) -> bool:
    return abs(left - right) <= MATCH_TOLERANCE


def _consistent(item: _Item, quantity: Decimal, price: Decimal) -> bool:
    """Whether quantity x price fits the item's printed amount (or it has none)."""
    return item.gross is None or _close(quantity * price, item.gross)


def _quantity_line(raw: RawItem, report: Report) -> tuple[Decimal, Decimal, Decimal | None] | None:
    """(quantity, unit price, amount) when the item is only a quantity line."""
    name = _squish(raw.name) or ""
    match = _QUANTITY_LINE.match(name)
    if match is None:
        return None
    quantity = parse_quantity(match["quantity"], report)
    price = parse_money(match["price"], report)
    if quantity is None or price is None:
        return None
    amount = parse_money(match["amount"], report) if match["amount"] else None
    if amount is None:
        amount = parse_money(raw.amount, report)
    return quantity, price, amount


def _take_quantity_from_name(item: _Item, report: Report) -> None:
    """Move `2 x 34.50` from the start or end of a name into the item's fields.

    Only when the numbers fit the printed amount: `Water 6 x 1.5` is a pack
    size, not a quantity and a price.
    """
    for pattern in (_LEADING_QTY_PRICE, _TRAILING_QTY_PRICE):
        match = pattern.match(item.name)
        if match is None:
            continue
        scratch = Report()
        quantity = parse_quantity(match["quantity"], scratch)
        price = parse_money(match["price"], scratch)
        if quantity is None or price is None or item.gross is None:
            return
        if not _close(quantity * price, item.gross):
            return
        item.name = match["rest"]
        item.quantity = quantity
        item.unit_price = price
        report.quantities_taken_from_names += 1
        return


def _split_quantity_field(raw: RawItem, report: Report) -> tuple[Decimal | None, Decimal | None]:
    """The quantity and unit price; `2 x 34.50` in the quantity field gives both."""
    text = raw.quantity or ""
    match = re.fullmatch(rf"\s*{_QTY_PRICE}\s*", text)
    if match is not None:
        return parse_quantity(match["quantity"], report), parse_money(match["price"], report)
    return parse_quantity(raw.quantity, report), parse_money(raw.unit_price, report)


def _attach_quantity_line(
    items: list[_Item],
    upcoming: list[RawItem],
    line: tuple[Decimal, Decimal, Decimal | None],
    report: Report,
) -> bool:
    """Give a quantity line to the item above or, failing that, the one below.

    The item above is preferred (most receipts print the quantity line under
    the name). An item takes the line only when quantity x price fits its
    printed amount, or it has none. Returns False when no item can take it.
    """
    quantity, price, amount = line
    if items and _consistent(items[-1], quantity, price):
        above = items[-1]
        above.quantity = quantity
        above.unit_price = price
        if above.gross is None:
            above.gross = amount
        report.quantity_lines_merged += 1
        return True
    below = upcoming[0] if upcoming else None
    if below is None or _squish(below.name) is None or _QUANTITY_LINE.match(below.name or ""):
        return False
    below_amount = parse_money(below.amount, Report())
    if below_amount is not None and not _close(quantity * price, below_amount):
        return False
    upcoming[0] = below.model_copy(
        update={
            "quantity": str(quantity),
            "unit_price": str(price),
            "amount": below.amount if below_amount is not None else _text(amount),
        }
    )
    report.quantity_lines_merged += 1
    return True


def _text(value: Decimal | None) -> str | None:
    return None if value is None else str(value)


def _fold_discount(items: list[_Item], raw: RawItem, report: Report) -> bool:
    """Fold a discount line into the item above. False when there is none."""
    if not items:
        return False
    value = parse_money(raw.amount, report)
    if value is None:
        value = parse_money(raw.discount, report)
    if value is None:
        return False
    items[-1].discount += abs(value)
    report.discount_lines_folded += 1
    return True


def _build_items(raw_items: list[RawItem], report: Report) -> list[_Item]:
    items: list[_Item] = []
    pending = list(raw_items)
    while pending:
        raw = pending.pop(0)
        line = _quantity_line(raw, report)
        if line is not None:
            if not _attach_quantity_line(items, pending, line, report):
                report.lines_left_over += 1
            continue
        name = _squish(raw.name)
        if name is not None and _DISCOUNT_LINE.match(name) and _fold_discount(items, raw, report):
            continue
        if name is None:
            report.items_without_name += 1
            continue
        quantity, price = _split_quantity_field(raw, report)
        item = _Item(
            name=name,
            quantity=quantity,
            unit_price=price,
            gross=parse_money(raw.amount, report),
        )
        discount = parse_money(raw.discount, report)
        if discount is not None:
            item.discount = abs(discount)
        if item.quantity is None or item.unit_price is None:
            _take_quantity_from_name(item, report)
        items.append(item)
    return items


def _derive_amount(item: _Item, report: Report) -> None:
    """Fill a missing printed amount from quantity x unit price when that is exact."""
    if item.gross is not None or item.quantity is None or item.unit_price is None:
        return
    product = (item.quantity * item.unit_price).normalize()
    exponent = product.as_tuple().exponent
    assert isinstance(exponent, int)
    if -exponent <= MONEY_PLACES:
        item.gross = product.quantize(Decimal("0.01"))
        report.amounts_derived += 1


def _finish(items: list[_Item], report: Report) -> tuple[list[ReceiptItem], bool]:
    """The API items, and whether any item was dropped for a missing amount."""
    result = []
    dropped = False
    for item in items:
        _derive_amount(item, report)
        if item.gross is None:
            report.items_without_amount += 1
            dropped = True
            continue
        discount = item.discount.quantize(Decimal("0.01"))
        result.append(
            ReceiptItem(
                name=item.name,
                quantity=item.quantity,
                unit_price=item.unit_price,
                amount=item.gross - discount,
                discount=discount,
            )
        )
    return result, dropped


def sum_matches_total(
    items: list[ReceiptItem], total: Decimal | None, *, incomplete: bool
) -> bool | None:
    """Whether the item amounts add up exactly to the total.

    None when it cannot be known: no total, no item, or an item was dropped
    because its amount was unreadable.
    """
    if total is None or not items or incomplete:
        return None
    return sum((item.amount for item in items), Decimal("0")) == total


def postprocess(raw: RawReceipt) -> tuple[Receipt, Report]:
    """The API receipt from the model's raw answer, and the counts of what changed."""
    report = Report()
    items, dropped = _finish(_build_items(raw.items or [], report), report)
    total = parse_money(raw.total, report)
    receipt = Receipt(
        kind=parse_kind(raw.kind),
        merchant=_squish(raw.merchant),
        fiscal_number=parse_fiscal_number(raw.fiscal_number, report),
        receipt_number=parse_identifier(raw.receipt_number),
        issued_at=parse_issued_at(raw.date, raw.time, report),
        total=total,
        currency=parse_currency(raw.currency),
        card_last4=parse_card_last4(raw.card_last4),
        sum_matches_total=sum_matches_total(items, total, incomplete=dropped),
        items=items,
    )
    return receipt, report
