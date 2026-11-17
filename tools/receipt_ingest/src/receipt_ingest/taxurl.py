"""Reading the tax-service URL that a Ukrainian fiscal receipt carries in its QR code.

The receipt check page is `https://cabinet.tax.gov.ua/cashregs/check` with these query keys:
`id` is the fiscal number of the receipt, `fn` the fiscal number of the cash register (RRO/PRRO),
`sm` the amount with a dot as decimal separator, `date` yyyyMMdd, `time` HHmm (sometimes HHmmss or
HH:MM:SS), and `mac` the checksum that only offline software registers need.
"""

from __future__ import annotations

import re
from datetime import datetime
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo

KYIV = ZoneInfo("Europe/Kyiv")
TAX_HOST = "cabinet.tax.gov.ua"
TAX_PATH = "/cashregs/check"
QUERY_KEYS = ("date", "time", "id", "sm", "fn", "mac")

_DATE = re.compile(r"\d{8}")
_TIME_FORMS = (
    (re.compile(r"(\d{2})(\d{2})"), False),
    (re.compile(r"(\d{2})(\d{2})(\d{2})"), True),
    (re.compile(r"(\d{2}):(\d{2})"), False),
    (re.compile(r"(\d{2}):(\d{2}):(\d{2})"), True),
)
_FISCAL = re.compile(r"\d{10}")
# Digits on most receipts; letters, digits, "-" and "_" (an 11-character code) on some software
# registers.
_RECEIPT_NO = re.compile(r"[0-9A-Za-z_-]+")
_AMOUNT = re.compile(r"\d+(\.\d{1,2})?")
_TWO_PLACES = Decimal("0.01")


def is_tax_url(payload: str | None) -> bool:
    if not payload:
        return False
    try:
        parts = urlsplit(payload.strip())
    except ValueError:
        return False
    return (
        parts.scheme.lower() in ("http", "https")
        and (parts.hostname or "").lower() == TAX_HOST
        and parts.path.rstrip("/") == TAX_PATH
    )


def query_values(payload: str) -> dict[str, str | None]:
    """The raw values of the known query keys: the first one when a key repeats, else None."""
    query = parse_qs(urlsplit(payload.strip()).query, keep_blank_values=True)
    return {key: (query[key][0] if key in query else None) for key in QUERY_KEYS}


def _issued_at(date: str | None, time: str | None) -> str | None:
    if date is None or time is None or not _DATE.fullmatch(date):
        return None
    for pattern, has_seconds in _TIME_FORMS:
        match = pattern.fullmatch(time)
        if match:
            hour, minute = int(match.group(1)), int(match.group(2))
            second = int(match.group(3)) if has_seconds else 0
            break
    else:
        return None
    try:
        local = datetime(
            int(date[:4]), int(date[4:6]), int(date[6:]), hour, minute, second, tzinfo=KYIV
        )
    except ValueError:
        return None
    return local.isoformat()


def _total(amount: str | None) -> str | None:
    if amount is None or not _AMOUNT.fullmatch(amount):
        return None
    try:
        return str(Decimal(amount).quantize(_TWO_PLACES))
    except InvalidOperation:  # pragma: no cover - the pattern already admits only plain decimals
        return None


def _matching(value: str | None, pattern: re.Pattern[str]) -> str | None:
    return value if value is not None and pattern.fullmatch(value) else None


def parse(payload: str | None) -> tuple[dict | None, dict | None, bool]:
    """Return (qr, qr_fields, partial) for a QR payload.

    `qr` and `qr_fields` are None when the payload is not a tax-service URL. `partial` is True when
    some field could not be read.
    """
    if not is_tax_url(payload):
        return None, None, False
    assert payload is not None
    values = query_values(payload)
    fields = {
        "issued_at": _issued_at(values["date"], values["time"]),
        "total": _total(values["sm"]),
        "fiscal_number": _matching(values["fn"], _FISCAL),
        "receipt_number": _matching(values["id"], _RECEIPT_NO),
    }
    partial = any(value is None for value in fields.values())
    return values, fields, partial
