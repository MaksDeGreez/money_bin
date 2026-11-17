import hashlib
import shutil
import stat

import pytest
from support import (
    OTHER_URL,
    TAX_URL,
    by_first_file,
    exif_bytes,
    page_with_qr,
    plain_image,
    receipt_on_table,
    receipts,
    shot,
    snapshot,
    state,
    write_heic,
    write_jpeg,
)

from receipt_ingest import pipeline, worker

KEY_ORDER = [
    "receipt_id",
    "batch",
    "seq_in_batch",
    "raw_files",
    "captured_at",
    "images",
    "fingerprint",
    "qr_payload",
    "qr",
    "qr_fields",
    "flags",
]


def two_batches(raw):
    """b1: receipts [1,2] and [3]; b2: [1] and [2,3,4,5] (too many parts)."""
    shot(raw, "b1/IMG_0001.jpg", 0)
    shot(raw, "b1/IMG_0002.jpg", 5)
    shot(raw, "b1/IMG_0003.jpg", 30)
    shot(raw, "b2/IMG_0001.jpg", 100)
    for index, seconds in enumerate((200, 203, 206, 209), start=2):
        shot(raw, f"b2/IMG_000{index}.jpg", seconds)


def ids(out):
    return {line["raw_files"][0]: line["receipt_id"] for line in receipts(out)}


def test_first_run(raw, out, run_tool):
    two_batches(raw)
    result = run_tool(raw, out)
    assert result.code == 0, result.err
    lines = receipts(out)
    assert [line["receipt_id"] for line in lines] == [f"rcpt_00000{i}" for i in range(1, 5)]
    assert [list(line) for line in lines] == [KEY_ORDER] * 4
    first = lines[0]
    assert first["batch"] == "b1"
    assert first["seq_in_batch"] == 1
    assert first["raw_files"] == ["b1/IMG_0001.jpg", "b1/IMG_0002.jpg"]
    assert first["captured_at"] == "2026-03-01T10:00:00.000+02:00"
    assert [image["file"] for image in first["images"]] == [
        "images/rcpt_000001_1.jpg",
        "images/rcpt_000001_2.jpg",
    ]
    for image in first["images"]:
        data = (out / image["file"]).read_bytes()
        assert image["sha256"] == hashlib.sha256(data).hexdigest()
        assert image["bytes"] == len(data)
        assert (image["width"], image["height"]) == (64, 48)
    assert lines[1]["seq_in_batch"] == 2
    assert lines[3]["flags"][:1] == ["too_many_parts"]
    assert len(lines[3]["images"]) == 4
    assert "no_qr" in first["flags"]
    assert "crop_failed" in first["flags"]
    assert "receipts" in result.out and "b1:" in result.out and "b2:" in result.out
    assert "4 new" in result.out
    assert "Written: 8 images, 0 crops, 8 thumbnails, 3 metadata files" in result.out
    html = (out / "groups_review.html").read_text(encoding="utf-8")
    assert "b1/IMG_0002.jpg" in html and "thumbs/rcpt_000004_4.jpg" in html
    assert "<script" not in html and "http" not in html


def test_fingerprint_matches_the_rails_rule():
    one = [{"sha256": "b" * 64}]
    assert pipeline.fingerprint(one) == "b" * 64
    two = [{"sha256": "b" * 64}, {"sha256": "a" * 64}]
    expected = hashlib.sha256(("a" * 64 + "b" * 64).encode()).hexdigest()
    assert pipeline.fingerprint(two) == expected
    assert pipeline.fingerprint(list(reversed(two))) == expected
    assert pipeline.fingerprint([]) is None


def test_fingerprint_in_the_output(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    for line in receipts(out):
        files = [out / image["file"] for image in line["images"]]
        digests = [hashlib.sha256(path.read_bytes()).hexdigest() for path in files]
        if len(digests) == 1:
            assert line["fingerprint"] == digests[0]
        else:
            joined = "".join(sorted(digests)).encode()
            assert line["fingerprint"] == hashlib.sha256(joined).hexdigest()


def test_file_modes(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    for path in [out, *out.rglob("*")]:
        mode = stat.S_IMODE(path.stat().st_mode)
        assert mode == (0o700 if path.is_dir() else 0o600), path


def test_second_identical_run_writes_nothing(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    before = snapshot(out)
    result = run_tool(raw, out)
    assert result.code == 0
    assert snapshot(out) == before
    assert "0 new, 4 unchanged, 0 rewritten" in result.out
    assert "Written: 0 images, 0 crops, 0 thumbnails, 0 metadata files; 0 files deleted" in (
        result.out
    )


def test_raw_folder_is_never_touched(raw, out, run_tool):
    two_batches(raw)
    (raw / ".DS_Store").write_bytes(b"finder")
    before = snapshot(raw)
    run_tool(raw, out)
    run_tool(raw, out, "--redo-qr", "--redo-crop")
    assert snapshot(raw) == before


def test_adding_a_batch_keeps_numbers(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    before = ids(out)
    shot(raw, "a0/IMG_0001.jpg", 1000)
    shot(raw, "c3/IMG_0001.jpg", 2000)
    result = run_tool(raw, out)
    after = ids(out)
    assert {name: after[name] for name in before} == before
    assert after["a0/IMG_0001.jpg"] == "rcpt_000005"
    assert after["c3/IMG_0001.jpg"] == "rcpt_000006"
    assert "2 new, 4 unchanged" in result.out


def test_merge_then_remove_the_override(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("merge: [[b1/IMG_0002.jpg, b1/IMG_0003.jpg]]\n")
    result = run_tool(raw, out)
    lines = by_first_file(out)
    merged = lines["b1/IMG_0001.jpg"]
    assert merged["receipt_id"] == "rcpt_000001"
    assert merged["raw_files"] == ["b1/IMG_0001.jpg", "b1/IMG_0002.jpg", "b1/IMG_0003.jpg"]
    assert "b1/IMG_0003.jpg" not in lines
    assert state(out)["retired"] == [
        {"receipt_id": "rcpt_000002", "key": state(out)["retired"][0]["key"], "reason": "merged"}
    ]
    assert not (out / "images/rcpt_000002_1.jpg").exists()
    assert not (out / "thumbs/rcpt_000002_1.jpg").exists()
    assert "1 rewritten" in result.out and "1 retired" in result.out

    (out / "groups_override.yaml").write_text("")
    result = run_tool(raw, out)
    assert ids(out) == {
        "b1/IMG_0001.jpg": "rcpt_000001",
        "b1/IMG_0003.jpg": "rcpt_000002",
        "b2/IMG_0001.jpg": "rcpt_000003",
        "b2/IMG_0002.jpg": "rcpt_000004",
    }
    assert state(out)["retired"] == []
    assert state(out)["next_id"] == 5
    assert "1 restored" in result.out
    assert not (out / "images/rcpt_000001_3.jpg").exists()


def test_split_gives_the_tail_a_new_number(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("split: [b2/IMG_0004.jpg]\n")
    run_tool(raw, out)
    lines = by_first_file(out)
    assert lines["b2/IMG_0002.jpg"]["receipt_id"] == "rcpt_000004"
    assert lines["b2/IMG_0002.jpg"]["raw_files"] == ["b2/IMG_0002.jpg", "b2/IMG_0003.jpg"]
    assert lines["b2/IMG_0004.jpg"]["receipt_id"] == "rcpt_000005"
    assert "too_many_parts" not in lines["b2/IMG_0002.jpg"]["flags"]
    assert not (out / "images/rcpt_000004_3.jpg").exists()
    assert lines["b2/IMG_0004.jpg"]["seq_in_batch"] == 3


def test_excluding_the_earliest_file_retires_the_number(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("exclude: [b1/IMG_0001.jpg]\n")
    result = run_tool(raw, out)
    lines = by_first_file(out)
    assert "b1/IMG_0001.jpg" not in lines
    assert lines["b1/IMG_0002.jpg"]["receipt_id"] == "rcpt_000005"
    assert [entry["reason"] for entry in state(out)["retired"]] == ["excluded"]
    assert state(out)["retired"][0]["receipt_id"] == "rcpt_000001"
    assert "Excluded: b1/IMG_0001.jpg" in (out / "groups_review.html").read_text()
    assert "1 new" in result.out


def test_excluding_a_whole_receipt(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    (out / "groups_override.yaml").write_text("exclude: [b1/IMG_0003.jpg]\n")
    run_tool(raw, out)
    assert "b1/IMG_0003.jpg" not in by_first_file(out)
    assert state(out)["retired"][0]["reason"] == "excluded"


def test_regrouping_by_gap_retires_the_old_number(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0)
    shot(raw, "b/IMG_0002.jpg", 5)
    run_tool(raw, out)
    (raw / "b/IMG_0001.jpg").unlink()
    run_tool(raw, out)
    assert state(out)["retired"][0]["reason"] == "regrouped"
    assert ids(out) == {"b/IMG_0002.jpg": "rcpt_000002"}


def test_renaming_a_file_and_a_batch_keeps_everything(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    images_before = snapshot(out / "images")
    (raw / "b1/IMG_0002.jpg").rename(raw / "b1/IMG_9002.jpg")
    (raw / "b2").rename(raw / "b9")
    result = run_tool(raw, out)
    lines = by_first_file(out)
    assert lines["b1/IMG_0001.jpg"]["raw_files"] == ["b1/IMG_0001.jpg", "b1/IMG_9002.jpg"]
    assert lines["b9/IMG_0001.jpg"]["receipt_id"] == "rcpt_000003"
    assert lines["b9/IMG_0001.jpg"]["batch"] == "b9"
    assert lines["b9/IMG_0002.jpg"]["receipt_id"] == "rcpt_000004"
    assert snapshot(out / "images") == images_before
    assert "Written: 0 images" in result.out


def test_duplicates_are_skipped_and_the_recorded_name_stays(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    shutil.copy(raw / "b1/IMG_0003.jpg", raw / "b0_copy.jpg")  # a file in the raw root
    (raw / "a_first").mkdir()
    shutil.copy(raw / "b1/IMG_0003.jpg", raw / "a_first/copy.jpg")
    result = run_tool(raw, out)
    assert ids(out)["b1/IMG_0003.jpg"] == "rcpt_000002"
    assert "1 duplicates, 1 non-images" in result.out
    assert "a_first/copy.jpg" not in (out / "receipts.jsonl").read_text()


def test_duplicates_on_a_first_run_keep_the_first_in_scan_order(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0)
    shutil.copy(raw / "b/IMG_0001.jpg", raw / "b/IMG_0001 copy.jpg")
    result = run_tool(raw, out)
    assert [line["raw_files"] for line in receipts(out)] == [["b/IMG_0001 copy.jpg"]]
    assert "1 duplicates" in result.out


def test_missing_raw_files_keep_their_receipts(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    shutil.rmtree(raw / "b2")
    result = run_tool(raw, out)
    lines = by_first_file(out)
    assert lines["b2/IMG_0001.jpg"]["flags"][0] == "raw_missing"
    assert (out / "images/rcpt_000004_4.jpg").exists()
    assert "2 raw missing" in result.out
    assert result.code == 0
    # The photos come back under another batch name: same numbers, flag gone, nothing re-encoded.
    images_before = snapshot(out / "images")
    two_batches(raw)
    shutil.rmtree(raw / "b1")
    (raw / "b2").rename(raw / "b5")
    result = run_tool(raw, out)
    lines = by_first_file(out)
    assert lines["b5/IMG_0001.jpg"]["receipt_id"] == "rcpt_000003"
    assert "raw_missing" not in lines["b5/IMG_0001.jpg"]["flags"]
    assert "raw_missing" in lines["b1/IMG_0001.jpg"]["flags"]
    assert snapshot(out / "images") == images_before


def test_partial_tax_url_fields(raw, out, run_tool):
    partial_url = TAX_URL.replace("&fn=4000000001", "")
    shot(raw, "q/IMG_0001.jpg", 0, image=page_with_qr(partial_url, size=(400, 520), scale=4))
    run_tool(raw, out)
    line = receipts(out)[0]
    assert line["qr"]["fn"] is None
    assert line["qr_fields"]["fiscal_number"] is None
    assert line["qr_fields"]["total"] == "12.30"
    assert "qr_fields_partial" in line["flags"]
    assert "no_qr" not in line["flags"]


def test_untimed_photo(raw, out, run_tool):
    write_jpeg(raw / "b/no_time.jpg", plain_image(), exif_bytes(None, None, None))
    write_jpeg(raw / "b/no_exif.jpg", plain_image(color=(1, 2, 3)))
    shot(raw, "b/timed.jpg", 0)
    run_tool(raw, out)
    lines = receipts(out)
    firsts = [line["raw_files"][0] for line in lines]
    assert firsts == ["b/timed.jpg", "b/no_exif.jpg", "b/no_time.jpg"]
    assert lines[1]["captured_at"] is None
    assert lines[1]["flags"][0] == "no_capture_time"


def qr_batch(raw):
    shot(raw, "q/IMG_0001.jpg", 0, image=page_with_qr(TAX_URL, size=(400, 520), scale=4))
    shot(raw, "q/IMG_0002.jpg", 60, image=page_with_qr(OTHER_URL, size=(400, 520), scale=4))
    shot(raw, "q/IMG_0003.jpg", 120, image=receipt_on_table())


def test_qr_and_crop(raw, out, run_tool):
    qr_batch(raw)
    result = run_tool(raw, out)
    tax, other, table = receipts(out)
    assert tax["qr_payload"] == TAX_URL
    assert tax["qr"]["fn"] == "4000000001"
    assert tax["qr_fields"] == {
        "issued_at": "2026-03-01T10:15:00+02:00",
        "total": "12.30",
        "fiscal_number": "4000000001",
        "receipt_number": "123456",
    }
    assert "no_qr" not in tax["flags"]
    assert other["qr_payload"] == OTHER_URL
    assert other["qr"] is None and other["qr_fields"] is None
    assert "qr_not_tax_url" in other["flags"]
    assert table["flags"] == ["no_qr"]
    crop = table["crop"][0]
    assert crop["file"] == "images/rcpt_000003_1_crop.jpg"
    assert crop["part"] == 1 and len(crop["quad"]) == 4
    assert abs(crop["width"] - 160) <= 8 and abs(crop["height"] - 480) <= 8
    assert (out / crop["file"]).stat().st_size == crop["bytes"]
    assert list(table)[-2:] == ["crop", "flags"]
    assert "QR 2 (66.7%), tax QR 1" in result.out
    review = (out / "groups_review.html").read_text()
    assert "QR: tax" in review and "QR: other" in review and "QR: none" in review
    assert TAX_URL not in review and OTHER_URL not in review

    again = run_tool(raw, out)
    assert "clahe_half: 0 / 0.0 s" in again.out
    before = snapshot(out)
    redo = run_tool(raw, out, "--redo-qr", "--redo-crop")
    assert "3 rewritten" in redo.out
    assert snapshot(out) == before  # same results, so nothing is rewritten on disk


def test_no_crop_keeps_existing_crops_and_makes_none(raw, out, run_tool, tmp_path):
    qr_batch(raw)
    run_tool(raw, out)
    run_tool(raw, out, "--no-crop")
    assert "crop" in receipts(out)[2]
    fresh = tmp_path / "fresh"
    run_tool(raw, fresh, "--no-crop")
    for line in receipts(fresh):
        assert "crop" not in line and "crop_failed" not in line["flags"]
    assert not list((fresh / "images").glob("*_crop.jpg"))


def test_console_output_has_no_payload_and_no_exif(raw, out, run_tool):
    qr_batch(raw)
    (raw / "q" / "broken.jpg").write_bytes(b"\xff\xd8 not really")
    results = [run_tool(raw, out), run_tool(raw, out, "--redo-qr")]
    for result in results:
        text = result.out + result.err
        for secret in (
            "cabinet",
            "tax.gov",
            "4000000001",
            "123456",
            "12.30",
            "20260301",
            "shop.example",
            "SyntheticCam",
            "2026",
            "10:00",
        ):
            assert secret not in text
    assert "skipped unreadable: q/broken.jpg (UnidentifiedImageError)" in results[0].err


def test_jobs_do_not_change_the_result(raw, tmp_path, run_tool):
    qr_batch(raw)
    shot(raw, "q/IMG_0004.jpg", 122)
    one, two = tmp_path / "one", tmp_path / "two"
    assert run_tool(raw, one).code == 0
    assert run_tool(raw, two, jobs="2").code == 0
    assert (one / "receipts.jsonl").read_bytes() == (two / "receipts.jsonl").read_bytes()
    assert (one / "groups_review.html").read_bytes() == (two / "groups_review.html").read_bytes()
    first = {k: v[0] for k, v in snapshot(one / "images").items()}
    assert first == {k: v[0] for k, v in snapshot(two / "images").items()}


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("exclude: [b1/IMG_0404.jpg]\n", "exclude[0]: 'b1/IMG_0404.jpg' is not a scanned raw file"),
        ("merge: [[b1/IMG_0001.jpg, b2/IMG_0001.jpg]]\n", "merge[0]: the files are in different"),
        ("regroup: []\n", "unknown key 'regroup'"),
    ],
)
def test_bad_override_file_stops_the_run(raw, out, run_tool, text, message):
    two_batches(raw)
    out.mkdir()
    (out / "groups_override.yaml").write_text(text)
    result = run_tool(raw, out)
    assert result.code == 2
    assert message in result.err
    assert not (out / "state.json").exists()


def test_a_photo_that_fails_to_decode(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0)
    good = raw / "b/IMG_0002.jpg"
    shot(raw, "b/IMG_0002.jpg", 60, image=plain_image((400, 300)))
    data = good.read_bytes()
    good.write_bytes(data[: len(data) // 2])  # the header reads, the pixels do not
    result = run_tool(raw, out)
    assert result.code == 1
    assert "error: b/IMG_0002.jpg: OSError" in result.err
    broken = receipts(out)[1]
    assert broken["flags"] == ["processing_failed"]
    assert broken["images"] == [] and broken["fingerprint"] is None
    assert not (out / "images/rcpt_000002_1.jpg").exists()
    # The whole file has other bytes, so it is another photo: a new number, the failed one retired.
    good.write_bytes(data)
    result = run_tool(raw, out)
    assert result.code == 0
    assert [line["receipt_id"] for line in receipts(out)] == ["rcpt_000001", "rcpt_000003"]
    assert state(out)["retired"][0]["reason"] == "failed"


def test_a_failed_receipt_is_tried_again(raw, out, run_tool, monkeypatch):
    two_batches(raw)

    def broken(data):
        raise MemoryError("synthetic")

    with monkeypatch.context() as patch:
        patch.setattr(worker.imaging, "decode_to_srgb", broken)
        result = run_tool(raw, out)
    assert result.code == 1
    assert result.err.count("MemoryError") == 4
    assert "synthetic" not in result.err
    assert "4 failed" in result.out
    assert not list((out / "images").iterdir())
    result = run_tool(raw, out)
    assert result.code == 0
    assert receipts(out)[0]["flags"] == ["no_qr", "crop_failed"]
    assert ids(out)["b2/IMG_0002.jpg"] == "rcpt_000004"
    assert "4 rewritten" in result.out


def test_damaged_output_is_repaired(raw, out, run_tool):
    two_batches(raw)
    run_tool(raw, out)
    image = out / "images/rcpt_000001_2.jpg"
    original = image.read_bytes()
    image.unlink()
    (out / "thumbs/rcpt_000002_1.jpg").write_bytes(b"short")
    (out / "images/.receipt-ingest-tmp-left").write_bytes(b"from a killed run")
    (out / "images/rcpt_000099_1.jpg").write_bytes(b"orphan")
    (out / "images/keep-me.txt").write_text("not ours")
    result = run_tool(raw, out)
    assert image.read_bytes() == original
    assert "Written: 1 images, 0 crops, 1 thumbnails, 0 metadata files; 1 files deleted" in (
        result.out
    )
    assert not (out / "images/.receipt-ingest-tmp-left").exists()
    assert (out / "images/keep-me.txt").exists()


@pytest.mark.parametrize("text", ["{not json", '{"format": 99}'])
def test_unusable_state_stops_the_run(raw, out, run_tool, text):
    shot(raw, "b/IMG_0001.jpg", 0)
    out.mkdir()
    (out / "state.json").write_text(text)
    result = run_tool(raw, out)
    assert result.code == 2
    assert "state.json" in result.err


def test_state_that_is_not_text(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0)
    out.mkdir()
    (out / "state.json").write_bytes(b"\xff\xfe\xfa")
    assert run_tool(raw, out).code == 2


def test_heic_input(raw, out, run_tool):
    import pillow_heif

    if not pillow_heif.libheif_info().get("HEIF"):
        pytest.skip("this libheif build has no HEIC encoder")
    write_heic(raw / "h/IMG_0001.HEIC", plain_image((40, 20)), exif_bytes(orientation=6))
    assert run_tool(raw, out).code == 0
    line = receipts(out)[0]
    assert line["captured_at"] == "2026-03-01T10:00:00.123+02:00"
    assert (line["images"][0]["width"], line["images"][0]["height"]) == (20, 40)


class TestRefusals:
    def test_inside_a_git_repository(self, tmp_path, raw, run_tool):
        (tmp_path / "repo" / ".git").mkdir(parents=True)
        out = tmp_path / "repo" / "not" / "yet" / "out"
        result = run_tool(raw, out)
        assert result.code == 2
        assert "inside a git repository" in result.err
        assert not (tmp_path / "repo" / "not").exists()

    def test_inside_a_linked_worktree(self, tmp_path, raw, run_tool):
        (tmp_path / "wt").mkdir()
        (tmp_path / "wt" / ".git").write_text("gitdir: elsewhere\n")
        assert run_tool(raw, tmp_path / "wt").code == 2

    def test_the_raw_folder_itself(self, raw, run_tool):
        result = run_tool(raw, raw)
        assert (result.code, "is the raw folder" in result.err) == (2, True)

    def test_inside_the_raw_folder(self, raw, run_tool):
        result = run_tool(raw, raw / "b1" / "out")
        assert (result.code, "inside the raw folder" in result.err) == (2, True)
        assert not (raw / "b1").exists()

    def test_containing_the_raw_folder(self, tmp_path, raw, run_tool):
        result = run_tool(raw, tmp_path)
        assert (result.code, "contains the raw folder" in result.err) == (2, True)

    def test_missing_raw_folder(self, tmp_path, run_tool):
        result = run_tool(tmp_path / "nope", tmp_path / "out")
        assert result.code == 2
        assert "raw folder does not exist" in result.err
