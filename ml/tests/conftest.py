"""Shared test helpers. Image bytes are built in memory; the stub never decodes them.

The service checks each file's signature (its first bytes) against the declared
type, so every test image starts with the real signature of its type.
"""

from collections.abc import Callable, Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

# The first bytes of each allowed type. Enough for an upload; nothing reads the pixels.
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8
JPEG_BYTES = b"\xff\xd8\xff\xe0" + b"\x00" * 12
WEBP_BYTES = b"RIFF\x10\x00\x00\x00WEBPVP8 " + b"\x00" * 4
HEIC_BYTES = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic"

ClientFactory = Callable[..., TestClient]

# Settings of the hosted backend. A developer's shell may export them; no test may
# see a real key or model id.
OPENROUTER_VARIABLES = (
    "OPENROUTER_API_KEY",
    "OPENROUTER_OCR_MODEL",
    "OPENROUTER_CATEGORISE_MODEL",
    "OPENROUTER_TIMEOUT",
    "OPENROUTER_MAX_TOKENS",
    "OPENROUTER_OCR_IMAGE_MAX_SIDE",
    "OPENROUTER_STRUCTURED_OUTPUT",
    "OCR_BACKEND",
    "CATEGORISE_BACKEND",
    "MLX_CATEGORISE_MODEL",
    "CATEGORISE_CALIBRATION_FILE",
)


@pytest.fixture(autouse=True)
def no_network(monkeypatch: pytest.MonkeyPatch) -> None:
    """No test may reach the network: every socket connect and name lookup fails."""
    import socket

    def refuse(*args: Any, **kwargs: Any) -> Any:
        raise OSError("tests must not use the network")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket.socket, "connect_ex", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)


@pytest.fixture(autouse=True)
def no_hosted_settings(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in OPENROUTER_VARIABLES:
        monkeypatch.delenv(name, raising=False)


@pytest.fixture(autouse=True)
def no_openrouter_halt() -> Iterator[None]:
    """A halt after a wrong provider lasts until the service restarts; each test is a restart."""
    from app.backends.openrouter import reset_halt

    reset_halt()
    yield
    reset_halt()


def image_part(
    name: str = "receipt.png", content: bytes = PNG_BYTES, content_type: str = "image/png"
) -> tuple[str, tuple[str, bytes, str]]:
    """One `images` part for a multipart request."""
    return ("images", (name, content, content_type))


@pytest.fixture
def make_client() -> ClientFactory:
    """Build a test client for the backend with the given name."""

    def factory(backend: str, **settings: Any) -> TestClient:
        return TestClient(create_app(Settings(ocr_backend=backend, **settings)))

    return factory


@pytest.fixture
def client(make_client: ClientFactory) -> TestClient:
    return make_client("stub")


def encoded_image(
    width: int = 64,
    height: int = 32,
    image_format: str = "JPEG",
    orientation: int | None = None,
) -> bytes:
    """A real, decodable image of one colour (no receipt content)."""
    from io import BytesIO

    import pillow_heif
    from PIL import Image

    image = Image.new("RGB", (width, height), "white")
    buffer = BytesIO()
    if image_format == "HEIF":
        pillow_heif.from_pillow(image).save(buffer, quality=50)
        return buffer.getvalue()
    options = {}
    if orientation is not None:
        exif = Image.Exif()
        exif[0x0112] = orientation
        options["exif"] = exif
    image.save(buffer, image_format, **options)
    return buffer.getvalue()
