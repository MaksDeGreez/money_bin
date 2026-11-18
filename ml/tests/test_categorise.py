"""The `/categorise` contract, through the stub categoriser."""

from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.categorise import CATEGORISERS, UnknownCategoriserError, create_categoriser
from app.categorise.mlx import MlxCategoriser
from app.categorise.openrouter import OpenRouterCategoriser
from app.categorise.prompt import categories_version
from app.categorise.stub import StubCategoriser
from app.config import Settings
from app.main import create_app
from tests.categorise_helpers import CATEGORIES, OPTIONS, SLUGS
from tests.conftest import ClientFactory

TEXTS = ["Мол2,5%900г", "Квиток автобус", "Парацетамол №10", "А-95"]


def body(texts: list[str] | None = None, **extra: Any) -> dict[str, Any]:
    return {"texts": TEXTS if texts is None else texts, "categories": CATEGORIES, **extra}


def test_categorise_returns_up_to_three_sorted_candidates_per_text(client: TestClient) -> None:
    response = client.post("/categorise", json=body())

    assert response.status_code == 200
    answer = response.json()
    assert answer["backend"] == "stub"
    assert answer["model_name"] == "stub-categoriser"
    assert answer["model_version"] == "0.2.0"
    assert answer["score_kind"] == "stub"
    assert answer["calibrated"] is False
    assert answer["prompt_version"] is None
    assert answer["categories_version"] == categories_version(OPTIONS)
    assert answer["cost_usd"] is None
    assert isinstance(answer["elapsed_seconds"], str)
    for result in answer["results"]:
        candidates = result["candidates"]
        assert 1 <= len(candidates) <= 3
        scores = [candidate["score"] for candidate in candidates]
        assert scores == sorted(scores, reverse=True)
        assert all(0.0 <= score <= 1.0 for score in scores)
        assert sum(scores) <= 1.0 + 1e-9
        slugs = [candidate["category_slug"] for candidate in candidates]
        assert len(set(slugs)) == len(slugs)
        assert set(slugs) <= set(SLUGS)


def test_categorise_keeps_the_order_of_texts(client: TestClient) -> None:
    texts = [*TEXTS, TEXTS[0]]  # duplicates are allowed

    results = client.post("/categorise", json=body(texts)).json()["results"]

    assert [result["text"] for result in results] == texts


def test_categorise_is_deterministic(client: TestClient, make_client: ClientFactory) -> None:
    first = client.post("/categorise", json=body()).json()
    second = make_client("stub").post("/categorise", json=body(list(reversed(TEXTS)))).json()

    by_text = {result["text"]: result for result in second["results"]}
    for result in first["results"]:
        assert by_text[result["text"]] == result


def test_the_merchant_is_optional_and_accepted(client: TestClient) -> None:
    response = client.post("/categorise", json=body(merchant="Аптека Добробут"))

    assert response.status_code == 200


def test_categorise_accepts_two_hundred_texts(client: TestClient) -> None:
    response = client.post("/categorise", json=body([f"item {n}" for n in range(200)]))

    assert response.status_code == 200
    assert len(response.json()["results"]) == 200


@pytest.mark.parametrize(
    ("payload", "field"),
    [
        ({}, "texts"),
        ({"texts": []}, "texts"),
        ({"texts": [f"item {n}" for n in range(201)]}, "texts"),
        ({"texts": [""]}, "texts"),
        ({"texts": ["milk", "   "]}, "texts"),
        ({"texts": [42]}, "texts"),
        ({"texts": "milk"}, "texts"),
        ({"texts": ["x" * 301]}, "texts"),
        ({"merchant": "x" * 301}, "merchant"),
    ],
    ids=[
        "missing",
        "empty-list",
        "too-many",
        "empty-text",
        "blank-text",
        "not-a-string",
        "str",
        "too-long",
        "merchant-too-long",
    ],
)
def test_categorise_rejects_invalid_texts(
    client: TestClient, payload: dict[str, Any], field: str
) -> None:
    request = {"texts": ["milk"], "categories": CATEGORIES} | payload
    if payload == {}:
        del request["texts"]

    response = client.post("/categorise", json=request)

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert field in error["message"]


@pytest.mark.parametrize(
    "categories",
    [
        None,
        [],
        CATEGORIES[:1],
        [*CATEGORIES, CATEGORIES[0]],
        [{**CATEGORIES[0], "slug": "groceries"}],
        [{**CATEGORIES[0], "slug": "Groceries/Groceries"}, CATEGORIES[1]],
        [{**CATEGORIES[0], "name": "  "}, CATEGORIES[1]],
        [{**CATEGORIES[0], "group": ""}, CATEGORIES[1]],
        [{"slug": "a/b"}, CATEGORIES[1]],
        [CATEGORIES[0]] * 101,
    ],
    ids=[
        "missing",
        "empty",
        "one",
        "duplicate-slug",
        "a-group-slug",
        "upper-case",
        "blank-name",
        "blank-group",
        "no-name",
        "too-many",
    ],
)
def test_categorise_rejects_a_bad_category_list(client: TestClient, categories: Any) -> None:
    request: dict[str, Any] = {"texts": ["milk"]}
    if categories is not None:
        request["categories"] = categories

    response = client.post("/categorise", json=request)

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert "categories" in error["message"]


def test_categorise_rejects_a_body_that_is_not_json(client: TestClient) -> None:
    response = client.post(
        "/categorise", content=b"not json", headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_an_answer_outside_the_listed_categories_is_never_returned() -> None:
    app = create_app(Settings())

    class Rogue(StubCategoriser):
        def categorise(self, request: Any) -> Any:
            answer = super().categorise(request)
            first = answer.candidates[0][0]
            answer.candidates[0][0] = type(first)("made/up", first.score)
            return answer

    app.state.categoriser = Rogue()
    client = TestClient(app, raise_server_exceptions=False)

    response = client.post("/categorise", json=body())

    assert response.status_code == 500
    assert response.json()["error"]["code"] == "internal_error"


def test_an_answer_with_too_few_items_is_never_returned() -> None:
    app = create_app(Settings())

    class Short(StubCategoriser):
        def categorise(self, request: Any) -> Any:
            answer = super().categorise(request)
            return type(answer)(answer.candidates[:-1], answer.score_kind, None)

    app.state.categoriser = Short()
    client = TestClient(app, raise_server_exceptions=False)

    assert client.post("/categorise", json=body()).status_code == 500


def test_texts_and_the_merchant_reach_the_categoriser_on_one_line_each() -> None:
    seen: list[Any] = []

    class Spy(StubCategoriser):
        def categorise(self, request: Any) -> Any:
            seen.append(request)
            return super().categorise(request)

    app = create_app(Settings(), categoriser=Spy())
    with TestClient(app) as client:
        client.post(
            "/categorise",
            json=body(["Мол\n2,5%  900г", "Хліб"], merchant="  Магазин\nКуток "),
        )

    assert seen[0].texts == ("Мол 2,5% 900г", "Хліб")
    assert seen[0].merchant == "Магазин Куток"
    assert [option.slug for option in seen[0].categories] == SLUGS


def test_registry_lists_every_categoriser() -> None:
    assert {
        "stub": StubCategoriser,
        "mlx": MlxCategoriser,
        "openrouter": OpenRouterCategoriser,
    } == CATEGORISERS


@pytest.mark.parametrize("name", ["stub", "mlx", "openrouter", " MLX "])
def test_create_categoriser_accepts_valid_names(name: str) -> None:
    assert create_categoriser(name).name == name.strip().lower()


def test_an_unknown_categoriser_stops_the_app() -> None:
    with pytest.raises(UnknownCategoriserError, match="mlx, openrouter, stub"):
        create_app(Settings(categorise_backend="nope"))


def test_the_categoriser_is_chosen_apart_from_the_ocr_backend(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("OCR_BACKEND", "openrouter")
    monkeypatch.setenv("CATEGORISE_BACKEND", "stub")

    health = TestClient(create_app()).get("/health").json()

    assert health["backend"] == "openrouter"
    assert health["categoriser"]["backend"] == "stub"
    assert Settings().categorise_backend == "stub"
