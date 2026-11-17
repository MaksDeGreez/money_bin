"""A failure in one stage never costs good images, and the failed stage is tried again."""

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
    real_write = worker.write_if_changed

    def write_with_a_trailer(path, data):
        # Something between the encoder and the disk adds bytes the in-memory check never saw.
        if path.name == "rcpt_000001_1.jpg" or path.name.endswith("_crop.jpg"):
            data = data + b"trailer"
        return real_write(path, data)

    monkeypatch.setattr(worker, "write_if_changed", write_with_a_trailer)
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
    monkeypatch.setattr(worker, "write_if_changed", lambda path, d: path.write_bytes(d + b"x"))
    with pytest.raises(imaging.MetadataLeftError):
        receipt.write("thumbs/rcpt_000001_1.jpg", data)
    assert not (tmp_path / "thumbs/rcpt_000001_1.jpg").exists()
