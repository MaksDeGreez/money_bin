"""Reading the tax-service URL that a Ukrainian fiscal receipt carries in its QR code.

The receipt check page is `https://cabinet.tax.gov.ua/cashregs/check` with these query keys:
`id` is the fiscal number of the receipt, `fn` the fiscal number of the cash register (RRO/PRRO),
`sm` the amount with a dot as decimal separator, `date` yyyyMMdd, `time` HHmm (sometimes HHmmss or
HH:MM:SS), and `mac` the checksum that only offline software registers need.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo

KYIV = ZoneInfo("Europe/Kyiv")
TAX_HOST = "cabinet.tax.gov.ua"
TAX_PATH = "/cashregs/check"
QUERY_KEYS = ("date", "time", "id", "sm", "fn", "mac")

# [0-9], not \d: \d also matches Arabic-Indic, fullwidth and other digits, which int() and
# Decimal() would then read as numbers.
_DATE = re.compile(r"[0-9]{8}")
_TIME_FORMS = (
    (re.compile(r"([0-9]{2})([0-9]{2})"), False),
    (re.compile(r"([0-9]{2})([0-9]{2})([0-9]{2})"), True),
    (re.compile(r"([0-9]{2}):([0-9]{2})"), False),
    (re.compile(r"([0-9]{2}):([0-9]{2}):([0-9]{2})"), True),
)
_FISCAL = re.compile(r"[0-9]{10}")
# Digits on most receipts; letters, digits, "-" and "_" (an 11-character code) on some software
# registers.
_RECEIPT_NO = re.compile(r"[0-9A-Za-z_-]+")
_AMOUNT = re.compile(r"[0-9]+(\.[0-9]{1,2})?")
_TWO_PLACES = Decimal("0.01")


def is_tax_url(payload: str | None) -> bool:
    """http(s), exactly the tax-service host, the check path.

    The network location must be the bare host: a URL with a user name or a port is not the tax
    service's check page, whatever host follows the `@`.
    """
    if not payload:
        return False
    try:
        parts = urlsplit(payload.strip())
    except ValueError:
        return False
    return (
        parts.scheme.lower() in ("http", "https")
        and parts.netloc.lower() == TAX_HOST
        and parts.path.rstrip("/") == TAX_PATH
    )


def query_values(payload: str) -> dict[str, str | None]:
    """The raw values of the known query keys: the first one when a key repeats, else None.

    The query is split by hand because parse_qs turns `+` into a space; only percent escapes are
    decoded.
    """
    found: dict[str, str] = {}
    for pair in urlsplit(payload.strip()).query.split("&"):
        if not pair:
            continue
        key, _, value = pair.partition("=")
        found.setdefault(unquote(key), unquote(value))
    return {key: found.get(key) for key in QUERY_KEYS}


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
    # A wall time inside the spring clock change (03:00-03:59 on the last Sunday of March) never
    # happened in Kyiv; zoneinfo would quietly give it an offset, so a round trip through UTC
    # finds it. In the repeated autumn hour fold=0 picks the first occurrence (summer time).
    if local.astimezone(UTC).astimezone(KYIV).replace(tzinfo=None) != local.replace(tzinfo=None):
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
