from fastapi.testclient import TestClient


def test_health_reports_the_stub_backend(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "backend": "stub",
        "model_name": "stub-ocr",
        "model_version": "0.1.0",
    }
