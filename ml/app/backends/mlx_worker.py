"""The one thread that runs everything MLX does in this service.

MLX keeps its GPU streams per thread, and mlx-vlm creates its generation stream
when it is imported. FastAPI runs each request in a thread of its own pool, so
calling a model from request threads would use streams from the wrong thread.
Instead ONE dedicated worker thread (a single-thread executor) imports mlx-vlm,
loads the models and runs every model call; a request hands its work to that
thread and waits for the result. One call runs at a time; others wait in the
queue.

The OCR backend and the item categoriser share one worker when both run on
MLX (`app.main.create_app` passes the same one to both), so a model loaded for
OCR can also categorise, and the two never use MLX at the same time.
"""

import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any, TypeVar

WORKER_THREAD_NAME = "mlx-worker"

T = TypeVar("T")


class MlxWorker:
    """A single-thread executor shared by its users: the first starts it, the last stops it."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._executor: ThreadPoolExecutor | None = None
        self._users = 0

    def acquire(self) -> None:
        """Start the thread if it is not running, and count one more user."""
        with self._lock:
            if self._executor is None:
                self._executor = ThreadPoolExecutor(
                    max_workers=1, thread_name_prefix=WORKER_THREAD_NAME
                )
            self._users += 1

    def release(self) -> None:
        """Count one user less; the last one finishes the queued work and stops the thread."""
        with self._lock:
            if self._users == 0:
                return
            self._users -= 1
            executor = self._executor if self._users == 0 else None
            if executor is not None:
                self._executor = None
        if executor is not None:
            executor.shutdown(wait=True)

    @property
    def running(self) -> bool:
        return self._executor is not None

    def run(self, function: Callable[..., T], *args: Any, **kwargs: Any) -> T:
        """Run `function` on the worker thread and wait for its result (or its exception)."""
        executor = self._executor
        if executor is None:
            raise RuntimeError("The MLX worker is not running.")
        return executor.submit(function, *args, **kwargs).result()
