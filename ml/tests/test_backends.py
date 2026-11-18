import pytest
from fastapi.testclient import TestClient

from app.backends import BACKENDS, UnknownBackendError, create_backend
from app.backends.mlx import MlxBackend
from app.backends.openrouter import OpenRouterBackend
from app.backends.stub import StubBackend
from app.config import Settings
from app.main import create_app
from tests.conftest import ClientFactory, image_part

PLACEHOLDERS = ["openrouter"]


def test_registry_lists_every_backend() -> None:
    expected = {"stub": StubBackend, "mlx": MlxBackend, "openrouter": OpenRouterBackend}

    assert expected == BACKENDS


@pytest.mark.parametrize("name", ["stub", "mlx", "openrouter", " MLX ", "Stub"])
def test_create_backend_accepts_valid_names(name: str) -> None:
    backend = create_backend(name)

    assert backend.name == name.strip().lower()


def test_create_backend_passes_the_settings_on() -> None:
    settings = Settings(mlx_ocr_model="example/model")

    backend = create_backend("mlx", settings)

    assert backend.settings is settings
    assert backend.model_name == "example/model"


def test_create_backend_rejects_an_unknown_name_and_lists_valid_names() -> None:
    with pytest.raises(UnknownBackendError) as error:
        create_backend("nope")

    message = str(error.value)
    assert "'nope'" in message
    assert "mlx, openrouter, stub" in message


def test_the_app_fails_fast_on_an_unknown_backend() -> None:
    with pytest.raises(UnknownBackendError, match="Valid names"):
        create_app(Settings(ocr_backend="nope"))


def test_stub_is_the_default_backend(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OCR_BACKEND", raising=False)

    assert Settings().ocr_backend == "stub"
    assert TestClient(create_app()).get("/health").json()["backend"] == "stub"


def test_the_backend_is_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OCR_BACKEND", "openrouter")

    assert TestClient(create_app()).get("/health").json()["backend"] == "openrouter"


@pytest.mark.parametrize("name", PLACEHOLDERS)
def test_health_works_for_placeholders(make_client: ClientFactory, name: str) -> None:
    response = make_client(name).get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["backend"] == name
    assert body["model_name"] == f"{name}-placeholder"
    assert body["model_version"] == "0.0.0"


@pytest.mark.parametrize("name", PLACEHOLDERS)
def test_placeholder_ocr_is_501(make_client: ClientFactory, name: str) -> None:
    response = make_client(name).post("/ocr", files=[image_part()])

    assert response.status_code == 501
    error = response.json()["error"]
    assert error["code"] == "backend_not_implemented"
    assert name in error["message"]


@pytest.mark.parametrize("name", ["openrouter", "mlx"])
def test_placeholder_categorise_is_501(make_client: ClientFactory, name: str) -> None:
    response = make_client(name).post("/categorise", json={"texts": ["milk"]})

    assert response.status_code == 501
    assert response.json()["error"]["code"] == "backend_not_implemented"


@pytest.mark.parametrize("name", PLACEHOLDERS)
def test_placeholders_still_validate_uploads_first(make_client: ClientFactory, name: str) -> None:
    response = make_client(name).post("/ocr", files=[image_part("a.txt", b"x", "text/plain")])

    assert response.status_code == 415
