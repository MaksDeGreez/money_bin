"""A small synthetic history export for the categoriser tests. All names and amounts are invented.

The export follows `docs/import-contract.md`. Like real history, it changes character over time: the
early rows are hand-entered (a payee and sometimes a comment, no bank fields) and the later rows
come from a bank feed (MCC, bank description, merchant).
"""

from __future__ import annotations

import hashlib
import json
import random
from datetime import date, timedelta
from pathlib import Path
from typing import Any

ACCOUNTS = [
    {"legacy_id": 1, "name": "Wallet", "kind": "cash", "currency": "UAH", "archived": False},
    {"legacy_id": 2, "name": "Card", "kind": "debit", "currency": "UAH", "archived": False},
    {"legacy_id": 3, "name": "Dollar card", "kind": "debit", "currency": "USD", "archived": False},
]

CATEGORIES = [
    {"legacy_id": 10, "legacy_path": "Food", "group_en": "Groceries", "category_en": "Groceries"},
    {
        "legacy_id": 11,
        "legacy_path": "Cafe",
        "group_en": "Eating out",
        "category_en": "Cafes, bars & restaurants",
    },
    {"legacy_id": 12, "legacy_path": "Fuel", "group_en": "Car", "category_en": "Fuel"},
    {
        "legacy_id": 13,
        "legacy_path": "Pharmacy",
        "group_en": "Health",
        "category_en": "Health & pharmacy",
    },
    {
        "legacy_id": 14,
        "legacy_path": "Phone",
        "group_en": "Digital & communications",
        "category_en": "Mobile & internet",
    },
    {"legacy_id": 15, "legacy_path": "Misc", "group_en": None, "category_en": None},
    {
        "legacy_id": 16,
        "legacy_path": "Unknown",
        "group_en": "Uncategorised",
        "category_en": "Uncategorised",
    },
]

# payee legacy id -> (name, category legacy id, MCC, bank text stem)
PAYEES = {
    100: ("Example Market", 10, "5411", "EXAMPLE MARKET STORE"),
    101: ("Sample Grocer", 10, "5411", "SAMPLE GROCER"),
    102: ("Corner Cafe Demo", 11, "5814", "CORNER CAFE DEMO"),
    103: ("Test Bistro", 11, "5812", "TEST BISTRO KITCHEN"),
    104: ("Fuel Station Alpha", 12, "5541", "ALPHA FUEL"),
    105: ("Pharmacy Placeholder", 13, "5912", "PLACEHOLDER PHARM"),
    106: ("Mobile Operator Fake", 14, "4814", "FAKE MOBILE TOPUP"),
}
# Payees that only appear in the last months, so they are never in the training rows.
LATE_PAYEES = {
    107: ("Latecomer Grocery Zeta", 10, "5411", "ZETA LATE GROCERY"),
}

START = date(2024, 1, 1)
DAYS = 540
BANK_FROM = date(2024, 10, 1)


def _decimal(value: float) -> str:
    return f"{value:.2f}"


def build_transactions(seed: int = 7) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    rows: list[dict[str, Any]] = []
    next_id = 1000

    def add(**fields: Any) -> None:
        nonlocal next_id
        row = {
            "legacy_id": next_id,
            "account_legacy_id": 2,
            "occurred_at": None,
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
            "lines": [],
        }
        row.update(fields)
        rows.append(row)
        next_id += 1

    for offset in range(DAYS):
        day = START + timedelta(days=offset)
        late = offset > DAYS - 90
        payees = {**PAYEES, **LATE_PAYEES} if late else PAYEES
        for _ in range(rng.randint(1, 2)):
            payee_id = rng.choice(list(payees))
            name, category, mcc, bank = payees[payee_id]
            if rng.random() < 0.1:  # some noise in the labels
                category = rng.choice([10, 11, 12, 13, 14])
            amount = -round(rng.uniform(20, 2500), 2)
            bank_feed = day >= BANK_FROM
            add(
                occurred_on=day.isoformat(),
                amount=_decimal(amount),
                payee_legacy_id=payee_id,
                comment=None if bank_feed or rng.random() < 0.5 else "invented note",
                mcc=mcc if bank_feed else None,
                bank_description=f"{bank} {rng.randint(1, 99)}" if bank_feed else None,
                merchant=name if bank_feed else None,
                account_legacy_id=2 if bank_feed else 1,
                lines=[{"amount": _decimal(amount), "category_legacy_id": category}],
            )
        if offset % 9 == 0:  # a transfer pair
            key = f"T-{offset}"
            add(occurred_on=day.isoformat(), amount="-500.00", transfer_key=key)
            add(occurred_on=day.isoformat(), amount="500.00", account_legacy_id=1, transfer_key=key)
        if offset % 11 == 0:  # a split: groceries are the larger line
            add(
                occurred_on=day.isoformat(),
                amount="-300.00",
                payee_legacy_id=100,
                lines=[
                    {"amount": "-100.00", "category_legacy_id": 13},
                    {"amount": "-200.00", "category_legacy_id": 10, "comment": "invented"},
                ],
            )
        if offset % 13 == 0:  # a tie: the first line wins
            add(
                occurred_on=day.isoformat(),
                amount="-200.00",
                payee_legacy_id=104,
                lines=[
                    {"amount": "-100.00", "category_legacy_id": 12},
                    {"amount": "-100.00", "category_legacy_id": 10},
                ],
            )
        if offset % 17 == 0:  # rows without a usable label
            add(
                occurred_on=day.isoformat(),
                amount="-42.00",
                lines=[{"amount": "-42.00", "category_legacy_id": None}],
            )
            add(
                occurred_on=day.isoformat(),
                amount="-43.00",
                lines=[{"amount": "-43.00", "category_legacy_id": 15}],
            )
            add(
                occurred_on=day.isoformat(),
                amount="-44.00",
                lines=[{"amount": "-44.00", "category_legacy_id": 16}],
            )
        if offset % 30 == 0:  # an income in another currency
            add(
                occurred_on=day.isoformat(),
                amount="1000.00",
                account_legacy_id=3,
                currency="USD",
                payee_legacy_id=106,
                lines=[{"amount": "1000.00", "category_legacy_id": 14}],
            )
    return rows


def payee_rows() -> list[dict[str, Any]]:
    return [
        {"legacy_id": legacy_id, "name": name}
        for legacy_id, (name, *_rest) in {**PAYEES, **LATE_PAYEES}.items()
    ]


def write_export(folder: Path, transactions: list[dict[str, Any]] | None = None) -> Path:
    """Write the synthetic export into `folder` with a correct manifest; return the folder."""
    folder.mkdir(parents=True, exist_ok=True)
    files = {
        "accounts.jsonl": ACCOUNTS,
        "categories.jsonl": CATEGORIES,
        "payees.jsonl": payee_rows(),
        "transactions.jsonl": build_transactions() if transactions is None else transactions,
    }
    counts, hashes = {}, {}
    for name, rows in files.items():
        data = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows).encode("utf-8")
        (folder / name).write_bytes(data)
        counts[name] = len(rows)
        hashes[name] = hashlib.sha256(data).hexdigest()
    manifest = {
        "schema_version": 1,
        "exported_at": "2026-01-01T00:00:00Z",
        "legacy_git_sha": None,
        "date_from": None,
        "date_to": None,
        "counts": counts,
        "sha256": hashes,
        "warnings": [],
    }
    (folder / "MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
    return folder


def private_strings() -> list[str]:
    """Every invented text that stands in for personal data and must never reach an output."""
    texts = ["invented note", "invented"]
    for name, _category, _mcc, bank in {**PAYEES, **LATE_PAYEES}.values():
        texts += [name, name.lower(), bank]
    return texts
