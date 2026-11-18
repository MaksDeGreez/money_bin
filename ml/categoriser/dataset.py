"""Turn the transactions of an export into labelled rows, one per transaction.

The rules:

- A transfer leg (a row with a `transfer_key`) is not a row: moving money between own accounts has
  no category.
- A transaction with several lines (a split) is represented by its largest line by absolute amount;
  on a tie, the first of the tied lines in the export's order. The other lines are not used.
- The label is the chosen line's category as the export names it: the English group and category
  names, joined as "Group / Category". A line without a category, or one whose category the export
  does not map, maps to names outside the app's taxonomy, or maps to Uncategorised, gives no label,
  and the row is dropped. Each drop is counted. The split and tie counts cover every transaction
  that is not a transfer leg, before these drops.
- The features come from the transaction only (payee, comment, bank fields, amount, account kind),
  never from its lines, so that a new transaction without lines can be scored the same way.
"""

from __future__ import annotations

import unicodedata
from collections import Counter
from collections.abc import Collection
from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any

from categoriser.export import Export, ExportError

UNCATEGORISED = ("Uncategorised", "Uncategorised")
COUNT_KEYS = (
    "transactions",
    "transfer_legs_excluded",
    "multi_line",
    "multi_line_tied",
    "dropped_line_without_category",
    "dropped_unmapped_category",
    "dropped_not_in_taxonomy",
    "dropped_uncategorised",
    "labelled_rows",
)
LABEL_SEPARATOR = " / "


@dataclass(frozen=True)
class Row:
    """One labelled transaction. Holds personal data: never print or write its text fields."""

    occurred_on: date
    legacy_id: str
    label: str
    payee: str
    comment: str
    bank_description: str
    merchant: str
    mcc: str
    amount: Decimal
    currency: str
    account_kind: str

    @property
    def has_bank_fields(self) -> bool:
        """True when the row has a field only a bank feed gives (MCC, bank text or merchant)."""
        return bool(self.mcc or self.bank_description or self.merchant)


def label_for(group_en: str | None, category_en: str | None) -> str | None:
    """The label of an export category, or None when it is unmapped or Uncategorised."""
    if group_en is None or category_en is None:
        return None
    if (group_en.strip(), category_en.strip()) == UNCATEGORISED:
        return None
    return f"{_squish(group_en)}{LABEL_SEPARATOR}{_squish(category_en)}"


def normalize_payee(name: str | None) -> str:
    """The payee matching key, as the app builds it: NFKC, squished whitespace, lower case."""
    if not name:
        return ""
    return _squish(unicodedata.normalize("NFKC", name)).lower()


def build_rows(
    export: Export, taxonomy: Collection[tuple[str, str]]
) -> tuple[list[Row], dict[str, int]]:
    """Build the labelled rows and the counts of what was kept and dropped.

    `taxonomy` holds the (group, category) name pairs the app has; a category outside it is dropped,
    as the importer sends it to Uncategorised.
    """
    accounts = {str(a["legacy_id"]): a for a in export.accounts}
    categories = {str(c["legacy_id"]): c for c in export.categories}
    payees = {str(p["legacy_id"]): normalize_payee(p["name"]) for p in export.payees}

    counts: Counter[str] = Counter({key: 0 for key in COUNT_KEYS})
    rows: list[Row] = []
    for number, tx in enumerate(export.transactions, start=1):
        counts["transactions"] += 1
        if tx["transfer_key"] is not None:
            counts["transfer_legs_excluded"] += 1
            continue
        lines = tx["lines"]
        if not isinstance(lines, list) or not lines:
            raise ExportError(f"transactions.jsonl line {number}: an ordinary row without lines")
        if len(lines) > 1:
            counts["multi_line"] += 1
        line, tied = _largest_line(lines, number)
        if tied:
            counts["multi_line_tied"] += 1

        category_id = line.get("category_legacy_id")
        if category_id is None:
            counts["dropped_line_without_category"] += 1
            continue
        category = categories.get(str(category_id))
        if category is None:
            raise ExportError(f"transactions.jsonl line {number}: unknown category_legacy_id")
        if category["group_en"] is None or category["category_en"] is None:
            counts["dropped_unmapped_category"] += 1
            continue
        pair = (_squish(category["group_en"]), _squish(category["category_en"]))
        if pair not in taxonomy:
            counts["dropped_not_in_taxonomy"] += 1
            continue
        label = label_for(category["group_en"], category["category_en"])
        if label is None:
            counts["dropped_uncategorised"] += 1
            continue

        account = accounts.get(str(tx["account_legacy_id"]))
        if account is None:
            raise ExportError(f"transactions.jsonl line {number}: unknown account_legacy_id")
        payee_id = tx["payee_legacy_id"]
        payee = "" if payee_id is None else payees.get(str(payee_id))
        if payee is None:
            raise ExportError(f"transactions.jsonl line {number}: unknown payee_legacy_id")

        rows.append(
            Row(
                occurred_on=_parse_date(tx["occurred_on"], number),
                legacy_id=str(tx["legacy_id"]),
                label=label,
                payee=payee,
                comment=_text(tx["comment"]),
                bank_description=_text(tx["bank_description"]),
                merchant=_text(tx["merchant"]),
                mcc=_text(tx["mcc"]),
                amount=_parse_amount(tx["amount"], number),
                currency=_text(account.get("currency")),
                account_kind=_text(account.get("kind")),
            )
        )
    counts["labelled_rows"] = len(rows)
    return rows, dict(counts)


def _largest_line(lines: list[Any], number: int) -> tuple[dict[str, Any], bool]:
    """The line with the largest absolute amount (the first one on a tie), and whether it tied."""
    best: dict[str, Any] | None = None
    best_size = Decimal(-1)
    tied = False
    for line in lines:
        if not isinstance(line, dict) or "amount" not in line:
            raise ExportError(f"transactions.jsonl line {number}: a line without an amount")
        size = abs(_parse_amount(line["amount"], number))
        if size > best_size:
            best, best_size, tied = line, size, False
        elif size == best_size:
            tied = True
    assert best is not None
    return best, tied


def _parse_amount(value: Any, number: int) -> Decimal:
    if not isinstance(value, str):
        raise ExportError(f"transactions.jsonl line {number}: an amount is not a decimal string")
    try:
        amount = Decimal(value)
    except InvalidOperation:
        raise ExportError(
            f"transactions.jsonl line {number}: an amount is not a decimal string"
        ) from None
    if not amount.is_finite():
        raise ExportError(f"transactions.jsonl line {number}: an amount is not a decimal string")
    return amount


def _parse_date(value: Any, number: int) -> date:
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError):
        raise ExportError(f"transactions.jsonl line {number}: occurred_on is not a date") from None


def _text(value: Any) -> str:
    return _squish(value) if isinstance(value, str) else ""


def _squish(value: str) -> str:
    return " ".join(value.split())
