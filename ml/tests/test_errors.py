from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from tests.categorise_helpers import CATEGORIES


def test_unknown_path_uses_the_error_shape(client: TestClient) -> None:
    response = client.get("/does-not-exist")

    assert response.status_code == 404
    assert response.json() == {"error": {"code": "not_found", "message": "Not Found"}}


def test_wrong_method_uses_the_error_shape(client: TestClient) -> None:
    response = client.get("/ocr")

    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"
    assert response.headers["allow"] == "POST"


def test_unexpected_errors_use_the_error_shape_and_hide_details() -> None:
    app = create_app(Settings(ocr_backend="stub"))

    def broken(request: object) -> object:
        raise RuntimeError("secret internal detail")

    app.state.categoriser.categorise = broken
    client = TestClient(app, raise_server_exceptions=False)

    response = client.post("/categorise", json={"texts": ["milk"], "categories": CATEGORIES})

    assert response.status_code == 500
    assert response.json() == {
        "error": {"code": "internal_error", "message": "Internal server error."}
    }
