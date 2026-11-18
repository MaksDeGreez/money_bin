from fastapi.testclient import TestClient


def test_health_reports_the_stub_backends(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "backend": "stub",
        "model_name": "stub-ocr",
        "model_version": "0.1.0",
        "categoriser": {
            "backend": "stub",
            "model_name": "stub-categoriser",
            "model_version": "0.2.0",
            "calibration": False,
        },
    }
