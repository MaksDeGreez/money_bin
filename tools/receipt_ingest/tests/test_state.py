"""state.json: checked entry by entry, versions per written file, and the order of writes."""

import json
import os
import stat

import pytest
from support import receipt_on_table, receipts, shot, state

from receipt_ingest import fsutil, numbering, pipeline


def two_receipts(raw):
    shot(raw, "b/IMG_0001.jpg", 0)
    shot(raw, "b/IMG_0002.jpg", 3)
    shot(raw, "b/IMG_0003.jpg", 60)


def write_state(out, data):
    (out / "state.json").write_text(json.dumps(data))


def first(data):
    return data["receipts"][0]


def set_next_id_low(data):
    data["next_id"] = 2


def drop_key(data):
    del first(data)["key"]


def id_also_retired(data):
    data["retired"].append({"receipt_id": "rcpt_000001", "key": "f" * 64, "reason": "merged"})


def key_also_retired(data):
    data["retired"].append({"receipt_id": "rcpt_000007", "key": first(data)["key"], "reason": "x"})
    data["next_id"] = 8


def same_id_twice(data):
    data["receipts"][1]["receipt_id"] = "rcpt_000001"


def id_not_canonical(data):
    first(data)["receipt_id"] = "rcpt_0000001"


def id_not_text(data):
    first(data)["receipt_id"] = 1


def parts_not_a_list(data):
    first(data)["parts"] = "abc"


def image_bytes_as_text(data):
    first(data)["images"][0]["bytes"] = "12"


def image_of_another_receipt(data):
    first(data)["images"][0]["file"] = "images/rcpt_000002_1.jpg"


def image_path_outside(data):
    first(data)["images"][0]["file"] = "../../elsewhere.jpg"


def image_without_versions(data):
    del first(data)["images"][0]["written_by"]


def some_images_only(data):
    first(data)["images"].pop()


def same_photo_in_two_receipts(data):
    second = data["receipts"][1]
    second["parts"].append(first(data)["key"])
    second["raw_files"].append("b/x.jpg")
    second["images"] = []  # so that only the shared photo is wrong


def unknown_stage(data):
    first(data)["failed_stages"] = ["everything"]


def qr_not_a_mapping(data):
    first(data)["qr"] = "payload"


def crop_part_out_of_range(data):
    first(data)["crop"] = {"parts": [{"part": 9, "failed": "no_shape"}]}


def retired_entry_not_a_mapping(data):
    data["retired"].append("rcpt_000009")


@pytest.mark.parametrize(
    "damage",
    [
        set_next_id_low,
        drop_key,
        id_also_retired,
        key_also_retired,
        same_id_twice,
        id_not_canonical,
        id_not_text,
        parts_not_a_list,
        image_bytes_as_text,
        image_of_another_receipt,
        image_path_outside,
        image_without_versions,
        some_images_only,
        same_photo_in_two_receipts,
        unknown_stage,
        qr_not_a_mapping,
        crop_part_out_of_range,
        retired_entry_not_a_mapping,
    ],
)
def test_a_damaged_entry_stops_the_run(raw, out, run_tool, damage):
    two_receipts(raw)
    run_tool(raw, out)
    data = state(out)
    damage(data)
    write_state(out, data)
    images_before = sorted(path.name for path in (out / "images").iterdir())
    result = run_tool(raw, out)
    assert result.code == 2
    assert result.err == "error: state.json has an unknown shape\n"
    assert sorted(path.name for path in (out / "images").iterdir()) == images_before


def test_ids_sort_by_their_number(raw, out, run_tool):
    two_receipts(raw)
    out.mkdir()
    write_state(out, {"format": 1, "next_id": 999_999, "receipts": [], "retired": []})
    assert run_tool(raw, out).code == 0
    assert [line["receipt_id"] for line in receipts(out)] == ["rcpt_999999", "rcpt_1000000"]
    assert [r["receipt_id"] for r in state(out)["receipts"]] == ["rcpt_999999", "rcpt_1000000"]
    assert run_tool(raw, out).code == 0
    assert state(out)["next_id"] == 1_000_001


def test_versions_are_recorded_per_written_file(raw, out, run_tool):
    two_receipts(raw)
    run_tool(raw, out)
    data = state(out)
    record = first(data)
    assert "written_by" not in record
    for entry in record["images"] + record["thumbs"]:
        assert entry["written_by"]["pillow"]
    for line in receipts(out):
        for image in line["images"]:
            assert list(image) == ["file", "sha256", "width", "height", "bytes"]

    # A reused image keeps the versions that wrote it; a rewritten one gets this run's.
    record["images"][0]["written_by"] = {"pillow": "0.0-test"}
    record["images"][1]["written_by"] = {"pillow": "0.0-test"}
    write_state(out, data)
    (out / record["images"][1]["file"]).unlink()
    run_tool(raw, out)
    images = first(state(out))["images"]
    assert images[0]["written_by"] == {"pillow": "0.0-test"}
    assert images[1]["written_by"]["pillow"] != "0.0-test"
    assert images[1]["written_by"]["receipt_ingest"]


def test_state_is_written_before_orphans_go_and_derived_files_come_last(
    raw, out, run_tool, monkeypatch
):
    two_receipts(raw)
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("merge: [[b/IMG_0001.jpg, b/IMG_0003.jpg]]\n")
    events = []
    real_write, real_remove = pipeline.write_if_changed, pipeline.Run.remove_orphans

    def write(path, data):
        events.append(path.name)
        return real_write(path, data)

    def remove(out_dir, records):
        events.append("orphans")
        # When orphans go, state.json already no longer refers to them.
        recorded = json.loads((out_dir / "state.json").read_text())["receipts"]
        assert [r["receipt_id"] for r in recorded] == ["rcpt_000001"]
        assert len(recorded[0]["images"]) == 3
        return real_remove(out_dir, records)

    monkeypatch.setattr(pipeline, "write_if_changed", write)
    monkeypatch.setattr(pipeline.Run, "remove_orphans", staticmethod(remove))
    result = run_tool(raw, out)
    assert "2 files deleted" in result.out  # the image and the thumbnail of rcpt_000002
    assert events == ["state.json", "orphans", "receipts.jsonl", "groups_review.html"]


def test_atomic_write_syncs_the_folder(tmp_path, monkeypatch):
    synced = []
    real_fsync = os.fsync

    def fsync(fd):
        synced.append(stat.S_ISDIR(os.fstat(fd).st_mode))
        real_fsync(fd)

    monkeypatch.setattr(fsutil.os, "fsync", fsync)
    fsutil.write_atomic(tmp_path / "file.json", b"{}")
    assert synced == [False, True]


def test_an_empty_state_is_valid():
    assert numbering.load_state(json.dumps(numbering.empty_state())) == numbering.empty_state()


def test_a_file_left_as_it_was_keeps_the_versions_that_wrote_it(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0, image=receipt_on_table())
    run_tool(raw, out)
    old = {"pillow": "0.0-test"}
    data = state(out)
    record = first(data)
    assert record["crop"]["parts"][0]["file"]
    for entry in record["images"] + record["thumbs"] + record["crop"]["parts"]:
        entry["written_by"] = old
    record["failed_stages"] = ["thumbs"]
    write_state(out, data)

    # Thumbnails and crop are made again, with the same bytes: nothing is written.
    result = run_tool(raw, out, "--redo-crop")
    assert "Written: 0 images, 0 crops, 0 thumbnails" in result.out
    record = first(state(out))
    for entry in record["thumbs"] + record["crop"]["parts"]:
        assert entry["written_by"] == old

    # A photo joins: the first image is encoded again with the same bytes and is not written.
    shot(raw, "b/IMG_0002.jpg", 2, image=receipt_on_table())
    result = run_tool(raw, out)
    assert "Written: 1 images" in result.out
    images = first(state(out))["images"]
    assert images[0]["written_by"] == old
    assert images[1]["written_by"]["pillow"] != "0.0-test"


@pytest.mark.parametrize("captured_at", [None, "not a time", "2026-13-01T10:00:00+02:00"])
def test_a_receipt_without_a_usable_capture_time_comes_last_in_its_batch(captured_at):
    timed = {"batch": "b", "captured_at": "2026-03-01T10:00:00.5+02:00", "raw_files": ["b/z"]}
    other = {"batch": "b", "captured_at": captured_at, "raw_files": ["b/a"]}
    records = [other, timed]
    pipeline.number_in_batches(records)
    assert (timed["seq_in_batch"], other["seq_in_batch"]) == (1, 2)
