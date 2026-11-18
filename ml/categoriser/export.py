"""Read a history export (`docs/import-contract.md`) after checking its manifest.

Each data file is read once: its SHA-256 and line count are checked against `MANIFEST.json`, and the
rows are parsed from the same bytes that were hashed. The SHA-256 of `MANIFEST.json` itself names
the export in every output, since the manifest holds the hash of every data file.

Errors name the file, the line number and the key, never a value: the export holds personal data.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DATA_FILES = ("accounts.jsonl", "categories.jsonl", "payees.jsonl", "transactions.jsonl")

REQUIRED_KEYS = {
    "accounts.jsonl": ("legacy_id", "kind", "currency"),
    "categories.jsonl": ("legacy_id", "group_en", "category_en"),
    "payees.jsonl": ("legacy_id", "name"),
    "transactions.jsonl": (
        "legacy_id",
        "account_legacy_id",
        "occurred_on",
        "amount",
        "payee_legacy_id",
        "comment",
        "mcc",
        "bank_description",
        "merchant",
        "transfer_key",
        "lines",
    ),
}


class ExportError(Exception):
    """The export is missing, does not match its manifest, or has a row this reader cannot use."""


@dataclass(frozen=True)
class Export:
    """The parsed rows of an export, keyed by file name, and what identifies the export."""

    manifest_sha256: str
    date_from: str | None
    date_to: str | None
    rows: dict[str, list[dict[str, Any]]]

    @property
    def accounts(self) -> list[dict[str, Any]]:
        return self.rows["accounts.jsonl"]

    @property
    def categories(self) -> list[dict[str, Any]]:
        return self.rows["categories.jsonl"]

    @property
    def payees(self) -> list[dict[str, Any]]:
        return self.rows["payees.jsonl"]

    @property
    def transactions(self) -> list[dict[str, Any]]:
        return self.rows["transactions.jsonl"]


def load_export(folder: Path) -> Export:
    """Verify the manifest of the export in `folder` and parse its four data files."""
    if not folder.is_dir():
        raise ExportError("the export folder does not exist")
    manifest_path = folder / "MANIFEST.json"
    if not manifest_path.is_file():
        raise ExportError("MANIFEST.json is missing")
    manifest_bytes = manifest_path.read_bytes()
    manifest = _parse_manifest(manifest_bytes)

    rows: dict[str, list[dict[str, Any]]] = {}
    for name in DATA_FILES:
        path = folder / name
        if not path.is_file():
            raise ExportError(f"{name} is missing")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != manifest["sha256"][name].lower():
            raise ExportError(f"{name}: the SHA-256 does not match MANIFEST.json")
        if _line_count(data) != manifest["counts"][name]:
            raise ExportError(f"{name}: the line count does not match MANIFEST.json")
        rows[name] = _parse_jsonl(name, data)

    return Export(
        manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        date_from=manifest.get("date_from"),
        date_to=manifest.get("date_to"),
        rows=rows,
    )


def _parse_manifest(data: bytes) -> dict[str, Any]:
    try:
        manifest = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ExportError("MANIFEST.json is not valid JSON") from None
    if not isinstance(manifest, dict):
        raise ExportError("MANIFEST.json is not a JSON object")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise ExportError(f"MANIFEST.json: schema_version must be {SCHEMA_VERSION}")
    for key in ("counts", "sha256"):
        value = manifest.get(key)
        if not isinstance(value, dict) or sorted(value) != sorted(DATA_FILES):
            raise ExportError(f"MANIFEST.json: {key} must list exactly the four data files")
    for name in DATA_FILES:
        digest = manifest["sha256"][name]
        if not isinstance(digest, str) or len(digest) != 64:
            raise ExportError(f"MANIFEST.json: sha256 of {name} is not a SHA-256")
        count = manifest["counts"][name]
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ExportError(f"MANIFEST.json: counts of {name} is not a line count")
    return manifest


def _line_count(data: bytes) -> int:
    """The contract's line count: newlines, plus one for a last line without a newline."""
    count = data.count(b"\n")
    if data and not data.endswith(b"\n"):
        count += 1
    return count


def _parse_jsonl(name: str, data: bytes) -> list[dict[str, Any]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ExportError(f"{name} is not valid UTF-8") from None
    required = REQUIRED_KEYS[name]
    rows = []
    for number, line in enumerate(text.splitlines(), start=1):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            raise ExportError(f"{name} line {number}: not valid JSON") from None
        if not isinstance(row, dict):
            raise ExportError(f"{name} line {number}: not a JSON object")
        for key in required:
            if key not in row:
                raise ExportError(f"{name} line {number}: the key {key} is missing")
        rows.append(row)
    return rows
