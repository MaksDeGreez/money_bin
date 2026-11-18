"""The OCR prompt and the JSON schema of the model's answer.

The model answers with the "raw" receipt: values copied as printed, as strings.
`app.ocr.postprocess` turns that into the API's `Receipt` with plain code, so
the model never has to do arithmetic or format decimals.

`PROMPT_VERSION` is a short hash of every text and the schema below. Any change
to them gives a new version, so a stored OCR result says which prompt produced it.
"""

import hashlib
import json
from dataclasses import dataclass
from typing import Any

SYSTEM_PROMPT = (
    "You read photos of Ukrainian shop receipts and card terminal slips. "
    "You answer with one JSON object and nothing else."
)

_ONE_IMAGE = "The image shows one paper document."

_SEVERAL_IMAGES = (
    "The {count} images are overlapping photos of ONE long receipt, in order from top to "
    "bottom. Read them together as a single receipt. Lines near the edge of one photo often "
    "appear again at the start of the next: list each item only once."
)

_INSTRUCTIONS = """\
First decide what the document is (`kind`):
- "fiscal": a fiscal receipt (фіскальний чек) with item lines, a total (СУМА, ДО СПЛАТИ, \
РАЗОМ), the cash register's fiscal number and the receipt's fiscal number.
- "card_slip": a card terminal slip (квитанція, чек POS-терміналу): merchant, date and time, \
the amount and a masked card number such as **** 1234. It has no item lines.
- null when it is neither.

Fields. Use null when a field is not printed or cannot be read. Never guess.
- merchant: the shop or company name at the top (ТОВ ..., ФОП ..., the store name).
- fiscal_number: the fiscal number of the CASH REGISTER: exactly 10 digits, printed in the \
last lines of the receipt after "ФН" or "ФН ПРРО" (often on one line with "ЗН" or the date). \
It is NOT the 12-digit tax number after "ПН" or "ІПН" at the top, and NOT a transaction \
number (ТРН, RRN, Код транз.).
- receipt_number: the fiscal number of THIS RECEIPT, printed in the last lines after \
"ЧЕК №", "ФН чека" or "Фіскальний номер чека". It is NOT an order number (Замовлення №) \
or a document number (Док.).
- date: the date of the purchase as YYYY-MM-DD.
- time: the time of the purchase as HH:MM:SS, or HH:MM when no seconds are printed. It is \
Kyiv local time; copy it as printed.
- total: the amount paid (СУМА, ДО СПЛАТИ).
- currency: "UAH" for гривня (грн), otherwise the three-letter ISO code.
- card_last4: the last four digits of the card number, when a card number is printed \
(ЕПЗ, картка: **** 1234).
- items: every purchased item, in printed order, between the header and the total. An \
empty list on a card slip.
  - name: the item text as printed, without its quantity and prices.
  - quantity: the number of units or the weight, e.g. "2" or "0.850". "1" when no quantity \
is printed.
  - unit_price: the price of one unit (or one kilogram).
  - amount: the line amount printed at the right of the item, BEFORE any discount.
  - discount: the discount printed for this item (знижка), as a positive number, or null.

Copy every number exactly as printed. Do not calculate, do not round. Leave out the tax \
letter (А, Б, В, ...) printed after an amount, and the currency sign.

A line such as "2,000 шт x 65,00" or "0.850 x 64.00" is the quantity and unit price of the \
item printed next to it, above or below; put its numbers into that item's quantity and \
unit_price, and do not list it as an item of its own. These lines are NOT items: item codes \
(Код, Артикул, a barcode), the cashier (Касир), subtotals, taxes (ПДВ, акциз), the payment \
(Готівка, Картка, Еквайринг, Оплата), the change (решта), rounding (заокруглення), bonus or \
loyalty lines (БАЛАНС, НАРАХОВАНО, бонуси) and anything after the total.

Answer with the JSON object only."""

_REPAIR = """\
Your previous answer could not be used. Problems: {problems}

Your previous answer was:
{previous}

Read the receipt again and answer with the complete, corrected JSON object only."""

# The longest previous answer quoted back to the model in the repair pass.
MAX_REPAIR_QUOTE = 12_000

_TEXT = {"type": ["string", "null"]}

ANSWER_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "kind": {"enum": ["fiscal", "card_slip", None]},
        "merchant": _TEXT,
        "fiscal_number": _TEXT,
        "receipt_number": _TEXT,
        "date": _TEXT,
        "time": _TEXT,
        "total": _TEXT,
        "currency": _TEXT,
        "card_last4": _TEXT,
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "quantity": _TEXT,
                    "unit_price": _TEXT,
                    "amount": _TEXT,
                    "discount": _TEXT,
                },
                "required": ["name", "quantity", "unit_price", "amount", "discount"],
                "additionalProperties": False,
            },
        },
    },
    "required": [
        "kind",
        "merchant",
        "fiscal_number",
        "receipt_number",
        "date",
        "time",
        "total",
        "currency",
        "card_last4",
        "items",
    ],
    "additionalProperties": False,
}


def _version() -> str:
    parts = [
        SYSTEM_PROMPT,
        _ONE_IMAGE,
        _SEVERAL_IMAGES,
        _INSTRUCTIONS,
        _REPAIR,
        str(MAX_REPAIR_QUOTE),
        json.dumps(ANSWER_SCHEMA, sort_keys=True, ensure_ascii=False),
    ]
    digest = hashlib.sha256("\x00".join(parts).encode()).hexdigest()
    return digest[:12]


PROMPT_VERSION = _version()


@dataclass(frozen=True)
class Repair:
    """What the repair pass tells the model: its previous answer and what was wrong."""

    previous: str
    problems: str


def user_prompt(image_count: int, repair: Repair | None = None) -> str:
    """The user message for `image_count` images (1 to 3) of one receipt."""
    if image_count < 1:
        raise ValueError("at least one image is needed")
    intro = _ONE_IMAGE if image_count == 1 else _SEVERAL_IMAGES.format(count=image_count)
    text = f"{intro}\n\n{_INSTRUCTIONS}"
    if repair is not None:
        previous = repair.previous[:MAX_REPAIR_QUOTE]
        text += "\n\n" + _REPAIR.format(problems=repair.problems, previous=previous)
    return text


def build_messages(image_count: int, repair: Repair | None = None) -> list[dict[str, str]]:
    """The chat messages: a system message and one user message.

    The images belong to the user message; each backend attaches them in the
    form its model expects.
    """
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt(image_count, repair)},
    ]
