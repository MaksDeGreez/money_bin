from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.backends.stub import STUB_CATEGORY_SLUGS
from tests.conftest import ClientFactory

TEXTS = ["milk 2.5% 900g", "bus ticket", "pain relief tablets", "petrol 95"]


def test_categorise_returns_three_sorted_candidates_per_text(client: TestClient) -> None:
    response = client.post("/categorise", json={"texts": TEXTS})

    assert response.status_code == 200
    body = response.json()
    assert body["backend"] == "stub"
    assert body["model_name"] == "stub-categoriser"
    assert body["model_version"] == "0.1.0"
    for result in body["results"]:
        candidates = result["candidates"]
        assert len(candidates) == 3
        scores = [candidate["score"] for candidate in candidates]
        assert scores == sorted(scores, reverse=True)
        assert all(0.0 <= score <= 1.0 for score in scores)
        assert sum(scores) <= 1.0 + 1e-9
        slugs = [candidate["category_slug"] for candidate in candidates]
        assert len(set(slugs)) == 3
        assert set(slugs) <= set(STUB_CATEGORY_SLUGS)


def test_categorise_keeps_the_order_of_texts(client: TestClient) -> None:
    texts = [*TEXTS, "milk 2.5% 900g"]  # duplicates are allowed

    results = client.post("/categorise", json={"texts": texts}).json()["results"]

    assert [result["text"] for result in results] == texts


def test_categorise_is_deterministic(client: TestClient, make_client: ClientFactory) -> None:
    first = client.post("/categorise", json={"texts": TEXTS}).json()
    second = make_client("stub").post("/categorise", json={"texts": list(reversed(TEXTS))}).json()

    by_text = {result["text"]: result for result in second["results"]}
    for result in first["results"]:
        assert by_text[result["text"]] == result


def test_categorise_accepts_two_hundred_texts(client: TestClient) -> None:
    texts = [f"item {n}" for n in range(200)]

    response = client.post("/categorise", json={"texts": texts})

    assert response.status_code == 200
    assert len(response.json()["results"]) == 200


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"texts": []},
        {"texts": [f"item {n}" for n in range(201)]},
        {"texts": [""]},
        {"texts": ["milk", "   "]},
        {"texts": [42]},
        {"texts": "milk"},
    ],
    ids=["missing", "empty-list", "too-many", "empty-text", "blank-text", "not-a-string", "str"],
)
def test_categorise_rejects_invalid_input(client: TestClient, payload: dict[str, Any]) -> None:
    response = client.post("/categorise", json=payload)

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert "texts" in error["message"]


def test_categorise_rejects_a_body_that_is_not_json(client: TestClient) -> None:
    response = client.post(
        "/categorise", content=b"not json", headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
