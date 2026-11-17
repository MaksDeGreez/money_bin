import pytest

from receipt_ingest import taxurl

BASE = "https://cabinet.tax.gov.ua/cashregs/check"
MAC40 = "0123456789abcdef0123456789abcdef01234567"
MAC64 = "f" * 64


def test_full_url_with_hhmm_time():
    qr, fields, partial = taxurl.parse(
        f"{BASE}?id=7001&date=20260301&time=1015&fn=4000000001&sm=12.30&mac={MAC40}"
    )
    assert qr == {
        "date": "20260301",
        "time": "1015",
        "id": "7001",
        "sm": "12.30",
        "fn": "4000000001",
        "mac": MAC40,
    }
    assert fields == {
        "issued_at": "2026-03-01T10:15:00+02:00",
        "total": "12.30",
        "fiscal_number": "4000000001",
        "receipt_number": "7001",
    }
    assert partial is False


def test_time_with_colons_and_seconds_in_summer_time():
    _, fields, partial = taxurl.parse(
        f"{BASE}?fn=4000000002&id=AB12cd34XYZ&sm=5&date=20260715&time=08:05:09&mac={MAC64}"
    )
    assert fields["issued_at"] == "2026-07-15T08:05:09+03:00"
    assert fields["total"] == "5.00"
    assert fields["receipt_number"] == "AB12cd34XYZ"
    assert partial is False


@pytest.mark.parametrize(
    ("time", "expected"),
    [("101500", "10:15:00"), ("10:15", "10:15:00"), ("1015", "10:15:00"), ("23:59:58", "23:59:58")],
)
def test_time_forms(time, expected):
    _, fields, _ = taxurl.parse(f"{BASE}?id=1&date=20260301&time={time}&fn=4000000001&sm=1.00")
    assert fields["issued_at"] == f"2026-03-01T{expected}+02:00"


def test_missing_mac_whole_number_sum_and_another_order():
    qr, fields, partial = taxurl.parse(
        f"{BASE}/?sm=123&time=0900&fn=4000000003&date=20260102&id=55"
    )
    assert qr["mac"] is None
    assert fields["total"] == "123.00"
    assert fields["issued_at"] == "2026-01-02T09:00:00+02:00"
    assert partial is False


@pytest.mark.parametrize(("amount", "total"), [("123.4", "123.40"), ("0.05", "0.05")])
def test_amounts(amount, total):
    _, fields, _ = taxurl.parse(f"{BASE}?id=1&date=20260301&time=1015&fn=4000000001&sm={amount}")
    assert fields["total"] == total


def test_host_and_scheme_case_do_not_matter():
    assert taxurl.is_tax_url("HTTP://Cabinet.Tax.Gov.UA/cashregs/check?id=1")


@pytest.mark.parametrize(
    "payload",
    [
        "https://x@cabinet.tax.gov.ua/cashregs/check?id=1",
        "https://user:pass@cabinet.tax.gov.ua/cashregs/check?id=1",
        "https://cabinet.tax.gov.ua:444/cashregs/check?id=1",
        "https://cabinet.tax.gov.ua:443/cashregs/check?id=1",
        "https://cabinet.tax.gov.ua:/cashregs/check?id=1",
        "https://cabinet.tax.gov.ua@shop.example.test/cashregs/check?id=1",
    ],
)
def test_userinfo_or_a_port_is_not_the_tax_service(payload):
    assert not taxurl.is_tax_url(payload)
    assert taxurl.parse(payload) == (None, None, False)


def test_query_values_are_raw():
    qr, fields, _ = taxurl.parse(
        f"{BASE}?id=12+34&sm=12%2E30&fn=4000000001&fn=4000000002&date=20260301&time=10%3A15&mac=a%2Bb"
    )
    assert qr["id"] == "12+34"  # parse_qs would have made it "12 34"
    assert qr["sm"] == "12.30"
    assert qr["fn"] == "4000000001"  # the first of a repeated key
    assert qr["time"] == "10:15"
    assert qr["mac"] == "a+b"
    assert fields["total"] == "12.30" and fields["issued_at"] == "2026-03-01T10:15:00+02:00"


def arabic(digits: str) -> str:
    return "".join(chr(0x0660 + int(d)) for d in digits)


def fullwidth(digits: str) -> str:
    return "".join(chr(0xFF10 + int(d)) if d.isdigit() else d for d in digits)


@pytest.mark.parametrize(
    ("values", "field"),
    [
        # Arabic-Indic and fullwidth digits match \d, and int() and Decimal() read them.
        ({"date": arabic("20260301")}, "issued_at"),
        ({"time": arabic("1015")}, "issued_at"),
        ({"sm": fullwidth("12.30")}, "total"),
        ({"fn": fullwidth("40000000") + "01"}, "fiscal_number"),
    ],
)
def test_only_ascii_digits_count(values, field):
    query = {"id": "1", "date": "20260301", "time": "1015", "fn": "4000000001", "sm": "1.00"}
    query.update(values)
    text = "&".join(f"{key}={value}" for key, value in query.items())
    _, fields, partial = taxurl.parse(f"{BASE}?{text}")
    assert fields[field] is None
    assert partial is True


def test_a_time_inside_the_spring_clock_change_never_existed():
    # Kyiv moved its clocks from 03:00 to 04:00 on 31 March 2024.
    _, fields, partial = taxurl.parse(f"{BASE}?id=1&date=20240331&time=0330&fn=4000000001&sm=1")
    assert fields["issued_at"] is None
    assert partial is True
    _, fields, _ = taxurl.parse(f"{BASE}?id=1&date=20240331&time=0430&fn=4000000001&sm=1")
    assert fields["issued_at"] == "2024-03-31T04:30:00+03:00"


def test_the_repeated_autumn_hour_takes_the_first_occurrence():
    # On 27 October 2024 Kyiv clocks went from 04:00 back to 03:00, so 03:30 happened twice.
    _, fields, partial = taxurl.parse(f"{BASE}?id=1&date=20241027&time=0330&fn=4000000001&sm=1")
    assert fields["issued_at"] == "2024-10-27T03:30:00+03:00"
    assert partial is False


@pytest.mark.parametrize(
    "payload",
    [
        None,
        "",
        "plain text on a receipt",
        "https://cabinet.tax.gov.ua/other?id=1",
        "https://example.test/cashregs/check?id=1",
        "ftp://cabinet.tax.gov.ua/cashregs/check?id=1",
        "http://[bad",
    ],
)
def test_not_a_tax_url(payload):
    assert taxurl.parse(payload) == (None, None, False)


@pytest.mark.parametrize(
    ("query", "field"),
    [
        ("id=1&date=2026031&time=1015&fn=4000000001&sm=1.00", "issued_at"),
        ("id=1&date=20261301&time=1015&fn=4000000001&sm=1.00", "issued_at"),
        ("id=1&date=20260301&time=2575&fn=4000000001&sm=1.00", "issued_at"),
        ("id=1&date=20260301&time=10h15&fn=4000000001&sm=1.00", "issued_at"),
        ("id=1&date=20260301&fn=4000000001&sm=1.00", "issued_at"),
        ("id=1&date=20260301&time=1015&fn=4000000001&sm=1,50", "total"),
        ("id=1&date=20260301&time=1015&fn=4000000001&sm=1.505", "total"),
        ("id=1&date=20260301&time=1015&fn=400000&sm=1.00", "fiscal_number"),
        ("id=1&date=20260301&time=1015&sm=1.00", "fiscal_number"),
        ("id=a+b&date=20260301&time=1015&fn=4000000001&sm=1.00", "receipt_number"),
    ],
)
def test_unparsable_field_is_null_and_partial(query, field):
    qr, fields, partial = taxurl.parse(f"{BASE}?{query}")
    assert qr is not None
    assert fields[field] is None
    assert partial is True
