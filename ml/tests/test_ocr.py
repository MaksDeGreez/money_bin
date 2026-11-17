from collections.abc import Sequence
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from app.backends import ImageInput
from app.backends.stub import stub_receipt
from app.config import Settings
from app.main import create_app
from app.schemas import Receipt
from tests.conftest import PNG_BYTES, image_part


def test_ocr_returns_the_stub_receipt(client: TestClient) -> None:
    response = client.post("/ocr", files=[image_part()])

    assert response.status_code == 200
    body = response.json()
    assert body["backend"] == "stub"
    assert body["model_name"] == "stub-ocr"
    assert body["model_version"] == "0.1.0"
    receipt = body["receipt"]
    assert receipt["merchant"] == "Example Market"
    assert receipt["fiscal_number"] == "0000000000"
    assert receipt["receipt_number"] == "000123"
    assert receipt["issued_at"] == "2026-01-15T12:34:00+02:00"
    assert receipt["total"] == "123.45"
    assert receipt["currency"] == "UAH"
    assert len(receipt["items"]) == 3


def test_ocr_writes_money_and_quantity_as_decimal_strings(client: TestClient) -> None:
    receipt = client.post("/ocr", files=[image_part()]).json()["receipt"]

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
    ("filename", "content_type"),
    [
        ("receipt.jpg", "image/jpeg"),
        ("receipt.png", "image/png"),
        ("receipt.webp", "image/webp"),
        ("receipt.heic", "image/heic"),
        ("receipt.jpg", "IMAGE/JPEG; charset=binary"),
    ],
)
def test_ocr_accepts_every_allowed_image_type(
    client: TestClient, filename: str, content_type: str
) -> None:
    response = client.post("/ocr", files=[image_part(filename, PNG_BYTES, content_type)])

    assert response.status_code == 200


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

    def spy(images: Sequence[ImageInput]) -> Receipt:
        seen.extend(images)
        return stub_receipt()

    app.state.backend.extract_receipt = spy
    client = TestClient(app)
    files = [image_part("a.png"), image_part("b.jpg", b"\xff\xd8\xff", "image/jpeg")]

    assert client.post("/ocr", files=files).status_code == 200
    assert [(image.filename, image.content_type, image.content) for image in seen] == [
        ("a.png", "image/png", PNG_BYTES),
        ("b.jpg", "image/jpeg", b"\xff\xd8\xff"),
    ]
