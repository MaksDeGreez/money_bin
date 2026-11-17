"""Grouping photos into receipts by the time between shots, and the owner's corrections to that."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from receipt_ingest.scan import RawFile

OVERRIDE_FILE = "groups_override.yaml"
OVERRIDE_KEYS = ("merge", "split", "exclude")
MAX_PARTS = 3


class OverrideError(Exception):
    """The override file is not valid. The message names the key and the entry only."""


@dataclass
class Overrides:
    merge: list[list[str]] = field(default_factory=list)
    split: list[str] = field(default_factory=list)
    exclude: list[str] = field(default_factory=list)


def group_by_gap(files: list[RawFile], gap: float) -> list[list[RawFile]]:
    """Split batches into receipts where the pause before a photo is longer than `gap` seconds.

    `files` must be in scan order. A photo without a capture time is a receipt of its own.
    """
    groups: list[list[RawFile]] = []
    previous: RawFile | None = None
    for item in files:
        starts_new = (
            previous is None
            or previous.batch != item.batch
            or item.captured_at is None
            or previous.captured_at is None
            or (item.captured_at - previous.captured_at).total_seconds() > gap
        )
        if starts_new:
            groups.append([item])
        else:
            groups[-1].append(item)
        previous = item
    return groups


def _string_list(value: object, key: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise OverrideError(f"{key}: must be a list of file names")
    for index, entry in enumerate(value):
        if not isinstance(entry, str):
            raise OverrideError(f"{key}[{index}]: must be a file name")
    return list(value)


def parse_overrides(text: str) -> Overrides:
    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        where = f" near line {mark.line + 1}" if mark is not None else ""
        raise OverrideError(f"not valid YAML ({type(error).__name__}){where}") from None
    if loaded is None:
        return Overrides()
    if not isinstance(loaded, dict):
        raise OverrideError("the top level must be a mapping with merge, split and exclude")
    for key in loaded:
        if key not in OVERRIDE_KEYS:
            raise OverrideError(f"unknown key {str(key)!r} (allowed: merge, split, exclude)")
    merge_value = loaded.get("merge")
    merge: list[list[str]] = []
    if merge_value is not None:
        if not isinstance(merge_value, list):
            raise OverrideError("merge: must be a list of lists of file names")
        for index, entry in enumerate(merge_value):
            if not isinstance(entry, list) or len(entry) < 2:
                raise OverrideError(f"merge[{index}]: must be a list of two or more file names")
            merge.append(_string_list(entry, f"merge[{index}]"))
    return Overrides(
        merge=merge,
        split=_string_list(loaded.get("split"), "split"),
        exclude=_string_list(loaded.get("exclude"), "exclude"),
    )


def load_overrides(path: Path) -> Overrides:
    if not path.exists():
        return Overrides()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise OverrideError(f"cannot be read ({type(error).__name__})") from None
    return parse_overrides(text)


def _check_names(overrides: Overrides, known: dict[str, RawFile]) -> None:
    entries: list[tuple[str, str]] = [
        (f"merge[{i}][{j}]", name)
        for i, names in enumerate(overrides.merge)
        for j, name in enumerate(names)
    ]
    entries += [(f"split[{i}]", name) for i, name in enumerate(overrides.split)]
    entries += [(f"exclude[{i}]", name) for i, name in enumerate(overrides.exclude)]
    for where, name in entries:
        if name not in known:
            raise OverrideError(f"{where}: {name!r} is not a scanned raw file")
    excluded = set(overrides.exclude)
    for where, name in entries:
        if not where.startswith("exclude") and name in excluded:
            raise OverrideError(f"{where}: {name!r} is also excluded")
    for index, names in enumerate(overrides.merge):
        batches = {known[name].batch for name in names}
        if len(batches) > 1:
            raise OverrideError(f"merge[{index}]: the files are in different batches")


def apply_overrides(
    groups: list[list[RawFile]], overrides: Overrides, known: dict[str, RawFile]
) -> tuple[list[list[RawFile]], list[RawFile]]:
    """Apply exclude, then split, then merge. Return (groups, excluded files)."""
    _check_names(overrides, known)
    excluded_names = set(overrides.exclude)
    excluded = [known[name] for name in sorted(excluded_names, key=lambda n: known[n].order)]
    # Removing a photo keeps the rest of its group together, even when it was in the middle.
    kept = [[f for f in group if f.name not in excluded_names] for group in groups]
    kept = [group for group in kept if group]

    split_names = set(overrides.split)
    after_split: list[list[RawFile]] = []
    for group in kept:
        current: list[RawFile] = []
        for item in group:
            if item.name in split_names and current:
                after_split.append(current)
                current = []
            current.append(item)
        after_split.append(current)

    # Union-find over group indexes, so that overlapping merge entries join into one receipt.
    parent = list(range(len(after_split)))

    def root(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    where = {item.name: index for index, group in enumerate(after_split) for item in group}
    for names in overrides.merge:
        first = root(where[names[0]])
        for name in names[1:]:
            other = root(where[name])
            if other != first:
                parent[other] = first

    merged: dict[int, list[RawFile]] = {}
    for index, group in enumerate(after_split):
        merged.setdefault(root(index), []).extend(group)
    result = [sorted(group, key=lambda f: f.order) for group in merged.values()]
    result.sort(key=lambda group: group[0].order)
    return result, excluded
