import hashlib
import os

import pytest
from PIL import Image
from support import BASE_TIME, exif_bytes, plain_image, write_jpeg

from receipt_ingest import scan


def exif_of(data: bytes) -> Image.Exif:
    exif = Image.Exif()
    exif.load(data[len(b"Exif\x00\x00") :])
    return exif


def test_capture_time_with_offset_and_subseconds():
    when, text = scan.capture_time(exif_of(exif_bytes(BASE_TIME, "05", "-04:30")))
    assert text == "2026-03-01T10:00:00.05-04:30"
    assert when.microsecond == 50000
    assert when.utcoffset().total_seconds() == -4.5 * 3600


def test_capture_time_without_offset_is_kyiv_time():
    _, winter_text = scan.capture_time(exif_of(exif_bytes(BASE_TIME, None, None)))
    assert winter_text == "2026-03-01T10:00:00+02:00"
    summer, summer_text = scan.capture_time(
        exif_of(exif_bytes(BASE_TIME.replace(month=7), "9", None))
    )
    assert summer_text == "2026-07-01T10:00:00.9+03:00"
    assert summer.microsecond == 900000


def test_no_capture_time():
    assert scan.capture_time(exif_of(exif_bytes(None, None, None))) == (None, None)
    assert scan.capture_time(Image.Exif()) == (None, None)


def test_bad_capture_time_counts_as_none():
    exif = Image.Exif()
    exif.get_ifd(0x8769)[36867] = "not a date"
    assert scan.capture_time(exif) == (None, None)


def test_bytes_values_are_read():
    exif = Image.Exif()
    exif.get_ifd(0x8769)[36867] = b"2026:03:01 10:00:00\x00"
    assert scan.capture_time(exif)[1] == "2026-03-01T10:00:00+02:00"


def test_only_ascii_digits_count_in_the_offset():
    exif = Image.Exif()
    exif.get_ifd(0x8769)[36867] = "2026:03:01 10:00:00"
    exif.get_ifd(0x8769)[36881] = "+\u0660\u0665:\u0660\u0660"  # Arabic-Indic digits
    assert scan.capture_time(exif)[1] == "2026-03-01T10:00:00+02:00"


def test_probe_hashes_and_never_writes(tmp_path):
    path = write_jpeg(tmp_path / "a.jpg", plain_image(), exif_bytes())
    before = (path.read_bytes(), path.stat().st_mtime_ns)
    probed = scan.probe(path, "x/a.jpg")
    assert probed.sha256 == hashlib.sha256(before[0]).hexdigest()
    assert probed.captured_text == "2026-03-01T10:00:00.123+02:00"
    assert (path.read_bytes(), path.stat().st_mtime_ns) == before


def test_probe_reports_the_error_class_only(tmp_path):
    path = tmp_path / "broken.jpg"
    path.write_bytes(b"not an image at all")
    probed = scan.probe(path, "x/broken.jpg")
    assert probed.error == "UnidentifiedImageError"
    assert probed.sha256 is None


def test_list_candidates(tmp_path):
    raw = tmp_path / "raw"
    write_jpeg(raw / "b2" / "nested" / "deep.JPEG")
    write_jpeg(raw / "b1" / "a.jpg")
    (raw / "b1" / "photo.HEIC").write_bytes(b"x")
    (raw / "b1" / "photo.heif").write_bytes(b"x")
    (raw / "b1" / "notes.txt").write_text("x")
    (raw / "b1" / ".hidden.jpg").write_bytes(b"x")
    (raw / "b1" / ".cache").mkdir()
    (raw / "b1" / ".cache" / "c.jpg").write_bytes(b"x")
    (raw / ".DS_Store").write_bytes(b"x")
    (raw / "top.jpg").write_bytes(b"x")
    (raw / ".hidden_batch").mkdir()
    os.symlink(raw / "b1" / "a.jpg", raw / "b1" / "link.jpg")
    os.symlink(raw / "b2", raw / "b1" / "linked_dir")
    os.symlink(raw / "b2", raw / "b3")
    found = scan.list_candidates(raw)
    assert found.batches == ["b1", "b2"]
    assert sorted(name for _, name, _ in found.files) == [
        "b1/a.jpg",
        "b1/photo.HEIC",
        "b1/photo.heif",
        "b2/nested/deep.JPEG",
    ]
    # notes, .hidden.jpg, .cache/c.jpg, .DS_Store, top.jpg, .hidden_batch, two symlinks, b3
    assert found.non_images == 9
    assert found.unreadable_folders == []


@pytest.mark.skipif(os.geteuid() == 0, reason="root can list any folder")
def test_a_folder_that_cannot_be_listed_is_reported(tmp_path):
    raw = tmp_path / "raw"
    write_jpeg(raw / "b1" / "a.jpg")
    locked = raw / "b1" / "locked"
    write_jpeg(locked / "hidden_receipt.jpg")
    locked.chmod(0)
    try:
        found = scan.list_candidates(raw)
    finally:
        locked.chmod(0o700)
    assert [name for _, name, _ in found.files] == ["b1/a.jpg"]
    assert found.unreadable_folders == [("b1/locked", "PermissionError")]


def test_order_files_puts_untimed_last(tmp_path):
    def raw_file(name, seconds):
        when = None
        if seconds is not None:
            when = scan.capture_time(exif_of(exif_bytes(BASE_TIME.replace(second=seconds))))[0]
        return scan.RawFile(name, name.split("/")[0], tmp_path, "s", when, None)

    ordered = scan.order_files(
        [
            raw_file("b/c", None),
            raw_file("b/z", 1),
            raw_file("b/a", None),
            raw_file("a/q", 9),
            raw_file("b/y", 1),
        ]
    )
    assert [item.name for item in ordered] == ["a/q", "b/y", "b/z", "b/a", "b/c"]
    assert [item.order for item in ordered] == [0, 1, 2, 3, 4]
