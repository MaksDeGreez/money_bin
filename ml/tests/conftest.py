"""Shared test helpers. Image bytes are built in memory; the stub never decodes them."""

from collections.abc import Callable

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

# The first bytes of a PNG file. Enough for an upload; nothing reads the pixels.
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8

ClientFactory = Callable[[str], TestClient]


def image_part(
    name: str = "receipt.png", content: bytes = PNG_BYTES, content_type: str = "image/png"
) -> tuple[str, tuple[str, bytes, str]]:
    """One `images` part for a multipart request."""
    return ("images", (name, content, content_type))


@pytest.fixture
def make_client() -> ClientFactory:
    """Build a test client for the backend with the given name."""

    def factory(backend: str) -> TestClient:
        return TestClient(create_app(Settings(ocr_backend=backend)))

    return factory


@pytest.fixture
def client(make_client: ClientFactory) -> TestClient:
    return make_client("stub")
