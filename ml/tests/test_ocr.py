import asyncio
import io
from collections.abc import Sequence
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from starlette.datastructures import Headers, UploadFile

from app.backends import Extraction, ImageInput
from app.backends.stub import stub_receipt
from app.config import DEFAULT_MAX_IMAGE_BYTES, Settings
from app.errors import ApiError
from app.main import _read_images, create_app, detect_image_type
from tests.conftest import (
    HEIC_BYTES,
    JPEG_BYTES,
    PNG_BYTES,
    WEBP_BYTES,
    ClientFactory,
    image_part,
)


def test_ocr_returns_the_stub_receipt(client: TestClient) -> None:
    response = client.post("/ocr", files=[image_part()])

    assert response.status_code == 200
    body = response.json()
    assert body["backend"] == "stub"
    assert body["model_name"] == "stub-ocr"
    assert body["model_version"] == "0.1.0"
    assert body["prompt_version"] is None
    assert body["repaired"] is False
    assert Decimal(body["elapsed_seconds"]) >= 0
    receipt = body["receipt"]
    assert receipt["kind"] == "fiscal"
    assert receipt["card_last4"] is None
    assert receipt["sum_matches_total"] is True
    assert receipt["merchant"] == "Example Market"
    assert receipt["fiscal_number"] == "0000000000"
    assert receipt["receipt_number"] == "000123"
    assert receipt["issued_at"] == "2026-01-15T12:34:00+02:00"
    assert receipt["total"] == "123.45"
    assert receipt["currency"] == "UAH"
    assert len(receipt["items"]) == 3


def test_ocr_writes_money_and_quantity_as_decimal_strings(client: TestClient) -> None:
    body = client.post("/ocr", files=[image_part()]).json()
    receipt = body["receipt"]

    assert isinstance(body["elapsed_seconds"], str)
    assert isinstance(receipt["total"], str)
    for item in receipt["items"]:
        for field in ("quantity", "unit_price", "amount", "discount"):
            assert isinstance(item[field], str), field
            Decimal(item[field])  # parses without error


def test_stub_item_amounts_add_up_to_the_total(client: TestClient) -> None:
    receipt = client.post("/ocr", files=[image_part()]).json()["receipt"]
    items = receipt["items"]

    assert sum(Decimal(item["amount"]) for item in items) == Decimal(receipt["total"])
    for item in items:
        gross = Decimal(item["quantity"]) * Decimal(item["unit_price"])
        expected = gross.quantize(Decimal("0.01")) - Decimal(item["discount"])
        assert Decimal(item["amount"]) == expected, item["name"]


@pytest.mark.parametrize(
    ("filename", "content", "content_type"),
    [
        ("receipt.jpg", JPEG_BYTES, "image/jpeg"),
        ("receipt.png", PNG_BYTES, "image/png"),
        ("receipt.webp", WEBP_BYTES, "image/webp"),
        ("receipt.heic", HEIC_BYTES, "image/heic"),
        ("receipt.jpg", JPEG_BYTES, "IMAGE/JPEG; charset=binary"),
    ],
)
def test_ocr_accepts_every_allowed_image_type(
    client: TestClient, filename: str, content: bytes, content_type: str
) -> None:
    response = client.post("/ocr", files=[image_part(filename, content, content_type)])

    assert response.status_code == 200


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (JPEG_BYTES, "image/jpeg"),
        (PNG_BYTES, "image/png"),
        (WEBP_BYTES, "image/webp"),
        (HEIC_BYTES, "image/heic"),
        (b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00", "image/heic"),
        (b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00", None),
        (b"RIFF\x10\x00\x00\x00WAVEfmt ", None),
        (b"GIF89a", None),
        (b"%PDF-1.7", None),
        (b"\xff\xd8", None),
    ],
)
def test_detect_image_type_reads_the_file_signature(content: bytes, expected: str | None) -> None:
    assert detect_image_type(content) == expected


@pytest.mark.parametrize(
    ("content", "content_type"),
    [
        (PNG_BYTES, "image/jpeg"),
        (JPEG_BYTES, "image/png"),
        (b"%PDF-1.7 not an image", "image/png"),
        (b"<svg xmlns='http://www.w3.org/2000/svg'/>", "image/webp"),
        (b"plain text", "image/heic"),
    ],
)
def test_ocr_refuses_content_that_does_not_match_its_type(
    client: TestClient, content: bytes, content_type: str
) -> None:
    response = client.post("/ocr", files=[image_part("receipt.img", content, content_type)])

    assert response.status_code == 415
    error = response.json()["error"]
    assert error["code"] == "unsupported_media_type"
    assert "its content is not an image of that type" in error["message"]


def test_ocr_refuses_a_file_over_the_size_limit(make_client: ClientFactory) -> None:
    client = make_client("stub", ml_max_image_bytes=len(PNG_BYTES))
    too_big = PNG_BYTES + b"\x00"

    response = client.post("/ocr", files=[image_part(), image_part("big.png", too_big)])

    assert response.status_code == 413
    assert response.json() == {
        "error": {
            "code": "image_too_large",
            "message": f"File 'big.png' is larger than the limit of {len(PNG_BYTES)} bytes.",
        }
    }


def test_ocr_accepts_a_file_exactly_at_the_size_limit(make_client: ClientFactory) -> None:
    client = make_client("stub", ml_max_image_bytes=len(PNG_BYTES))

    assert client.post("/ocr", files=[image_part()]).status_code == 200


def test_the_size_limit_is_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    assert Settings().ml_max_image_bytes == DEFAULT_MAX_IMAGE_BYTES == 15 * 1024 * 1024

    monkeypatch.setenv("ML_MAX_IMAGE_BYTES", "1024")
    assert Settings().ml_max_image_bytes == 1024

    monkeypatch.setenv("ML_MAX_IMAGE_BYTES", "0")
    with pytest.raises(ValueError, match="greater than 0"):
        Settings()


def test_an_oversized_file_is_refused_without_being_read(
    make_client: ClientFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    reads: list[int] = []
    original = UploadFile.read

    async def counting_read(self: UploadFile, size: int = -1) -> bytes:
        reads.append(size)
        return await original(self, size)

    monkeypatch.setattr(UploadFile, "read", counting_read)
    client = make_client("stub", ml_max_image_bytes=8)

    response = client.post("/ocr", files=[image_part("big.png", PNG_BYTES * 100)])

    assert response.status_code == 413
    assert reads == []


def test_ocr_accepts_three_images(client: TestClient) -> None:
    files = [image_part(f"page-{n}.png") for n in range(3)]

    assert client.post("/ocr", files=files).status_code == 200


def test_ocr_without_images_is_422(client: TestClient) -> None:
    response = client.post("/ocr", data={"note": "no files here"})

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert "images" in error["message"]


def test_ocr_with_more_than_three_images_is_422(client: TestClient) -> None:
    files = [image_part(f"page-{n}.png") for n in range(4)]

    response = client.post("/ocr", files=files)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "too_many_images"


@pytest.mark.parametrize("content_type", ["application/pdf", "text/plain", "image/gif"])
def test_ocr_with_a_wrong_content_type_is_415(client: TestClient, content_type: str) -> None:
    response = client.post("/ocr", files=[image_part("receipt.bin", b"data", content_type)])

    assert response.status_code == 415
    error = response.json()["error"]
    assert error["code"] == "unsupported_media_type"
    assert content_type in error["message"]


def test_ocr_rejects_a_bad_file_among_good_ones(client: TestClient) -> None:
    files = [image_part(), image_part("notes.txt", b"text", "text/plain")]

    assert client.post("/ocr", files=files).status_code == 415


def test_ocr_with_an_empty_file_is_422(client: TestClient) -> None:
    response = client.post("/ocr", files=[image_part("empty.png", b"")])

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "empty_image"


def test_ocr_passes_the_images_to_the_backend() -> None:
    app = create_app(Settings(ocr_backend="stub"))
    seen: list[ImageInput] = []

    def spy(images: Sequence[ImageInput]) -> Extraction:
        seen.extend(images)
        return Extraction(receipt=stub_receipt())

    app.state.backend.extract_receipt = spy
    client = TestClient(app)
    files = [image_part("a.png"), image_part("b.jpg", b"\xff\xd8\xff", "image/jpeg")]

    assert client.post("/ocr", files=files).status_code == 200
    assert [(image.filename, image.content_type, image.content) for image in seen] == [
        ("a.png", "image/png", PNG_BYTES),
        ("b.jpg", "image/jpeg", b"\xff\xd8\xff"),
    ]


def test_a_file_of_unknown_size_is_read_only_up_to_the_limit() -> None:
    upload = UploadFile(
        io.BytesIO(PNG_BYTES * 100),
        filename="big.png",
        headers=Headers({"content-type": "image/png"}),
    )
    assert upload.size is None

    with pytest.raises(ApiError) as raised:
        asyncio.run(_read_images([upload], max_bytes=len(PNG_BYTES)))

    assert raised.value.status_code == 413
    assert raised.value.code == "image_too_large"
    assert upload.file.tell() == len(PNG_BYTES) + 1
