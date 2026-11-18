"""`/categorise/transaction`: the served transaction categoriser over HTTP.

Every test here runs with the network refused (`conftest.no_network`): the endpoint, the artefact
and the encoder never need it.
"""

from __future__ import annotations

import ast
import re
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import yaml
from fastapi.testclient import TestClient

from app import transactions
from app.config import Settings
from app.main import create_app
from app.transactions import TransactionCategoriser
from categoriser.dataset import build_rows
from categoriser.export import load_export
from categoriser.serving import fit_artefact
from categoriser.taxonomy import DEFAULT_TAXONOMY, load_taxonomy
from tests.categoriser_export import write_export
from tests.categoriser_fakes import FakeEncoder
from tests.conftest import PNG_BYTES
from tests.test_categoriser_serving import HYBRID


def _slug(text: str) -> str:
    """A slug for the test's category list (the app builds the real ones; Python never does)."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def categories() -> list[dict[str, str]]:
    document = yaml.safe_load(DEFAULT_TAXONOMY.read_text())
    return [
        {
            "slug": f"{_slug(group['group'])}/{_slug(category['name'])}",
            "name": category["name"],
            "description": "",
            "group": group["group"],
        }
        for group in document["taxonomy"]
        for category in group["categories"]
    ]


@pytest.fixture(scope="module")
def artefact(tmp_path_factory: pytest.TempPathFactory) -> Path:
    root = tmp_path_factory.mktemp("endpoint")
    export = load_export(write_export(root / "export"))
    rows, _counts = build_rows(export, load_taxonomy())
    result = fit_artefact(
        HYBRID,
        rows,
        seed=42,
        encoders={"fake": FakeEncoder()},
        taxonomy_path=DEFAULT_TAXONOMY,
        out_dir=root / "models",
        stem_suffix="synthetic",
        described={},
    )
    return result["artefact_path"]


class CountingFactory:
    def __init__(self) -> None:
        self.built = 0

    def __call__(self, _name: str) -> FakeEncoder:
        self.built += 1
        return FakeEncoder()


@pytest.fixture
def factory() -> CountingFactory:
    return CountingFactory()


@pytest.fixture
def client(artefact: Path, factory: CountingFactory) -> Iterator[TestClient]:
    settings = Settings(transaction_categoriser_model=artefact)
    app = create_app(settings, transaction_categoriser=TransactionCategoriser(settings, factory))
    with TestClient(app) as test_client:
        yield test_client


def body(*items: dict[str, Any], **extra: Any) -> dict[str, Any]:
    return {"categories": categories(), "transactions": list(items), **extra}


GROCER = {"payee": "Example Market", "amount": "-120.50", "currency": "UAH", "mcc": "5411"}


def test_it_answers_three_listed_categories_per_transaction(client: TestClient) -> None:
    response = client.post(
        "/categorise/transaction",
        json=body(GROCER, {"comment": "an invented note nobody wrote before"}),
    )
    assert response.status_code == 200, response.text
    answer = response.json()
    slugs = {category["slug"] for category in categories()}
    assert len(answer["results"]) == 2
    for result in answer["results"]:
        assert len(result["candidates"]) == 3
        assert {c["category_slug"] for c in result["candidates"]} <= slugs
        probabilities = [c["probability"] for c in result["candidates"]]
        assert probabilities == sorted(probabilities, reverse=True)
    assert answer["results"][0]["source"] == "mix"
    assert answer["results"][0]["history"] == "payee"
    assert answer["results"][0]["candidates"][0]["category_slug"] == "groceries/groceries"
    assert answer["results"][1]["source"] == "model"
    assert answer["model_name"] == "transaction-categoriser"
    assert re.match(r"^\d{4}-\d{2}-\d{2}-[0-9a-f]{12}$", answer["model_version"])
    assert answer["fitted_at"]


def test_the_artefact_and_the_encoder_load_lazily_and_once(
    client: TestClient, factory: CountingFactory
) -> None:
    assert client.get("/health").status_code == 200
    assert factory.built == 0
    info = client.get("/categorise/transaction").json()
    assert info["encoder_loaded"] is False and factory.built == 0
    for _ in range(3):
        assert client.post("/categorise/transaction", json=body(GROCER)).status_code == 200
    assert factory.built == 1
    info = client.get("/categorise/transaction").json()
    assert info["encoder_loaded"] is True
    assert info["configuration"] == HYBRID.name
    assert info["encoder"] == "fake"


@pytest.mark.parametrize(
    "item",
    [
        {**GROCER, "amount": -120.5},  # a JSON number: money is a decimal string
        {**GROCER, "amount": "-120.505"},  # more places than money has: never rounded
        {**GROCER, "amount": "1e3"},
        {"amount": "-10.00", "currency": "UAH"},  # nothing to go on
        {"payee": "   ", "comment": ""},
        {**GROCER, "mcc": "54111"},
        {**GROCER, "currency": "uah"},
        {**GROCER, "unknown_field": "x"},
    ],
)
def test_a_bad_transaction_is_refused(client: TestClient, item: dict[str, Any]) -> None:
    response = client.post("/categorise/transaction", json=body(item))
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_the_request_size_is_limited(client: TestClient) -> None:
    assert client.post("/categorise/transaction", json=body()).status_code == 422
    many = [GROCER] * (transactions.MAX_TRANSACTIONS + 1)
    assert client.post("/categorise/transaction", json=body(*many)).status_code == 422
    answer = client.post("/categorise/transaction", json=body(*[GROCER] * 300))
    assert answer.status_code == 200
    assert len(answer.json()["results"]) == 300


def test_a_category_the_list_lacks_is_never_dropped_silently(client: TestClient) -> None:
    listed = [c for c in categories() if c["slug"] != "groceries/groceries"]
    response = client.post(
        "/categorise/transaction", json={"categories": listed, "transactions": [GROCER]}
    )
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "categories_mismatch"
    assert "Groceries / Groceries" in error["message"]


def test_categories_are_matched_by_group_and_name_not_by_slug(client: TestClient) -> None:
    renamed = [{**c, "slug": f"x-{c['slug']}"} for c in categories()]
    answer = client.post(
        "/categorise/transaction", json={"categories": renamed, "transactions": [GROCER]}
    ).json()
    assert answer["results"][0]["candidates"][0]["category_slug"] == "x-groceries/groceries"


def test_no_artefact_is_a_501_that_leaves_the_rest_of_the_service_working(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(transactions, "DEFAULT_MODELS_DIR", tmp_path / "nothing-here")
    app = create_app(Settings())
    with TestClient(app) as client:
        for method in (client.get, lambda url: client.post(url, json=body(GROCER))):
            response = method("/categorise/transaction")
            assert response.status_code == 501
            assert response.json()["error"]["code"] == "transaction_categoriser_not_configured"
        assert client.get("/health").status_code == 200
        ocr = client.post("/ocr", files={"images": ("r.png", PNG_BYTES, "image/png")})
        assert ocr.status_code == 200
        texts = {"texts": ["milk"], "categories": categories()[:5]}
        assert client.post("/categorise", json=texts).status_code == 200


def test_the_newest_artefact_of_the_default_folder_is_used(
    artefact: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = tmp_path / "models"
    folder.mkdir()
    (folder / "transaction-categoriser-20200101T000000Z-old.serving.joblib").write_bytes(b"old")
    newest = folder / "transaction-categoriser-20990101T000000Z-new.serving.joblib"
    newest.write_bytes(artefact.read_bytes())
    monkeypatch.setattr(transactions, "DEFAULT_MODELS_DIR", folder)
    holder = TransactionCategoriser(Settings(), lambda _name: FakeEncoder())
    assert holder.artefact_path() == newest
    assert holder.info().model_name == "transaction-categoriser"


def test_an_unreadable_artefact_is_a_501_and_is_tried_again_later(tmp_path: Path) -> None:
    path = tmp_path / "broken.serving.joblib"
    path.write_bytes(b"not an artefact")
    app = create_app(Settings(transaction_categoriser_model=path))
    with TestClient(app) as client:
        response = client.post("/categorise/transaction", json=body(GROCER))
        assert response.status_code == 501
        assert response.json()["error"]["code"] == "transaction_categoriser_unavailable"
        assert "broken.serving.joblib" in response.json()["error"]["message"]
        assert str(tmp_path) not in response.json()["error"]["message"]


SERVING_SOURCES = (
    Path(transactions.__file__),
    Path(transactions.__file__).parents[1] / "categoriser" / "serving.py",
    Path(transactions.__file__).parents[1] / "categoriser" / "embeddings.py",
)
NETWORK_MODULES = {"httpx", "requests", "urllib", "http", "socket", "aiohttp", "openai", "ssl"}


@pytest.mark.parametrize("path", SERVING_SOURCES, ids=lambda path: path.name)
def test_the_serving_code_imports_no_network_client(path: Path) -> None:
    """Transaction data never leaves the machine: the serving path has no way to send it."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    assert not imported & NETWORK_MODULES
    assert "openrouter" not in path.read_text(encoding="utf-8").lower()
