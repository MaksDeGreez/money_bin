"""Stable receipt numbers across runs.

A receipt's key is the SHA-256 of its earliest photo. A key keeps its id for ever, also after it was
retired and came back, and an id is never given to another key.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from receipt_ingest.scan import RawFile

STATE_FORMAT = 1


class StateError(Exception):
    """state.json exists but cannot be used."""


def format_id(number: int) -> str:
    return f"rcpt_{number:06d}"


def empty_state() -> dict:
    return {"format": STATE_FORMAT, "next_id": 1, "receipts": [], "retired": []}


def load_state(text: str | None) -> dict:
    if text is None:
        return empty_state()
    try:
        state = json.loads(text)
    except json.JSONDecodeError:
        raise StateError("state.json is not valid JSON") from None
    if (
        not isinstance(state, dict)
        or state.get("format") != STATE_FORMAT
        or not isinstance(state.get("next_id"), int)
        or not isinstance(state.get("receipts"), list)
        or not isinstance(state.get("retired"), list)
    ):
        raise StateError("state.json has an unknown shape")
    return state


def dump_state(state: dict) -> bytes:
    return (json.dumps(state, ensure_ascii=False, indent=1, sort_keys=False) + "\n").encode("utf-8")


@dataclass
class Planned:
    receipt_id: str
    group: list[RawFile]
    previous: dict | None  # the state record for this key, if any
    status: str  # "new", "restored", "unchanged" or "changed"


@dataclass
class Plan:
    planned: list[Planned] = field(default_factory=list)
    raw_missing: list[dict] = field(default_factory=list)
    retired: list[dict] = field(default_factory=list)  # newly retired: receipt_id, key, reason
    next_id: int = 1


def recorded_names(state: dict) -> dict[str, str]:
    """SHA-256 -> raw name as recorded by the last run, to keep the same file canonical."""
    names: dict[str, str] = {}
    for record in state["receipts"]:
        pairs = zip(record.get("parts") or [], record.get("raw_files") or [], strict=False)
        for sha, name in pairs:
            names.setdefault(sha, name)
    return names


def plan(groups: list[list[RawFile]], state: dict, scanned: set[str], excluded: set[str]) -> Plan:
    """Match this run's groups to the receipts recorded in `state`.

    `scanned` holds the SHA-256 of every image found in this run (duplicates and excluded files
    included); `excluded` the SHA-256 of the excluded ones.
    """
    active = {record["key"]: record for record in state["receipts"]}
    retired = {entry["key"]: entry for entry in state["retired"]}
    result = Plan(next_id=state["next_id"])
    new_groups = []
    for group in groups:
        key = group[0].sha256
        record = active.get(key)
        if record is not None:
            parts = [item.sha256 for item in group]
            # A receipt that failed last time is tried again from its raw photos.
            same = record.get("parts") == parts and not record.get("failed")
            status = "unchanged" if same else "changed"
            result.planned.append(Planned(record["receipt_id"], group, record, status))
        elif key in retired:
            result.planned.append(Planned(retired[key]["receipt_id"], group, None, "restored"))
        else:
            new_groups.append(group)
    # Groups arrive in scan order: batch name, then capture time, then name.
    for group in new_groups:
        result.planned.append(Planned(format_id(result.next_id), group, None, "new"))
        result.next_id += 1

    matched = {planned.group[0].sha256 for planned in result.planned}
    owner = {item.sha256: group[0].sha256 for group in groups for item in group}
    for key, record in active.items():
        if key in matched:
            continue
        raw_gone = not any(sha in scanned for sha in record.get("parts") or [key])
        if raw_gone and not record.get("failed"):
            # Raw photos can be moved away or lost; output is never deleted for that reason.
            result.raw_missing.append(record)
            continue
        if raw_gone:
            # A receipt that never got images has nothing to keep.
            reason = "failed"
        elif key in excluded:
            reason = "excluded"
        elif key in owner and owner[key] != key:
            reason = "merged"
        else:
            reason = "regrouped"
        result.retired.append({"receipt_id": record["receipt_id"], "key": key, "reason": reason})
    result.planned.sort(key=lambda planned: planned.receipt_id)
    return result
