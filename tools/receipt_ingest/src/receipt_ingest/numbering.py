"""Stable receipt numbers across runs.

A receipt's key is the SHA-256 of its earliest photo. A key keeps its id for ever, also after it was
retired and came back, and an id is never given to another key.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

from receipt_ingest.scan import RawFile

STATE_FORMAT = 1
STAGES = ("convert", "thumbs", "qr", "crop")

_ID = re.compile(r"rcpt_([0-9]{6,})")
_SHA = re.compile(r"[0-9a-f]{64}")


class StateError(Exception):
    """state.json exists but cannot be used."""


def format_id(number: int) -> str:
    return f"rcpt_{number:06d}"


def id_number(receipt_id: str) -> int:
    """The number in `rcpt_000123`. Sorting by it keeps rcpt_1000000 after rcpt_999999."""
    match = _ID.fullmatch(receipt_id)
    assert match is not None
    return int(match.group(1))


def empty_state() -> dict:
    return {"format": STATE_FORMAT, "next_id": 1, "receipts": [], "retired": []}


def load_state(text: str | None) -> dict:
    if text is None:
        return empty_state()
    try:
        state = json.loads(text)
    except json.JSONDecodeError:
        raise StateError("state.json is not valid JSON") from None
    if not _valid_state(state):
        # The message says nothing about which entry is wrong: an entry holds hashes and names.
        raise StateError("state.json has an unknown shape")
    return state


# --- validation ---


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_str_list(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _valid_id(value: object) -> bool:
    # Only the canonical spelling: "rcpt_0000001" and "rcpt_000001" must not both exist.
    return (
        isinstance(value, str)
        and _ID.fullmatch(value) is not None
        and (format_id(id_number(value)) == value)
    )


def _valid_file(entry: object, versions: bool, name: str) -> bool:
    # The file name must be the one the tool gives this receipt and part, so that a hand-edited
    # state can neither point the tool at another file nor give one file to two receipts.
    if not isinstance(entry, dict):
        return False
    if not (
        entry.get("file") == name
        and isinstance(entry.get("sha256"), str)
        and _SHA.fullmatch(entry["sha256"])
        and all(_is_int(entry.get(key)) and entry[key] >= 0 for key in ("width", "height", "bytes"))
    ):
        return False
    if not versions:
        return True
    written_by = entry.get("written_by")
    return isinstance(written_by, dict) and all(
        isinstance(value, str) for value in written_by.values()
    )


def _valid_crop(crop: object, receipt_id: str, part_count: int) -> bool:
    if crop is None:
        return True
    if not isinstance(crop, dict) or not isinstance(crop.get("parts"), list):
        return False
    numbers = []
    for part in crop["parts"]:
        if not isinstance(part, dict) or not _is_int(part.get("part")):
            return False
        if not 1 <= part["part"] <= part_count:
            return False
        numbers.append(part["part"])
        name = f"images/{receipt_id}_{part['part']}_crop.jpg"
        if "file" in part and not (
            _valid_file(part, True, name) and isinstance(part.get("quad"), list)
        ):
            return False
        if "file" not in part and not isinstance(part.get("failed"), str):
            return False
    return len(set(numbers)) == len(numbers)


def _valid_record(record: object) -> bool:
    if not isinstance(record, dict):
        return False
    parts = record.get("parts")
    if not (
        _valid_id(record.get("receipt_id"))
        and isinstance(record.get("key"), str)
        and _SHA.fullmatch(record["key"])
        and _is_str_list(parts)
        and parts
        and parts[0] == record["key"]
        and all(_SHA.fullmatch(sha) for sha in parts)
        and len(set(parts)) == len(parts)
        and _is_str_list(record.get("raw_files"))
        and len(record["raw_files"]) == len(parts)
        and isinstance(record.get("batch"), str)
        and _is_int(record.get("seq_in_batch"))
        and record["seq_in_batch"] >= 1
        and (record.get("captured_at") is None or isinstance(record["captured_at"], str))
        and _is_str_list(record.get("group_flags", []))
        and _is_str_list(record.get("failed_stages", []))
        and set(record.get("failed_stages", [])) <= set(STAGES)
        and isinstance(record.get("raw_missing", False), bool)
    ):
        return False
    images, thumbs = record.get("images"), record.get("thumbs")
    if not isinstance(images, list) or not isinstance(thumbs, list):
        return False
    # Images are all there or none are: a receipt never carries a part of its photos.
    if len(images) not in (0, len(parts)) or len(thumbs) > len(parts):
        return False
    receipt_id = record["receipt_id"]
    for number, entry in enumerate(images, start=1):
        if not _valid_file(entry, True, f"images/{receipt_id}_{number}.jpg"):
            return False
    for number, entry in enumerate(thumbs, start=1):
        if not _valid_file(entry, True, f"thumbs/{receipt_id}_{number}.jpg"):
            return False
    qr = record.get("qr")
    if qr is not None and not (
        isinstance(qr, dict)
        and _is_str_list(qr.get("flags", []))
        and (qr.get("payload") is None or isinstance(qr["payload"], str))
    ):
        return False
    return _valid_crop(record.get("crop"), receipt_id, len(parts))


def _valid_retired(entry: object) -> bool:
    return (
        isinstance(entry, dict)
        and _valid_id(entry.get("receipt_id"))
        and isinstance(entry.get("key"), str)
        and _SHA.fullmatch(entry["key"]) is not None
        and isinstance(entry.get("reason"), str)
    )


def _valid_state(state: object) -> bool:
    if (
        not isinstance(state, dict)
        or state.get("format") != STATE_FORMAT
        or not _is_int(state.get("next_id"))
        or not isinstance(state.get("receipts"), list)
        or not isinstance(state.get("retired"), list)
    ):
        return False
    if not all(_valid_record(record) for record in state["receipts"]):
        return False
    if not all(_valid_retired(entry) for entry in state["retired"]):
        return False
    entries = state["receipts"] + state["retired"]
    numbers = [id_number(entry["receipt_id"]) for entry in entries]
    keys = [entry["key"] for entry in entries]
    parts = [sha for record in state["receipts"] for sha in record["parts"]]
    # A number given twice, or a next_id that would hand out a number in use again, would make two
    # receipts write to the same image files. A photo in two receipts would be processed twice.
    return (
        len(set(numbers)) == len(numbers)
        and len(set(keys)) == len(keys)
        and len(set(parts)) == len(parts)
        and state["next_id"] > max(numbers, default=0)
    )


def dump_state(state: dict) -> bytes:
    return (json.dumps(state, ensure_ascii=False, indent=1, sort_keys=False) + "\n").encode("utf-8")


# --- planning ---


@dataclass
class Planned:
    receipt_id: str
    group: list[RawFile]
    previous: dict | None  # the state record for this key, if any
    status: str  # "new", "restored", "unchanged" or "changed"


@dataclass
class Plan:
    planned: list[Planned] = field(default_factory=list)
    raw_missing: list[dict] = field(default_factory=list)  # frozen records, kept as they are
    retired: list[dict] = field(default_factory=list)  # newly retired: receipt_id, key, reason
    next_id: int = 1


def recorded_names(state: dict) -> dict[str, str]:
    """SHA-256 -> raw name as recorded by the last run, to keep the same file canonical."""
    names: dict[str, str] = {}
    for record in state["receipts"]:
        for sha, name in zip(record["parts"], record["raw_files"], strict=True):
            names.setdefault(sha, name)
    return names


def frozen_records(state: dict, scanned: set[str]) -> list[dict]:
    """Recorded receipts that have images and lost at least one raw photo.

    Such a receipt is kept exactly as recorded until all its photos are back: regrouping what is
    left would rewrite or retire its images only because a file was moved away. A receipt with no
    images has nothing to keep and follows the normal rules.
    """
    return [
        record
        for record in state["receipts"]
        if record["images"] and any(sha not in scanned for sha in record["parts"])
    ]


def plan(
    groups: list[list[RawFile]],
    state: dict,
    scanned: set[str],
    excluded: set[str],
    merged: set[str] | None = None,
    frozen: list[dict] | None = None,
) -> Plan:
    """Match this run's groups to the receipts recorded in `state`.

    `scanned` holds the SHA-256 of every image found in this run (duplicates and excluded files
    included); `excluded` the SHA-256 of the excluded ones; `merged` the keys of groups that a
    merge override joined into an earlier group; `frozen` the records from `frozen_records`, whose
    photos must not be in `groups`.
    """
    merged = merged or set()
    frozen = frozen or []
    frozen_keys = {record["key"] for record in frozen}
    active = {
        record["key"]: record for record in state["receipts"] if record["key"] not in frozen_keys
    }
    retired = {entry["key"]: entry for entry in state["retired"]}
    result = Plan(next_id=state["next_id"], raw_missing=list(frozen))
    new_groups = []
    for group in groups:
        key = group[0].sha256
        record = active.get(key)
        if record is not None:
            parts = [item.sha256 for item in group]
            status = "unchanged" if record["parts"] == parts else "changed"
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
    for key, record in active.items():
        if key in matched:
            continue
        if any(sha not in scanned for sha in record["parts"]):
            # Not frozen, so it has no images: a receipt that failed and whose photo is gone.
            reason = "failed"
        elif key in excluded:
            reason = "excluded"
        elif key in merged:
            reason = "merged"
        else:
            # For example a longer --gap joined it to the receipt before it.
            reason = "regrouped"
        result.retired.append({"receipt_id": record["receipt_id"], "key": key, "reason": reason})
    result.planned.sort(key=lambda planned: id_number(planned.receipt_id))
    return result
