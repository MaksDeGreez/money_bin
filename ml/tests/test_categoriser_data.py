"""The export reader, the row rules and the date split of the transaction categoriser."""

from __future__ import annotations

import json
from datetime import date
from decimal import Decimal
from pathlib import Path

import pytest

from categoriser.dataset import Row, build_rows, label_for, normalize_payee
from categoriser.export import ExportError, load_export
from categoriser.split import SplitError, split_by_date
from tests.categoriser_export import build_transactions, write_export


def make_row(day: date, legacy_id: str = "1", **fields: object) -> Row:
    values: dict[str, object] = {
        "occurred_on": day,
        "legacy_id": legacy_id,
        "label": "Groceries / Groceries",
        "payee": "",
        "comment": "",
        "bank_description": "",
        "merchant": "",
        "mcc": "",
        "amount": Decimal("-10.00"),
        "currency": "UAH",
        "account_kind": "debit",
    }
    values.update(fields)
    return Row(**values)  # type: ignore[arg-type]


def tx(legacy_id: int, lines: list[dict[str, object]], **fields: object) -> dict[str, object]:
    row: dict[str, object] = {
        "legacy_id": legacy_id,
        "account_legacy_id": 2,
        "occurred_on": "2025-01-01",
        "occurred_at": None,
        "amount": "-100.00",
        "currency": "UAH",
        "original_amount": None,
        "original_currency": None,
        "payee_legacy_id": None,
        "comment": None,
        "mcc": None,
        "bank_description": None,
        "merchant": None,
        "source_system": None,
        "transfer_key": None,
        "lines": lines,
    }
    row.update(fields)
    return row


def line(amount: str, category: int | None) -> dict[str, object]:
    return {"amount": amount, "category_legacy_id": category}


# The export reader


def test_load_export_reads_a_valid_export(tmp_path: Path) -> None:
    export = load_export(write_export(tmp_path / "export"))

    assert len(export.accounts) == 3
    assert len(export.categories) == 7
    assert len(export.payees) == 8
    assert len(export.transactions) == len(build_transactions())
    assert len(export.manifest_sha256) == 64


def test_the_manifest_hash_names_the_export(tmp_path: Path) -> None:
    first = load_export(write_export(tmp_path / "a")).manifest_sha256
    same = load_export(write_export(tmp_path / "b")).manifest_sha256
    other = load_export(write_export(tmp_path / "c", build_transactions(seed=8))).manifest_sha256

    assert first == same
    assert first != other


def test_a_changed_data_file_is_refused(tmp_path: Path) -> None:
    folder = write_export(tmp_path / "export")
    path = folder / "payees.jsonl"
    path.write_bytes(path.read_bytes().replace(b"Example", b"Exampel"))

    with pytest.raises(ExportError, match=r"payees\.jsonl: the SHA-256 does not match"):
        load_export(folder)


def _rewrite_manifest(folder: Path, change: object) -> None:
    manifest = json.loads((folder / "MANIFEST.json").read_text())
    change(manifest)  # type: ignore[operator]
    (folder / "MANIFEST.json").write_text(json.dumps(manifest))


def test_a_wrong_line_count_is_refused(tmp_path: Path) -> None:
    folder = write_export(tmp_path / "export")
    _rewrite_manifest(folder, lambda m: m["counts"].update({"accounts.jsonl": 4}))

    with pytest.raises(ExportError, match="line count"):
        load_export(folder)


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda m: m.update({"schema_version": 2}), "schema_version"),
        (lambda m: m["sha256"].pop("payees.jsonl"), "sha256 must list"),
        (lambda m: m["counts"].update({"extra.jsonl": 1}), "counts must list"),
        (lambda m: m["sha256"].update({"payees.jsonl": "abc"}), "not a SHA-256"),
        (lambda m: m["counts"].update({"payees.jsonl": True}), "not a line count"),
    ],
)
def test_a_bad_manifest_is_refused(tmp_path: Path, change: object, message: str) -> None:
    folder = write_export(tmp_path / "export")
    _rewrite_manifest(folder, change)

    with pytest.raises(ExportError, match=message):
        load_export(folder)


def test_a_missing_folder_or_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ExportError, match="does not exist"):
        load_export(tmp_path / "nowhere")

    folder = write_export(tmp_path / "export")
    (folder / "accounts.jsonl").unlink()
    with pytest.raises(ExportError, match=r"accounts\.jsonl is missing"):
        load_export(folder)

    (folder / "MANIFEST.json").unlink()
    with pytest.raises(ExportError, match=r"MANIFEST\.json is missing"):
        load_export(folder)


@pytest.mark.parametrize(
    ("content", "message"),
    [(b"{not json", "not valid JSON"), (b"[1, 2]", "not a JSON object")],
)
def test_an_unreadable_manifest_is_refused(tmp_path: Path, content: bytes, message: str) -> None:
    folder = write_export(tmp_path / "export")
    (folder / "MANIFEST.json").write_bytes(content)

    with pytest.raises(ExportError, match=message):
        load_export(folder)


def _export_with_payee_lines(tmp_path: Path, payees: bytes) -> Path:
    """An export whose payees file is replaced by `payees`, with the manifest updated to match."""
    import hashlib

    folder = write_export(tmp_path / "export")
    (folder / "payees.jsonl").write_bytes(payees)

    def change(manifest: dict) -> None:
        manifest["sha256"]["payees.jsonl"] = hashlib.sha256(payees).hexdigest()
        count = payees.count(b"\n") + (1 if payees and not payees.endswith(b"\n") else 0)
        manifest["counts"]["payees.jsonl"] = count

    _rewrite_manifest(folder, change)
    return folder


@pytest.mark.parametrize(
    ("payees", "message"),
    [
        (b'{"legacy_id": 1, "name": "A"}\nnot json\n', r"payees\.jsonl line 2: not valid JSON"),
        (b'{"legacy_id": 1, "name": "A"}\n[1]\n', "line 2: not a JSON object"),
        (b'{"legacy_id": 1}\n', "line 1: the key name is missing"),
        (b'{"legacy_id": 1, "name": "\xff"}', "not valid UTF-8"),
    ],
)
def test_a_bad_row_is_refused_without_its_content(
    tmp_path: Path, payees: bytes, message: str
) -> None:
    folder = _export_with_payee_lines(tmp_path, payees)

    with pytest.raises(ExportError, match=message):
        load_export(folder)


def test_a_last_line_without_a_newline_is_counted(tmp_path: Path) -> None:
    folder = _export_with_payee_lines(tmp_path, b'{"legacy_id": 100, "name": "A"}')

    assert len(load_export(folder).payees) == 1


# Rows and labels


def test_label_for_joins_the_export_names_and_drops_uncategorised() -> None:
    assert label_for("Eating out", "Takeaway & fast food") == "Eating out / Takeaway & fast food"
    assert label_for(" Groceries ", "Groceries") == "Groceries / Groceries"
    assert label_for("Uncategorised", "Uncategorised") is None
    assert label_for(None, "Groceries") is None
    assert label_for("Groceries", None) is None


def test_normalize_payee() -> None:
    assert normalize_payee("  Example\u00a0  MARKET ") == "example market"
    assert normalize_payee("") == ""
    assert normalize_payee(None) == ""


def test_build_rows_counts_every_rule(tmp_path: Path) -> None:
    transactions = build_transactions()
    rows, counts = build_rows(load_export(write_export(tmp_path / "export", transactions)))

    legs = sum(1 for t in transactions if t["transfer_key"] is not None)
    multi = sum(1 for t in transactions if len(t["lines"]) > 1)
    assert counts["transactions"] == len(transactions)
    assert counts["transfer_legs_excluded"] == legs
    assert counts["multi_line"] == multi
    tied = sum(
        1
        for t in transactions
        if len(t["lines"]) > 1 and len({line["amount"] for line in t["lines"]}) == 1
    )
    assert counts["multi_line_tied"] == tied > 0
    assert counts["dropped_line_without_category"] == counts["dropped_unmapped_category"]
    assert counts["dropped_uncategorised"] == counts["dropped_unmapped_category"]
    dropped = (
        counts["dropped_line_without_category"]
        + counts["dropped_unmapped_category"]
        + counts["dropped_uncategorised"]
    )
    assert counts["labelled_rows"] == len(rows) == len(transactions) - legs - dropped


def test_the_largest_line_labels_a_split_and_the_first_line_wins_a_tie(tmp_path: Path) -> None:
    transactions = [
        tx(1, [line("-30.00", 13), line("-70.00", 10)]),
        tx(2, [line("-50.00", 12), line("-50.00", 10)]),
        tx(3, [line("-120.00", 11), line("20.00", 10)], amount="-100.00"),
    ]
    rows, counts = build_rows(load_export(write_export(tmp_path / "export", transactions)))

    assert [row.label for row in rows] == [
        "Groceries / Groceries",
        "Car / Fuel",
        "Eating out / Cafes, bars & restaurants",
    ]
    assert counts["multi_line"] == 3
    assert counts["multi_line_tied"] == 1


def test_a_split_whose_largest_line_is_uncategorised_is_dropped(tmp_path: Path) -> None:
    transactions = [tx(1, [line("-30.00", 10), line("-70.00", None)])]
    rows, counts = build_rows(load_export(write_export(tmp_path / "export", transactions)))

    assert rows == []
    assert counts["dropped_line_without_category"] == 1


def test_row_fields_come_from_the_transaction_and_its_account(tmp_path: Path) -> None:
    transactions = [
        tx(
            1,
            [{"amount": "-100.00", "category_legacy_id": 10, "comment": "line note"}],
            payee_legacy_id=100,
            comment="  a   note ",
            mcc="5411",
            bank_description="SHOP 1",
            merchant="Shop",
        ),
        tx(2, [{"amount": "10.00", "category_legacy_id": 14}], amount="10.00", account_legacy_id=3),
    ]
    rows, _ = build_rows(load_export(write_export(tmp_path / "export", transactions)))

    first, second = rows
    assert first.payee == "example market"
    assert first.comment == "a note"
    assert (first.mcc, first.bank_description, first.merchant) == ("5411", "SHOP 1", "Shop")
    assert first.amount == Decimal("-100.00")
    assert (first.currency, first.account_kind) == ("UAH", "debit")
    assert first.has_bank_fields
    assert second.payee == ""
    assert second.currency == "USD"
    assert not second.has_bank_fields


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"lines": []}, "without lines"),
        ({"lines": [{"category_legacy_id": 10}]}, "a line without an amount"),
        ({"lines": [{"amount": "-1.00", "category_legacy_id": 99}]}, "unknown category"),
        ({"account_legacy_id": 99}, "unknown account"),
        ({"payee_legacy_id": 99}, "unknown payee"),
        ({"occurred_on": "2025-13-01"}, "not a date"),
        ({"lines": [{"amount": -1, "category_legacy_id": 10}]}, "not a decimal string"),
        ({"lines": [{"amount": "1,5", "category_legacy_id": 10}]}, "not a decimal string"),
        ({"lines": [{"amount": "NaN", "category_legacy_id": 10}]}, "not a decimal string"),
    ],
)
def test_a_row_the_rules_cannot_use_is_refused(
    tmp_path: Path, change: dict[str, object], message: str
) -> None:
    base = tx(1, [{"amount": "-100.00", "category_legacy_id": 10}])
    base.update(change)
    export = load_export(write_export(tmp_path / "export", [base]))

    with pytest.raises(ExportError, match=rf"line 1: .*{message}"):
        build_rows(export)


# The date split


def test_the_split_keeps_whole_days_on_one_side() -> None:
    rows = [make_row(date(2025, 1, day), f"{day}-{i}") for day in range(1, 11) for i in range(day)]
    split = split_by_date(rows, 0.2)

    assert max(r.occurred_on for r in split.head) < min(r.occurred_on for r in split.tail)
    assert split.cut == min(r.occurred_on for r in split.tail)
    assert len(split.tail) >= 0.2 * len(rows)
    assert len(split.head) + len(split.tail) == len(rows)
    # The day of the cut is not shared: removing it would leave less than the fraction.
    cut_day = sum(1 for r in split.tail if r.occurred_on == split.cut)
    assert len(split.tail) - cut_day < 0.2 * len(rows)


def test_the_split_orders_rows_by_date_whatever_their_order() -> None:
    rows = [make_row(date(2025, 1, d), str(d)) for d in (5, 1, 4, 2, 3)]
    split = split_by_date(rows, 0.4)

    assert [r.legacy_id for r in split.head] == ["1", "2", "3"]
    assert [r.legacy_id for r in split.tail] == ["4", "5"]


def test_a_large_first_day_never_takes_the_whole_set() -> None:
    rows = [make_row(date(2025, 1, 1), str(i)) for i in range(9)] + [make_row(date(2025, 1, 2))]
    split = split_by_date(rows, 0.5)

    assert len(split.head) == 9
    assert split.cut == date(2025, 1, 2)


def test_the_split_needs_two_days_and_a_sensible_fraction() -> None:
    with pytest.raises(SplitError, match="two days"):
        split_by_date([make_row(date(2025, 1, 1))] * 3, 0.2)
    with pytest.raises(SplitError, match="between 0 and 1"):
        split_by_date([make_row(date(2025, 1, 1))], 1.0)
