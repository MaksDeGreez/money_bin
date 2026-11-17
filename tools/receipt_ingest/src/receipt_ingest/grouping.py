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


class _UniqueKeyLoader(yaml.SafeLoader):
    """PyYAML's safe loader, except that a key written twice is an error.

    PyYAML keeps the last of two equal keys, so a second `exclude:` would silently drop the first.
    """


def _unique_mapping(loader: _UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    seen: set = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=True)
        try:
            repeated = key in seen
        except TypeError:  # an unhashable key: the safe constructor below reports it
            continue
        if repeated:
            raise OverrideError(f"{str(key)!r}: the key appears more than once")
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)


def _check_repeats(merge: list[list[str]], split: list[str], exclude: list[str]) -> None:
    # A name listed twice is almost always a copy-paste slip that hides the name meant instead.
    seen: dict[str, str] = {}
    for index, names in enumerate(merge):
        for position, name in enumerate(names):
            where = f"merge[{index}][{position}]"
            if name in seen:
                raise OverrideError(f"{where}: {name!r} is already in {seen[name]}")
            seen[name] = where
    for key, names in (("split", split), ("exclude", exclude)):
        listed: dict[str, str] = {}
        for index, name in enumerate(names):
            where = f"{key}[{index}]"
            if name in listed:
                raise OverrideError(f"{where}: {name!r} is already in {listed[name]}")
            listed[name] = where


def parse_overrides(text: str) -> Overrides:
    try:
        # _UniqueKeyLoader is a SafeLoader: it builds plain data only, never Python objects.
        loaded = yaml.load(text, Loader=_UniqueKeyLoader)
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
    split = _string_list(loaded.get("split"), "split")
    exclude = _string_list(loaded.get("exclude"), "exclude")
    _check_repeats(merge, split, exclude)
    return Overrides(merge=merge, split=split, exclude=exclude)


def load_overrides(path: Path) -> Overrides:
    if not path.exists():
        return Overrides()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise OverrideError(f"cannot be read ({type(error).__name__})") from None
    return parse_overrides(text)


def _batch_of(name: str) -> str:
    # The batch is the folder directly under the raw folder, so the name alone tells it, also
    # for a photo that is not there in this run.
    return name.split("/", 1)[0]


def _check_names(overrides: Overrides, known: dict[str, RawFile], waiting: set[str]) -> None:
    entries: list[tuple[str, str]] = [
        (f"merge[{i}][{j}]", name)
        for i, names in enumerate(overrides.merge)
        for j, name in enumerate(names)
    ]
    entries += [(f"split[{i}]", name) for i, name in enumerate(overrides.split)]
    entries += [(f"exclude[{i}]", name) for i, name in enumerate(overrides.exclude)]
    for where, name in entries:
        if name not in known and name not in waiting:
            raise OverrideError(f"{where}: {name!r} is not a scanned raw file")
    excluded = set(overrides.exclude)
    for where, name in entries:
        if not where.startswith("exclude") and name in excluded:
            raise OverrideError(f"{where}: {name!r} is also excluded")
    for index, names in enumerate(overrides.merge):
        batches = {_batch_of(name) for name in names}
        if len(batches) > 1:
            raise OverrideError(f"merge[{index}]: the files are in different batches")


@dataclass
class Grouped:
    groups: list[list[RawFile]]
    excluded: list[RawFile]
    # SHA-256 of the first photos of groups that a merge entry joined into an earlier group.
    merged: set[str]


def apply_overrides(
    groups: list[list[RawFile]],
    overrides: Overrides,
    known: dict[str, RawFile],
    frozen: set[str] | None = None,
    waiting: set[str] | None = None,
) -> Grouped:
    """Apply exclude, then split, then merge.

    `known` holds every scanned file by name, `groups` only those that may be regrouped. Names in
    `frozen` (photos of receipts kept as recorded because another of their photos is missing) are
    valid names, but the entries that use them wait until the receipt is complete again. Names in
    `waiting` are recorded photos missing from this run: valid too, and a merge or split that
    uses one waits for it. (Excluding a missing photo releases it; the caller handles that.)
    """
    waiting = waiting or set()
    _check_names(overrides, known, waiting)
    frozen = frozen or set()
    on_hold = frozen | waiting
    excluded_names = set(overrides.exclude) - on_hold
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
        if on_hold.intersection(names):
            continue
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
    heads = {group[0].sha256 for group in result}
    joined = {group[0].sha256 for group in after_split} - heads
    return Grouped(result, excluded, joined)
