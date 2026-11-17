import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from receipt_ingest import grouping
from receipt_ingest.scan import RawFile

START = datetime(2026, 3, 1, 8, 0, tzinfo=UTC)


def make_files(spec: list[tuple[str, float | None]]) -> list[RawFile]:
    files = []
    for order, (name, seconds) in enumerate(spec):
        taken = None if seconds is None else START + timedelta(seconds=seconds)
        files.append(
            RawFile(name, name.split("/")[0], Path(name), f"sha-{name}", taken, None, order=order)
        )
    return files


def names(groups):
    return [[item.name for item in group] for group in groups]


def test_gap_boundary_keeps_eight_seconds_together():
    files = make_files([("b/1", 0), ("b/2", 8), ("b/3", 16.001), ("b/4", 30)])
    assert names(grouping.group_by_gap(files, 8)) == [["b/1", "b/2"], ["b/3"], ["b/4"]]


def test_groups_never_cross_batches_and_untimed_files_stand_alone():
    files = make_files([("a/1", 0), ("b/1", 1), ("b/2", 2), ("b/3", None), ("b/4", None)])
    assert names(grouping.group_by_gap(files, 8)) == [["a/1"], ["b/1", "b/2"], ["b/3"], ["b/4"]]


@pytest.fixture
def setup():
    files = make_files(
        [("b/1", 0), ("b/2", 3), ("b/3", 6), ("b/4", 30), ("b/5", 33), ("b/6", 60), ("c/1", 0)]
    )
    known = {item.name: item for item in files}
    return grouping.group_by_gap(files, 8), known


def test_exclude_keeps_the_rest_of_the_group_together(setup):
    groups, known = setup
    grouped = grouping.apply_overrides(groups, grouping.Overrides(exclude=["b/2"]), known)
    assert names(grouped.groups) == [["b/1", "b/3"], ["b/4", "b/5"], ["b/6"], ["c/1"]]
    assert [item.name for item in grouped.excluded] == ["b/2"]
    assert grouped.merged == set()


def test_excluding_a_whole_group_removes_it(setup):
    groups, known = setup
    result = grouping.apply_overrides(groups, grouping.Overrides(exclude=["b/6"]), known)
    assert names(result.groups) == [["b/1", "b/2", "b/3"], ["b/4", "b/5"], ["c/1"]]


def test_split_starts_a_new_receipt(setup):
    groups, known = setup
    overrides = grouping.Overrides(split=["b/2", "b/4"])
    result = grouping.apply_overrides(groups, overrides, known)
    assert names(result.groups) == [["b/1"], ["b/2", "b/3"], ["b/4", "b/5"], ["b/6"], ["c/1"]]


def test_merge_joins_whole_groups_in_capture_order(setup):
    groups, known = setup
    overrides = grouping.Overrides(merge=[["b/6", "b/1"], ["b/4", "b/6"]])
    result = grouping.apply_overrides(groups, overrides, known)
    assert names(result.groups) == [["b/1", "b/2", "b/3", "b/4", "b/5", "b/6"], ["c/1"]]
    assert result.merged == {"sha-b/4", "sha-b/6"}


def test_entries_naming_a_frozen_photo_wait(setup):
    # b/4 and b/5 belong to a receipt kept as recorded: they are not in the groups, their names
    # stay valid, and the entries that use them do nothing for now.
    groups, known = setup
    groups = [[item for item in group if item.name not in ("b/4", "b/5")] for group in groups]
    groups = [group for group in groups if group]
    overrides = grouping.Overrides(
        merge=[["b/1", "b/4"], ["b/6", "b/1"]], exclude=["b/5"], split=["b/4"]
    )
    result = grouping.apply_overrides(groups, overrides, known, frozen={"b/4", "b/5"})
    assert names(result.groups) == [["b/1", "b/2", "b/3", "b/6"], ["c/1"]]
    assert result.excluded == []
    assert result.merged == {"sha-b/6"}


def test_split_then_merge_order(setup):
    groups, known = setup
    overrides = grouping.Overrides(split=["b/3"], merge=[["b/3", "b/4"]])
    result = grouping.apply_overrides(groups, overrides, known)
    assert names(result.groups) == [["b/1", "b/2"], ["b/3", "b/4", "b/5"], ["b/6"], ["c/1"]]


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        (grouping.Overrides(merge=[["b/1", "c/1"]]), "merge[0]: the files are in different"),
        (grouping.Overrides(split=["b/9"]), "split[0]: 'b/9' is not a scanned raw file"),
        (grouping.Overrides(exclude=["zz"]), "exclude[0]: 'zz' is not a scanned raw file"),
        (grouping.Overrides(merge=[["b/1", "b/x"]]), "merge[0][1]: 'b/x' is not a scanned"),
        (grouping.Overrides(exclude=["b/1"], split=["b/1"]), "split[0]: 'b/1' is also excluded"),
        (
            grouping.Overrides(exclude=["b/4"], merge=[["b/1", "b/4"]]),
            "merge[0][1]: 'b/4' is also excluded",
        ),
    ],
)
def test_override_errors(setup, overrides, message):
    groups, known = setup
    with pytest.raises(grouping.OverrideError, match=re.escape(message)):
        grouping.apply_overrides(groups, overrides, known)


def test_parse_full_file():
    text = """
merge:   [[b/1, b/2]]
split:   [b/4]
exclude: [b/6]
"""
    parsed = grouping.parse_overrides(text)
    assert parsed == grouping.Overrides(merge=[["b/1", "b/2"]], split=["b/4"], exclude=["b/6"])


@pytest.mark.parametrize("text", ["", "# nothing yet\n", "merge:\nsplit:\nexclude:\n"])
def test_empty_files_mean_no_overrides(text):
    assert grouping.parse_overrides(text) == grouping.Overrides()


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("join: [[a, b]]", "unknown key 'join'"),
        ("- a\n- b", "the top level must be a mapping"),
        ("merge: [a, b]", r"merge\[0\]: must be a list of two or more"),
        ("merge: [[a]]", r"merge\[0\]: must be a list of two or more"),
        ("merge: a", "merge: must be a list of lists"),
        ("merge: [[a, 3]]", r"merge\[0\]\[1\]: must be a file name"),
        ("split: a", "split: must be a list of file names"),
        ("exclude: [[a]]", r"exclude\[0\]: must be a file name"),
        ("merge: [[a, b]\nsplit: [", r"not valid YAML \(\w+\) near line \d"),
        ("exclude: [a]\nsplit: [b]\nexclude: [c]\n", "'exclude': the key appears more than once"),
        ("merge: [[a, b]]\nmerge: [[c, d]]\n", "'merge': the key appears more than once"),
        ("? [a]\n: [b]\n", r"not valid YAML \(\w+\)"),
        ("merge: [[a, b, a]]", r"merge\[0\]\[2\]: 'a' is already in merge\[0\]\[0\]"),
        ("merge: [[a, b], [c, b]]", r"merge\[1\]\[1\]: 'b' is already in merge\[0\]\[1\]"),
        ("split: [a, b, a]", r"split\[2\]: 'a' is already in split\[0\]"),
        ("exclude: [a, a]", r"exclude\[1\]: 'a' is already in exclude\[0\]"),
    ],
)
def test_parse_errors(text, message):
    with pytest.raises(grouping.OverrideError, match=message):
        grouping.parse_overrides(text)


def test_missing_override_file(tmp_path):
    assert grouping.load_overrides(tmp_path / "none.yaml") == grouping.Overrides()


def test_unreadable_override_file(tmp_path):
    path = tmp_path / "groups_override.yaml"
    path.write_bytes(b"\xff\xfe\x00bad")
    with pytest.raises(grouping.OverrideError, match="cannot be read"):
        grouping.load_overrides(path)
