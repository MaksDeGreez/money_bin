"""A failure in one stage never costs good images, and the failed stage is tried again."""

import json
import os

import pytest
from support import (
    OTHER_URL,
    TAX_URL,
    page_with_qr,
    receipt_on_table,
    receipts,
    shot,
    snapshot,
    state,
)

from receipt_ingest import imaging, worker


def qr_and_table(raw):
    shot(raw, "q/IMG_0001.jpg", 0, image=page_with_qr(TAX_URL, size=(400, 520), scale=4))
    shot(raw, "q/IMG_0002.jpg", 2, image=receipt_on_table())
    shot(raw, "q/IMG_0003.jpg", 60, image=page_with_qr(OTHER_URL, size=(400, 520), scale=4))


def broken(*args, **kwargs):
    raise RuntimeError("synthetic detail that must not be printed")


def output_files(out):
    return {**snapshot(out / "images"), **snapshot(out / "thumbs")}


def crop(path):
    return path.name.endswith("_crop.jpg")


def with_a_trailer(applies):
    """A stage() that writes extra bytes the in-memory check never saw, for the chosen files."""
    real_stage = worker.stage

    def stage(path, data, check=None):
        return real_stage(path, data + b"trailer" if applies(path) else data, check)

    return stage


@pytest.mark.parametrize(
    ("target", "stage"),
    [(worker.qr, "decode_jpeg"), (worker.crop, "find_quad"), (worker.imaging, "thumbnail")],
)
def test_a_late_stage_failure_keeps_the_new_images(raw, out, run_tool, monkeypatch, target, stage):
    qr_and_table(raw)
    with monkeypatch.context() as patch:
        patch.setattr(target, stage, broken)
        result = run_tool(raw, out)
    assert result.code == 1
    assert "synthetic" not in result.err
    assert "error: q/IMG_0001.jpg: RuntimeError (" in result.err
    lines = receipts(out)
    assert all("processing_failed" in line["flags"] for line in lines)
    for line in lines:
        assert len(line["images"]) == len(line["raw_files"])
        for image in line["images"]:
            assert (out / image["file"]).stat().st_size == image["bytes"]
    images_before = snapshot(out / "images")
    images_before = {name: data for name, data in images_before.items() if "_crop" not in name}

    # The next run tries the failed stage again and converts nothing.
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert "Written: 0 images" in result.out
    current = {k: v for k, v in snapshot(out / "images").items() if "_crop" not in k}
    assert current == images_before
    tax, other = receipts(out)
    assert "processing_failed" not in tax["flags"]
    assert tax["qr_payload"] == TAX_URL and other["qr_payload"] == OTHER_URL
    assert tax["crop"][0]["part"] == 2
    assert all(len(r["thumbs"]) == len(r["parts"]) for r in state(out)["receipts"])


def test_a_failure_on_an_unchanged_receipt_keeps_what_was_recorded(raw, out, run_tool, monkeypatch):
    qr_and_table(raw)
    run_tool(raw, out)
    lines_before = receipts(out)
    files_before = output_files(out)
    with monkeypatch.context() as patch:
        patch.setattr(worker.qr, "decode_jpeg", broken)
        patch.setattr(worker.crop, "find_quad", broken)
        result = run_tool(raw, out, "--redo-qr", "--redo-crop")
    assert result.code == 1
    assert result.err.count("(qr)") == 2 and result.err.count("(crop)") == 2
    assert "0 files deleted" in result.out
    assert output_files(out) == files_before
    after = receipts(out)
    for old, new in zip(lines_before, after, strict=True):
        assert new["flags"] == ["processing_failed", *old["flags"]]
        assert {k: v for k, v in new.items() if k != "flags"} == {
            k: v for k, v in old.items() if k != "flags"
        }
    assert [r["failed_stages"] for r in state(out)["receipts"]] == [["qr", "crop"]] * 2

    # Without --redo-qr the failed stages run again because they failed.
    result = run_tool(raw, out)
    assert result.code == 0
    assert receipts(out) == lines_before
    assert output_files(out) == files_before
    assert "clahe_half: 2 /" in result.out


def test_a_conversion_failure_on_an_unchanged_receipt_deletes_nothing(
    raw, out, run_tool, monkeypatch
):
    qr_and_table(raw)
    run_tool(raw, out)
    lines_before = receipts(out)
    files_before = output_files(out)
    lost = out / "images/rcpt_000001_2.jpg"
    lost.unlink()
    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "decode_to_srgb", broken)
        result = run_tool(raw, out)
    assert result.code == 1
    assert "error: q/IMG_0002.jpg: RuntimeError (convert)" in result.err
    assert "0 files deleted" in result.out
    assert receipts(out)[0]["images"] == lines_before[0]["images"]
    assert {k: v for k, v in output_files(out).items() if k != "rcpt_000001_2.jpg"} == {
        k: v for k, v in files_before.items() if k != "rcpt_000001_2.jpg"
    }
    result = run_tool(raw, out)
    assert result.code == 0
    assert "Written: 1 images, 0 crops, 0 thumbnails" in result.out
    assert receipts(out) == lines_before


def test_a_stage_waiting_for_its_retry_is_not_forgotten(raw, out, run_tool, monkeypatch):
    qr_and_table(raw)
    run_tool(raw, out)
    with monkeypatch.context() as patch:
        patch.setattr(worker.qr, "decode_jpeg", broken)
        run_tool(raw, out, "--redo-qr")
    (out / "images/rcpt_000001_2.jpg").unlink()
    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "decode_to_srgb", broken)
        result = run_tool(raw, out)
    assert result.err.count("(convert)") == 1 and "(qr)" not in result.err
    assert state(out)["receipts"][0]["failed_stages"] == ["convert", "qr"]
    result = run_tool(raw, out)
    assert result.code == 0
    assert [r["failed_stages"] for r in state(out)["receipts"]] == [[], []]
    # Only the first receipt still owed a QR retry; the second one made it up in the run before.
    assert "clahe_half: 1 /" in result.out
    assert receipts(out)[0]["qr_payload"] == TAX_URL


def test_a_failed_thumbnail_stage_is_redone_whole(raw, out, run_tool, monkeypatch):
    qr_and_table(raw)
    run_tool(raw, out)
    thumbs_before = snapshot(out / "thumbs")
    (out / "thumbs/rcpt_000001_2.jpg").unlink()
    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "thumbnail", broken)
        result = run_tool(raw, out)
    assert "error: q/IMG_0002.jpg: RuntimeError (thumbs)" in result.err
    assert "thumbs" in state(out)["receipts"][0]["failed_stages"]
    # A thumbnail of the right size but other bytes would be reused by a normal run.
    first_thumb = out / "thumbs/rcpt_000001_1.jpg"
    first_thumb.write_bytes(bytes(len(first_thumb.read_bytes())))
    result = run_tool(raw, out)
    assert result.code == 0
    assert "Written: 0 images, 0 crops, 2 thumbnails" in result.out
    assert {k: v[0] for k, v in snapshot(out / "thumbs").items()} == {
        k: v[0] for k, v in thumbs_before.items()
    }


def test_a_written_file_is_checked_again_on_disk(raw, out, run_tool, monkeypatch):
    shot(raw, "b/IMG_0001.jpg", 0)
    shot(raw, "b/IMG_0002.jpg", 60, image=receipt_on_table())
    monkeypatch.setattr(
        worker, "stage", with_a_trailer(lambda path: path.name == "rcpt_000001_1.jpg" or crop(path))
    )
    result = run_tool(raw, out)
    assert result.code == 1
    assert "error: b/IMG_0001.jpg: MetadataLeftError (convert)" in result.err
    assert "error: b/IMG_0002.jpg: MetadataLeftError (crop)" in result.err
    assert not (out / "images/rcpt_000001_1.jpg").exists()
    assert not (out / "images/rcpt_000002_1_crop.jpg").exists()
    first, second = receipts(out)
    assert first["images"] == [] and "processing_failed" in first["flags"]
    assert len(second["images"]) == 1 and "crop" not in second
    assert (out / second["images"][0]["file"]).exists()


def test_a_thumbnail_is_checked_again_on_disk(tmp_path, monkeypatch):
    receipt = worker._Receipt(
        worker.Task("rcpt_000001", str(tmp_path), [], None, True, False, False)
    )
    (tmp_path / "thumbs").mkdir()
    data = imaging.thumbnail(imaging.open_jpeg(imaging.encode_jpeg(receipt_on_table())))
    monkeypatch.setattr(worker, "stage", with_a_trailer(lambda path: True))
    with pytest.raises(imaging.MetadataLeftError):
        receipt.write("thumbs/rcpt_000001_1.jpg", data)
    assert list((tmp_path / "thumbs").iterdir()) == []


def test_a_rewrite_that_fails_the_check_keeps_the_good_files(raw, out, run_tool, monkeypatch):
    qr_and_table(raw)
    run_tool(raw, out)
    lines_before = receipts(out)
    files_before = output_files(out)
    assert "images/rcpt_000001_2_crop.jpg" in {c["file"] for c in lines_before[0]["crop"]}
    # A thumbnail stage owed from an earlier run redoes every thumbnail of the receipt.
    data = state(out)
    data["receipts"][0]["failed_stages"] = ["thumbs"]
    (out / "state.json").write_text(json.dumps(data))
    records_before = state(out)["receipts"]

    with monkeypatch.context() as patch:
        patch.setattr(worker, "stage", with_a_trailer(lambda path: True))
        result = run_tool(raw, out, "--redo-crop")
    assert result.code == 1
    assert "MetadataLeftError (thumbs)" in result.err
    assert "MetadataLeftError (crop)" in result.err
    assert "0 files deleted" in result.out
    # The old files are still there with their old bytes, and the records still name them.
    assert output_files(out) == files_before
    after = state(out)["receipts"]
    for old, new in zip(records_before, after, strict=True):
        assert new["images"] == old["images"]
        assert new["thumbs"] == old["thumbs"]
        assert new["crop"] == old["crop"]
    first = receipts(out)[0]
    assert first["flags"] == ["processing_failed", *lines_before[0]["flags"]]
    assert {k: v for k, v in first.items() if k != "flags"} == {
        k: v for k, v in lines_before[0].items() if k != "flags"
    }
    assert state(out)["receipts"][0]["failed_stages"] == ["thumbs", "crop"]


def truncated_shot(raw, name, seconds):
    """A photo whose EXIF reads fine but whose pixels stop half way."""
    path = shot(raw, name, seconds, image=receipt_on_table())
    data = path.read_bytes()
    path.write_bytes(data[: len(data) * 2 // 3])


def test_an_unreadable_photo_that_joins_a_receipt_costs_it_nothing(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0, image=receipt_on_table())
    shot(raw, "b/IMG_0009.jpg", 60)
    run_tool(raw, out)
    lines_before = receipts(out)
    files_before = output_files(out)
    record_before = state(out)["receipts"][0]

    truncated_shot(raw, "b/IMG_0002.jpg", 2)
    everything = None
    for _ in range(2):
        result = run_tool(raw, out)
        assert result.code == 1
        assert "unreadable" not in result.err
        assert result.err.startswith("error: b/IMG_0002.jpg: ")
        assert result.err.rstrip().endswith("(convert)")
        assert "0 files deleted" in result.out
        assert output_files(out) == files_before
        kept, other = receipts(out)
        assert kept["flags"] == ["processing_failed", *lines_before[0]["flags"]]
        assert {k: v for k, v in kept.items() if k != "flags"} == {
            k: v for k, v in lines_before[0].items() if k != "flags"
        }
        assert other == lines_before[1]
        assert state(out)["receipts"][0] == {**record_before, "failed_stages": ["convert"]}
        # A second failing run changes nothing at all, not even an mtime.
        if everything is not None:
            assert snapshot(out) == everything
        everything = snapshot(out)

    # Once the photo reads, the receipt takes it in under its number.
    shot(raw, "b/IMG_0002.jpg", 2)
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    first = receipts(out)[0]
    assert first["receipt_id"] == "rcpt_000001"
    assert first["raw_files"] == ["b/IMG_0001.jpg", "b/IMG_0002.jpg"]
    assert len(first["images"]) == 2 and "processing_failed" not in first["flags"]


def test_a_receipt_whose_photo_went_elsewhere_cannot_be_kept(raw, out, run_tool, monkeypatch):
    for seconds, name in ((0, "b/IMG_0001.jpg"), (3, "b/IMG_0002.jpg"), (6, "b/IMG_0003.jpg")):
        shot(raw, name, seconds, color=(100 + seconds, 120, 140))
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("split: [b/IMG_0003.jpg]\n")
    bad = (raw / "b/IMG_0002.jpg").read_bytes()
    real_decode = worker.imaging.decode_to_srgb

    def decode(data):
        if data == bad:
            raise RuntimeError("synthetic")
        return real_decode(data)

    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "decode_to_srgb", decode)
        result = run_tool(raw, out)
    assert result.code == 1
    # Kept as recorded, rcpt_000001 would hold IMG_0003 too, which is now rcpt_000002.
    first, second = receipts(out)
    assert first["raw_files"] == ["b/IMG_0001.jpg", "b/IMG_0002.jpg"] and first["images"] == []
    assert second["raw_files"] == ["b/IMG_0003.jpg"] and len(second["images"]) == 1
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert len(receipts(out)[0]["images"]) == 2


def test_a_crop_owed_waits_through_a_no_crop_run(raw, out, run_tool, monkeypatch):
    qr_and_table(raw)
    real_find = worker.crop.find_quad

    def find_quad(grey):
        if grey.shape == (600, 400):  # the second photo of the first receipt
            raise RuntimeError("synthetic")
        return real_find(grey)

    with monkeypatch.context() as patch:
        patch.setattr(worker.crop, "find_quad", find_quad)
        assert run_tool(raw, out).code == 1
    assert state(out)["receipts"][0]["failed_stages"] == ["crop"]
    assert "crop" not in receipts(out)[0]

    result = run_tool(raw, out, "--no-crop")
    assert result.code == 0
    assert state(out)["receipts"][0]["failed_stages"] == ["crop"]
    assert "processing_failed" in receipts(out)[0]["flags"]

    result = run_tool(raw, out)
    assert result.code == 0
    assert state(out)["receipts"][0]["failed_stages"] == []
    assert [entry["part"] for entry in receipts(out)[0]["crop"]] == [2]


def test_derived_files_are_redone_after_a_conversion_that_failed_half_way(
    raw, out, run_tool, monkeypatch
):
    qr_and_table(raw)
    run_tool(raw, out)
    for part in (1, 2):
        (out / f"images/rcpt_000001_{part}.jpg").unlink()
    real_encode, real_replace = worker.imaging.encode_jpeg, os.replace

    def encode(image, quality=imaging.JPEG_QUALITY):
        # Another encoder version: same pixels, other bytes.
        return real_encode(image, quality - 5)

    def replace(source, target):
        if str(target).endswith("rcpt_000001_2.jpg"):
            raise OSError("synthetic")
        return real_replace(source, target)

    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "encode_jpeg", encode)
        patch.setattr("receipt_ingest.fsutil.os.replace", replace)
        result = run_tool(raw, out)
    assert result.code == 1
    assert "error: q/IMG_0002.jpg: OSError (convert)" in result.err
    assert state(out)["receipts"][0]["failed_stages"] == ["convert", "thumbs", "qr", "crop"]

    result = run_tool(raw, out)
    assert result.code == 0, result.err
    assert [r["failed_stages"] for r in state(out)["receipts"]] == [[], []]
    # The QR code of the first receipt is read again from its new image.
    assert "clahe_half: 1 /" in result.out
    assert receipts(out)[0]["qr_payload"] == TAX_URL


def test_images_take_their_place_only_when_every_part_passed(raw, out, run_tool, monkeypatch):
    shot(raw, "b/IMG_0001.jpg", 0)
    shot(raw, "b/IMG_0002.jpg", 2, image=receipt_on_table())
    monkeypatch.setattr(worker, "stage", with_a_trailer(lambda p: p.name == "rcpt_000001_2.jpg"))
    result = run_tool(raw, out)
    assert "error: b/IMG_0002.jpg: MetadataLeftError (convert)" in result.err
    # The first part passed the check but was never put in place, and no temporary file is left.
    assert sorted(path.name for path in (out / "images").iterdir()) == []
