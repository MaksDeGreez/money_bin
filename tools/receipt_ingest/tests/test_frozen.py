"""A receipt that lost some of its raw photos is kept exactly as recorded until they come back."""

import shutil

from support import receipts, shot, snapshot, state

NAMES = [f"b/IMG_000{i}.jpg" for i in (1, 2, 3)]


def three_part_receipt(raw):
    """b: one receipt of three photos, then a second receipt of one photo."""
    for seconds, name in zip((0, 3, 6), NAMES, strict=True):
        shot(raw, name, seconds, color=(100 + seconds, 120, 140))
    shot(raw, "b/IMG_0009.jpg", 60)


def move_away(raw, aside, *names):
    aside.mkdir(exist_ok=True)
    for name in names:
        shutil.move(raw / name, aside / name.replace("/", "_"))


def bring_back(raw, aside, *names):
    for name in names:
        shutil.move(aside / name.replace("/", "_"), raw / name)


def output_files(out):
    return {**snapshot(out / "images"), **snapshot(out / "thumbs")}


def test_losing_the_last_photo_freezes_the_receipt(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    first_lines = receipts(out)
    files_before = output_files(out)
    next_id = state(out)["next_id"]

    move_away(raw, tmp_path / "aside", NAMES[2])
    result = run_tool(raw, out)
    assert result.code == 0
    frozen = receipts(out)[0]
    assert frozen["receipt_id"] == "rcpt_000001"
    assert frozen["raw_files"] == NAMES
    assert frozen["images"] == first_lines[0]["images"]
    assert frozen["flags"][0] == "raw_missing"
    assert "1 raw missing" in result.out
    assert "0 files deleted" in result.out
    assert output_files(out) == files_before
    assert state(out)["next_id"] == next_id
    assert state(out)["retired"] == []

    bring_back(raw, tmp_path / "aside", NAMES[2])
    result = run_tool(raw, out)
    assert receipts(out) == first_lines
    assert output_files(out) == files_before
    assert "0 new, 2 unchanged, 0 rewritten" in result.out
    assert "Written: 0 images, 0 crops, 0 thumbnails" in result.out


def test_losing_the_earliest_photo_gives_the_rest_no_new_number(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    first_lines = receipts(out)
    files_before = output_files(out)

    move_away(raw, tmp_path / "aside", NAMES[0])
    result = run_tool(raw, out)
    assert [line["receipt_id"] for line in receipts(out)] == ["rcpt_000001", "rcpt_000002"]
    assert receipts(out)[0]["raw_files"] == NAMES
    assert "0 new" in result.out and "0 retired" in result.out
    assert state(out)["next_id"] == 3
    assert output_files(out) == files_before

    bring_back(raw, tmp_path / "aside", NAMES[0])
    run_tool(raw, out)
    assert receipts(out) == first_lines
    assert output_files(out) == files_before


def test_overrides_wait_for_a_frozen_receipt(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    files_before = output_files(out)
    move_away(raw, tmp_path / "aside", NAMES[2])
    # The names of present photos stay valid, but nothing happens to the frozen receipt.
    (out / "groups_override.yaml").write_text(
        f"exclude: [{NAMES[1]}]\nmerge: [[b/IMG_0009.jpg, {NAMES[0]}]]\n"
    )
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert [line["raw_files"] for line in receipts(out)] == [NAMES, ["b/IMG_0009.jpg"]]
    assert output_files(out) == files_before
    assert "Excluded" not in (out / "groups_review.html").read_text()

    # With every photo back the overrides apply.
    bring_back(raw, tmp_path / "aside", NAMES[2])
    (out / "groups_override.yaml").write_text(f"exclude: [{NAMES[1]}]\n")
    result = run_tool(raw, out)
    assert receipts(out)[0]["raw_files"] == [NAMES[0], NAMES[2]]
    assert receipts(out)[0]["receipt_id"] == "rcpt_000001"
    assert "1 rewritten" in result.out


def test_a_photo_that_became_unreadable_freezes_its_receipt(raw, out, run_tool):
    three_part_receipt(raw)
    run_tool(raw, out)
    files_before = output_files(out)
    (raw / NAMES[1]).write_bytes(b"not an image any more")
    result = run_tool(raw, out)
    assert "skipped unreadable: b/IMG_0002.jpg" in result.err
    assert receipts(out)[0]["flags"][0] == "raw_missing"
    assert output_files(out) == files_before


def test_a_frozen_receipt_keeps_its_place_in_the_batch(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    shot(raw, "b/IMG_0010.jpg", 120)
    run_tool(raw, out)
    lines = receipts(out)
    assert [line["seq_in_batch"] for line in lines] == [1, 2, 3]

    move_away(raw, tmp_path / "aside", NAMES[0])
    run_tool(raw, out)
    assert [line["seq_in_batch"] for line in receipts(out)] == [1, 2, 3]
    assert receipts(out)[1:] == lines[1:]

    # A new receipt before it moves the frozen one down, by its recorded capture time.
    shot(raw, "b/IMG_0000.jpg", -60)
    run_tool(raw, out)
    seq = {line["receipt_id"]: line["seq_in_batch"] for line in receipts(out)}
    assert seq == {"rcpt_000001": 2, "rcpt_000002": 3, "rcpt_000003": 4, "rcpt_000004": 1}


def test_a_merge_that_names_a_missing_photo_waits(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    out.mkdir()
    (out / "groups_override.yaml").write_text(f"merge: [[{NAMES[0]}, b/IMG_0009.jpg]]\n")
    run_tool(raw, out)
    lines = receipts(out)
    assert [line["raw_files"] for line in lines] == [[*NAMES, "b/IMG_0009.jpg"]]
    files_before = output_files(out)

    shutil.move(raw / "b", tmp_path / "b_aside")
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert "raw_missing" in receipts(out)[0]["flags"]
    assert output_files(out) == files_before

    shutil.move(tmp_path / "b_aside", raw / "b")
    result = run_tool(raw, out)
    assert result.code == 0
    assert receipts(out) == lines
    assert output_files(out) == files_before


def test_a_split_that_names_a_missing_photo_waits(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    files_before = output_files(out)
    move_away(raw, tmp_path / "aside", NAMES[2])
    (out / "groups_override.yaml").write_text(f"split: [{NAMES[2]}]\n")
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert receipts(out)[0]["raw_files"] == NAMES
    assert output_files(out) == files_before


def test_excluding_a_missing_photo_releases_its_receipt(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    move_away(raw, tmp_path / "aside", NAMES[2])
    (out / "groups_override.yaml").write_text(f"exclude: [{NAMES[2]}]\n")
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    first = receipts(out)[0]
    assert first["receipt_id"] == "rcpt_000001"
    assert first["raw_files"] == NAMES[:2]
    assert "raw_missing" not in first["flags"]
    assert "0 raw missing" in result.out and "1 rewritten" in result.out
    assert not (out / "images/rcpt_000001_3.jpg").exists()
    assert not (out / "thumbs/rcpt_000001_3.jpg").exists()


def test_excluding_a_missing_earliest_photo_retires_its_number(raw, out, run_tool, tmp_path):
    three_part_receipt(raw)
    run_tool(raw, out)
    move_away(raw, tmp_path / "aside", NAMES[0], "b/IMG_0009.jpg")
    (out / "groups_override.yaml").write_text(f"exclude: [{NAMES[0]}, b/IMG_0009.jpg]\n")
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    # The rest of rcpt_000001 gets a new number; rcpt_000002 lost its only photo.
    assert [(line["receipt_id"], line["raw_files"]) for line in receipts(out)] == [
        ("rcpt_000003", NAMES[1:])
    ]
    assert [(entry["receipt_id"], entry["reason"]) for entry in state(out)["retired"]] == [
        ("rcpt_000001", "excluded"),
        ("rcpt_000002", "excluded"),
    ]
    remaining = {path.name for path in (out / "images").iterdir()}
    assert remaining == {"rcpt_000003_1.jpg", "rcpt_000003_2.jpg"}


def test_a_stale_name_of_a_renamed_photo_is_still_an_error(raw, out, run_tool):
    three_part_receipt(raw)
    run_tool(raw, out)
    (raw / NAMES[2]).rename(raw / "b/IMG_0003_renamed.jpg")
    (out / "groups_override.yaml").write_text(f"exclude: [{NAMES[2]}]\n")
    result = run_tool(raw, out)
    assert result.code == 2
    assert "is not a scanned raw file" in result.err
