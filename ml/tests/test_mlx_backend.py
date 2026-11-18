"""The mlx backend with a fake model: no MLX, no weights, no network."""

import threading
import time
from collections.abc import Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from PIL.Image import Image

from app.backends import ImageInput
from app.backends.mlx import WORKER_THREAD_NAME, Generation, MlxBackend, weights_revision
from app.config import Settings
from app.main import create_app
from app.ocr.parsing import OcrParseError
from app.ocr.prompt import ANSWER_SCHEMA, PROMPT_VERSION
from tests.conftest import encoded_image

ANSWER = """{"kind": "fiscal", "merchant": "Example Market", "fiscal_number": "4000000001",
"receipt_number": "000123", "date": "2026-01-15", "time": "12:34", "total": "71,40",
"currency": "UAH", "card_last4": null, "items": [
{"name": "Milk", "quantity": "1", "unit_price": "42,50", "amount": "42,50 А", "discount": null},
{"name": "Bread", "quantity": "1", "unit_price": "28,90", "amount": "28,90 А", "discount": null}
]}"""


class FakeGenerator:
    """Answers from a list, and records the thread and the arguments of each call."""

    model_name = "example/fake-vl-model"
    model_version = "0123abcd"

    def __init__(self, *answers: str, delay: float = 0.0) -> None:
        self.answers = list(answers) or [ANSWER]
        self.delay = delay
        self.threads: list[int] = []
        self.calls: list[dict[str, Any]] = []
        self.running = 0
        self.most_running = 0
        self.closed_on: list[int] = []
        self.fail_close = False
        self._count_lock = threading.Lock()

    def close(self) -> None:
        self.closed_on.append(threading.get_ident())
        if self.fail_close:
            raise RuntimeError("cannot release")

    def generate(
        self,
        messages: Sequence[Mapping[str, str]],
        images: Sequence[Image],
        *,
        schema: Mapping[str, Any] | None,
        max_tokens: int,
    ) -> Generation:
        with self._count_lock:
            self.running += 1
            self.most_running = max(self.most_running, self.running)
        self.threads.append(threading.get_ident())
        self.calls.append(
            {"messages": messages, "images": images, "schema": schema, "max_tokens": max_tokens}
        )
        time.sleep(self.delay)
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        with self._count_lock:
            self.running -= 1
        return Generation(
            text=answer,
            prompt_tokens=100,
            generation_tokens=50,
            peak_memory_gb=1.5,
            finish_reason="stop",
        )


class Loader:
    """Loads a fake generator and records which thread loaded it."""

    def __init__(self, generator: FakeGenerator) -> None:
        self.generator = generator
        self.threads: list[threading.Thread] = []

    def __call__(self, settings: Settings) -> FakeGenerator:
        self.threads.append(threading.current_thread())
        return self.generator


def make_backend(
    generator: FakeGenerator | None = None, **settings: Any
) -> tuple[MlxBackend, Loader]:
    loader = Loader(generator or FakeGenerator())
    backend = MlxBackend(Settings(ocr_backend="mlx", **settings), loader=loader)
    return backend, loader


def jpeg(width: int = 400, height: int = 900) -> ImageInput:
    return ImageInput(
        content=encoded_image(width, height), content_type="image/jpeg", filename="r.jpg"
    )


def test_before_start_the_backend_reports_the_configured_model() -> None:
    backend, loader = make_backend(mlx_ocr_model="example/model")

    assert backend.model_name == "example/model"
    assert backend.model_version == "not-loaded"
    assert loader.threads == []


def test_start_loads_the_model_on_the_worker_thread_once() -> None:
    backend, loader = make_backend()

    backend.start()
    backend.start()

    assert len(loader.threads) == 1
    assert loader.threads[0].name.startswith(WORKER_THREAD_NAME)
    assert loader.threads[0] is not threading.current_thread()
    assert backend.model_name == "example/fake-vl-model"
    assert backend.categoriser_model_name == "example/fake-vl-model"
    assert backend.model_version == "0123abcd"
    backend.stop()


def test_a_receipt_is_read_through_the_shared_ocr_modules() -> None:
    generator = FakeGenerator()
    backend, _ = make_backend(generator)

    extraction = backend.extract_receipt([jpeg()])

    receipt = extraction.receipt
    assert receipt.kind == "fiscal"
    assert receipt.total == Decimal("71.40")
    assert [item.amount for item in receipt.items] == [Decimal("42.50"), Decimal("28.90")]
    assert receipt.sum_matches_total is True
    assert receipt.issued_at is not None
    assert receipt.issued_at.isoformat() == "2026-01-15T12:34:00+02:00"
    assert extraction.prompt_version == PROMPT_VERSION
    assert extraction.repaired is False
    assert extraction.diagnostics["model_calls"] == 1
    assert extraction.diagnostics["prompt_tokens"] == 100
    assert extraction.diagnostics["peak_memory_gb"] == 1.5
    assert extraction.diagnostics["postprocess"]["tax_letters_stripped"] == 2
    backend.stop()


def test_the_model_gets_the_prompt_the_schema_and_the_scaled_images() -> None:
    generator = FakeGenerator()
    backend, _ = make_backend(generator, mlx_ocr_image_max_side=300, mlx_ocr_max_tokens=1234)

    backend.extract_receipt([jpeg(400, 900), jpeg(400, 600)])

    call = generator.calls[0]
    assert call["schema"] == ANSWER_SCHEMA
    assert call["max_tokens"] == 1234
    assert [image.size for image in call["images"]] == [(133, 300), (200, 300)]
    assert [message["role"] for message in call["messages"]] == ["system", "user"]
    assert "The 2 images are overlapping photos" in call["messages"][1]["content"]
    backend.stop()


def test_without_constrained_decoding_no_schema_is_passed() -> None:
    generator = FakeGenerator()
    backend, _ = make_backend(generator, mlx_ocr_constrained_decoding=False)

    backend.extract_receipt([jpeg()])

    assert generator.calls[0]["schema"] is None
    backend.stop()


def test_an_unreadable_first_answer_is_repaired() -> None:
    generator = FakeGenerator("Sorry, I cannot", ANSWER)
    backend, _ = make_backend(generator)

    extraction = backend.extract_receipt([jpeg()])

    assert extraction.repaired is True
    assert extraction.diagnostics["model_calls"] == 2
    assert extraction.diagnostics["generation_tokens"] == 100
    repair_prompt = generator.calls[1]["messages"][1]["content"]
    assert "Your previous answer could not be used" in repair_prompt
    assert "Sorry, I cannot" in repair_prompt
    backend.stop()


def test_two_unreadable_answers_raise_with_the_call_counts() -> None:
    backend, _ = make_backend(FakeGenerator("nope", "still nope"))

    with pytest.raises(OcrParseError) as error:
        backend.extract_receipt([jpeg()])

    assert error.value.diagnostics["model_calls"] == 2
    assert error.value.diagnostics["finish_reasons"] == ["stop", "stop"]
    backend.stop()


def test_load_and_every_generation_run_on_one_thread() -> None:
    generator = FakeGenerator(delay=0.01)
    backend, loader = make_backend(generator)
    backend.start()

    with ThreadPoolExecutor(max_workers=6) as requests:
        results = list(requests.map(lambda _: backend.extract_receipt([jpeg(64, 64)]), range(12)))

    assert len(results) == 12
    worker = loader.threads[0]
    assert set(generator.threads) == {worker.ident}
    assert generator.most_running == 1
    backend.stop()


def test_the_api_runs_every_request_on_the_one_worker_thread() -> None:
    generator = FakeGenerator(delay=0.01)
    backend, loader = make_backend(generator)
    app = create_app(Settings(ocr_backend="mlx"), backend=backend)
    files = [("images", ("r.jpg", encoded_image(64, 64), "image/jpeg"))]

    with TestClient(app) as client:
        assert len(loader.threads) == 1  # loaded at startup, before any request
        health = client.get("/health").json()
        with ThreadPoolExecutor(max_workers=4) as requests:
            responses = list(requests.map(lambda _: client.post("/ocr", files=files), range(6)))

    assert health == {
        "status": "ok",
        "backend": "mlx",
        "model_name": "example/fake-vl-model",
        "model_version": "0123abcd",
    }
    assert [response.status_code for response in responses] == [200] * 6
    body = responses[0].json()
    assert body["prompt_version"] == PROMPT_VERSION
    assert body["repaired"] is False
    assert Decimal(body["elapsed_seconds"]) > 0
    assert body["receipt"]["sum_matches_total"] is True
    assert set(generator.threads) == {loader.threads[0].ident}
    assert generator.most_running == 1
    # Shut down with the app: the worker thread has finished.
    assert not loader.threads[0].is_alive()


def test_the_api_answers_422_when_the_model_answer_stays_unreadable() -> None:
    backend, _ = make_backend(FakeGenerator("not json"))
    app = create_app(Settings(ocr_backend="mlx"), backend=backend)

    with TestClient(app) as client:
        response = client.post("/ocr", files=[("images", ("r.jpg", encoded_image(), "image/jpeg"))])

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "ocr_parse_failed"
    assert "after one repair pass" in error["message"]
    assert "not json" not in error["message"]


def test_the_api_answers_422_for_an_image_that_cannot_be_decoded() -> None:
    backend, _ = make_backend()
    app = create_app(Settings(ocr_backend="mlx"), backend=backend)
    broken = b"\xff\xd8\xff\xe0" + b"\x00" * 64

    with TestClient(app) as client:
        response = client.post("/ocr", files=[("images", ("bad.jpg", broken, "image/jpeg"))])

    assert response.status_code == 422
    assert response.json()["error"] == {
        "code": "image_unreadable",
        "message": "File 'bad.jpg' cannot be read as an image.",
    }


def test_categorise_is_not_implemented_on_this_backend() -> None:
    backend, _ = make_backend()
    app = create_app(Settings(ocr_backend="mlx"), backend=backend)

    with TestClient(app) as client:
        response = client.post("/categorise", json={"texts": ["milk"]})

    assert response.status_code == 501
    assert response.json()["error"]["code"] == "backend_not_implemented"


def test_a_failed_load_stops_the_service_from_starting() -> None:
    def broken(settings: Settings) -> FakeGenerator:
        raise RuntimeError("no such model")

    backend = MlxBackend(Settings(ocr_backend="mlx"), loader=broken)
    app = create_app(Settings(ocr_backend="mlx"), backend=backend)

    with pytest.raises(RuntimeError, match="no such model"), TestClient(app):
        pass  # pragma: no cover - startup fails first


def test_start_can_be_retried_after_a_failed_load() -> None:
    attempts: list[int] = []
    generator = FakeGenerator()

    def flaky(settings: Settings) -> FakeGenerator:
        attempts.append(1)
        if len(attempts) == 1:
            raise OSError("disk busy")
        return generator

    backend = MlxBackend(Settings(ocr_backend="mlx"), loader=flaky)
    with pytest.raises(OSError, match="disk busy"):
        backend.start()
    backend.start()

    assert backend.model_version == "0123abcd"
    backend.stop()


def test_the_first_request_loads_the_model_when_start_was_not_called() -> None:
    backend, loader = make_backend()

    backend.extract_receipt([jpeg()])

    assert len(loader.threads) == 1
    backend.stop()


def test_stop_releases_the_model_on_the_worker_thread() -> None:
    generator = FakeGenerator()
    backend, loader = make_backend(generator)
    backend.start()

    backend.stop()

    assert generator.closed_on == [loader.threads[0].ident]
    assert not loader.threads[0].is_alive()


def test_a_failed_release_still_stops_the_worker(caplog: pytest.LogCaptureFixture) -> None:
    generator = FakeGenerator()
    generator.fail_close = True
    backend, loader = make_backend(generator)
    backend.start()

    backend.stop()

    assert not loader.threads[0].is_alive()
    assert "Releasing the MLX model failed" in caplog.text


def test_stop_without_start_does_nothing() -> None:
    backend, _ = make_backend()

    backend.stop()


def test_generation_after_stop_is_refused() -> None:
    backend, _ = make_backend()
    backend.start()
    backend.stop()

    with pytest.raises(RuntimeError, match="stopped"):
        backend._generate([], [])


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("/cache/hub/models--example--model/snapshots/0123abcd", "0123abcd"),
        ("/models/my-local-model", "local"),
    ],
)
def test_weights_revision(path: str, expected: str) -> None:
    assert weights_revision(Path(path)) == expected
