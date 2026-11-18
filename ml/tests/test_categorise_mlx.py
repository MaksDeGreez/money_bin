"""The local categoriser: the worker thread, the shared worker and model, the answers."""

import threading
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.backends.mlx import MlxBackend
from app.backends.mlx_worker import WORKER_THREAD_NAME, MlxWorker
from app.categorise.base import CategoriseInput
from app.categorise.mlx import MlxCategoriser, categorise_model_id
from app.categorise.prompt import PROMPT_VERSION
from app.config import Settings
from app.main import create_app
from tests.categorise_helpers import CATEGORIES, OPTIONS, SLUGS, FakeTokenModel


class Loader:
    """Loads a fake model and records which thread loaded which id."""

    def __init__(self, answers: dict[int, str] | None = None) -> None:
        self.answers = answers or {1: "groceries/groceries", 2: "health/health-pharmacy"}
        self.loaded: list[tuple[str, threading.Thread]] = []
        self.models: list[FakeTokenModel] = []
        self.threads: list[int] = []

    def __call__(self, model_id: str) -> FakeTokenModel:
        self.loaded.append((model_id, threading.current_thread()))
        loader = self

        class Recording(FakeTokenModel):
            def prefill(self, tokens: Any) -> Any:
                loader.threads.append(threading.get_ident())
                return super().prefill(tokens)

        model = Recording(self.answers, strength=6.0)
        self.models.append(model)
        return model


def request(*texts: str, merchant: str | None = "Аптека") -> CategoriseInput:
    return CategoriseInput(OPTIONS, texts or ("Мол900г", "Парацетамол"), merchant)


def test_the_model_defaults_to_the_ocr_model() -> None:
    assert categorise_model_id(Settings(mlx_ocr_model="example/vl")) == "example/vl"
    assert categorise_model_id(Settings(mlx_categorise_model="  ")) == Settings().mlx_ocr_model
    assert (
        categorise_model_id(Settings(mlx_ocr_model="example/vl", mlx_categorise_model="ex/text"))
        == "ex/text"
    )


def test_items_are_scored_on_the_worker_thread() -> None:
    loader = Loader()
    categoriser = MlxCategoriser(Settings(mlx_ocr_model="example/vl"), loader=loader)

    answer = categoriser.categorise(request())

    (model_id, thread), *_ = loader.loaded
    assert model_id == "example/vl"
    assert thread.name.startswith(WORKER_THREAD_NAME)
    assert thread is not threading.current_thread()
    assert loader.threads == [thread.ident]
    assert categoriser.model_version == "fake-revision"
    assert answer.score_kind == "label_probability"
    assert answer.prompt_version == PROMPT_VERSION
    assert [c[0].slug for c in answer.candidates] == [
        "groceries/groceries",
        "health/health-pharmacy",
    ]
    for candidates in answer.candidates:
        assert len(candidates) == 3
        assert sum(c.score for c in candidates) <= 1.0 + 1e-9
        assert {c.slug for c in candidates} <= set(SLUGS)
    assert answer.diagnostics["model_calls"] >= 2
    categoriser.stop()
    assert loader.models[0].closed
    assert not thread.is_alive()


def test_the_merchant_is_context_for_the_local_model() -> None:
    loader = Loader()
    categoriser = MlxCategoriser(Settings(), loader=loader)

    categoriser.categorise(request(merchant="Аптека Добробут"))
    categoriser.categorise(request(merchant=None))

    first, second = loader.models[0].messages
    assert "Аптека Добробут" in first[1]["content"]
    assert "The shop" not in second[1]["content"]
    categoriser.stop()


def test_start_is_once_and_stop_is_safe_twice() -> None:
    loader = Loader()
    categoriser = MlxCategoriser(Settings(), loader=loader)

    categoriser.start()
    categoriser.start()
    categoriser.stop()
    categoriser.stop()

    assert len(loader.loaded) == 1


def test_a_failed_load_releases_the_worker() -> None:
    worker = MlxWorker()

    def broken(model_id: str) -> FakeTokenModel:
        raise RuntimeError("no such model")

    categoriser = MlxCategoriser(Settings(), loader=broken, worker=worker)

    with pytest.raises(RuntimeError, match="no such model"):
        categoriser.start()
    assert not worker.running


def test_the_ocr_backend_and_the_categoriser_share_one_worker_thread() -> None:
    from tests.test_mlx_backend import FakeGenerator

    worker = MlxWorker()
    ocr_threads: list[threading.Thread] = []

    def load_generator(settings: Settings) -> FakeGenerator:
        ocr_threads.append(threading.current_thread())
        return FakeGenerator()

    loader = Loader()
    backend = MlxBackend(Settings(), loader=load_generator, worker=worker)
    categoriser = MlxCategoriser(Settings(), loader=loader, worker=worker)
    backend.start()
    categoriser.start()

    categoriser.categorise(request())

    assert ocr_threads[0] is loader.loaded[0][1]
    backend.stop()
    assert worker.running  # the categoriser still uses it
    categoriser.stop()
    assert not worker.running


def test_the_api_starts_and_stops_a_shared_worker() -> None:
    from tests.test_mlx_backend import FakeGenerator

    worker = MlxWorker()
    loader = Loader()
    backend = MlxBackend(Settings(), loader=lambda settings: FakeGenerator(), worker=worker)
    categoriser = MlxCategoriser(Settings(), loader=loader, worker=worker)
    app = create_app(Settings(ocr_backend="mlx", categorise_backend="mlx"), backend, categoriser)

    with TestClient(app) as client:
        assert worker.running
        response = client.post("/categorise", json={"texts": ["Мол900г"], "categories": CATEGORIES})
        health = client.get("/health").json()

    assert response.status_code == 200
    answer = response.json()
    assert answer["backend"] == "mlx"
    assert answer["model_name"] == Settings().mlx_ocr_model
    assert answer["score_kind"] == "label_probability"
    assert answer["calibrated"] is False
    assert answer["results"][0]["candidates"][0]["category_slug"] == "groceries/groceries"
    assert health["categoriser"]["model_version"] == "fake-revision"
    assert not worker.running


def test_create_app_shares_one_worker_between_mlx_backends() -> None:
    app = create_app(Settings(ocr_backend="mlx", categorise_backend="mlx"))

    assert app.state.backend._worker is app.state.categoriser._worker


def test_the_worker_refuses_work_when_stopped() -> None:
    worker = MlxWorker()
    worker.release()  # nothing to release: harmless

    with pytest.raises(RuntimeError, match="not running"):
        worker.run(print)


def test_a_stopped_categoriser_refuses_to_answer() -> None:
    loader = Loader()
    categoriser = MlxCategoriser(Settings(), loader=loader)
    categoriser.start()
    categoriser.start = lambda: None  # type: ignore[method-assign]
    categoriser.stop()

    with pytest.raises(RuntimeError, match="stopped"):
        categoriser.categorise(request())


def test_a_failure_to_release_the_model_is_logged(caplog: pytest.LogCaptureFixture) -> None:
    loader = Loader()
    categoriser = MlxCategoriser(Settings(), loader=loader)
    categoriser.start()

    def broken() -> None:
        raise RuntimeError("cannot release")

    loader.models[0].close = broken  # type: ignore[method-assign]
    categoriser.stop()

    assert "Releasing the MLX categoriser model failed" in caplog.text
