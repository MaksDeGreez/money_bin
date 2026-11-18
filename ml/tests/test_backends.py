import pytest
from fastapi.testclient import TestClient

from app.backends import BACKENDS, UnknownBackendError, create_backend
from app.backends.mlx import MlxBackend
from app.backends.openrouter import OpenRouterBackend
from app.backends.stub import StubBackend
from app.config import Settings
from app.main import create_app
from tests.conftest import ClientFactory, image_part


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


def test_health_works_for_an_unconfigured_openrouter_backend(
    make_client: ClientFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("OPENROUTER_OCR_MODEL", raising=False)
    response = make_client("openrouter").get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["backend"] == "openrouter"
    assert body["model_name"] == "not-configured"
    assert body["model_version"] == "not-started"


def test_an_unconfigured_openrouter_backend_answers_501(
    make_client: ClientFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("OPENROUTER_OCR_MODEL", raising=False)
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)

    response = make_client("openrouter").post("/ocr", files=[image_part()])

    assert response.status_code == 501
    error = response.json()["error"]
    assert error["code"] == "openrouter_model_missing"
    assert "OPENROUTER_OCR_MODEL" in error["message"]


def test_uploads_are_checked_before_the_backend(make_client: ClientFactory) -> None:
    response = make_client("openrouter").post(
        "/ocr", files=[image_part("a.txt", b"x", "text/plain")]
    )

    assert response.status_code == 415
