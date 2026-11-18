"""The real `TokenModel`: a language model run by mlx-vlm, with one KV cache.

Import and use this module only on the MLX worker thread (see
`app.backends.mlx_worker`). It is left out of the coverage measurement: it
needs Apple silicon and model weights; `app.categorise.labels` holds the logic
and is tested with a fake model.

The model may be a vision-language model (the OCR model, shared with the OCR
backend through `acquire_model`) or a text model; both are loaded by mlx-vlm.
Only the language part is called, with text tokens. A Qwen VL model numbers
positions in three dimensions (mRoPE); for text alone all three are the plain
position, so they are passed explicitly, which keeps the model's own image
position state out of it.

The cache is kept between receipts: the chat starts with the instructions and
the category list, which do not change, so a new receipt only computes what
differs from the previous one (`prefill`), and the scoring takes its tokens
back out (`rewind`).
"""

from collections.abc import Sequence
from typing import Any

import mlx.core as mx
from mlx_vlm.models import cache as cache_module

from app.backends.mlx_vlm_generator import acquire_model, release_model
from app.categorise.labels import NextToken

# Tokens computed per model call while filling the cache with a long prompt.
PREFILL_STEP = 512


class MlxTokenModel:
    def __init__(self, model: Any, processor: Any, model_name: str, model_version: str) -> None:
        self._model = model
        self._language_model = model.language_model
        self._tokenizer = getattr(processor, "tokenizer", processor)
        self._vision_positions = hasattr(self._language_model, "get_rope_index")
        self.model_name = model_name
        self.model_version = model_version
        self._cache = cache_module.make_prompt_cache(self._language_model)
        if not all(entry.is_trimmable() for entry in self._cache):
            raise RuntimeError(f"{model_name}: its cache cannot be rewound")
        self._tokens: list[int] = []

    @classmethod
    def load(cls, model_id: str) -> "MlxTokenModel":
        model, processor, revision = acquire_model(model_id)
        return cls(model, processor, model_id, revision)

    def encode(self, text: str) -> list[int]:
        return list(self._tokenizer.encode(text, add_special_tokens=False))

    def chat_tokens(self, messages: Sequence[dict[str, str]], answer_start: str) -> list[int]:
        text = self._tokenizer.apply_chat_template(
            [dict(message) for message in messages], add_generation_prompt=True, tokenize=False
        )
        return self.encode(text + answer_start)

    def _forward(self, tokens: Sequence[int]) -> mx.array:
        offset = self._cache[0].offset
        arguments: dict[str, Any] = {}
        if self._vision_positions:
            positions = mx.arange(offset, offset + len(tokens)).reshape(1, 1, -1)
            arguments["position_ids"] = mx.broadcast_to(positions, (3, 1, len(tokens)))
        try:
            output = self._language_model(mx.array([list(tokens)]), cache=self._cache, **arguments)
            logits = output.logits[0, -1, :]
            mx.eval(logits)
        except BaseException:
            # Some layers may have stored the tokens and others not: start from an empty cache, so a
            # later prompt is never scored against a half-written one.
            self._cache = cache_module.make_prompt_cache(self._language_model)
            self._tokens = []
            raise
        self._tokens.extend(tokens)
        return logits

    def _next(self, logits: mx.array) -> NextToken:
        def scores(ids: Sequence[int]) -> list[float]:
            values = mx.take(logits, mx.array(list(ids))).astype(mx.float32)
            return [float(value) for value in values.tolist()]

        return scores

    def prefill(self, tokens: Sequence[int]) -> NextToken:
        shared = 0
        limit = min(len(self._tokens), len(tokens))
        while shared < limit and self._tokens[shared] == tokens[shared]:
            shared += 1
        # At least one token is computed again: its logits are needed.
        shared = min(shared, len(tokens) - 1)
        self.rewind(len(self._tokens) - shared)
        rest = list(tokens[shared:])
        logits = None
        for start in range(0, len(rest), PREFILL_STEP):
            logits = self._forward(rest[start : start + PREFILL_STEP])
        assert logits is not None
        return self._next(logits)

    def feed(self, tokens: Sequence[int]) -> NextToken:
        return self._next(self._forward(tokens))

    def rewind(self, count: int) -> None:
        if count <= 0:
            return
        for entry in self._cache:
            entry.trim(count)
        del self._tokens[len(self._tokens) - count :]

    def close(self) -> None:
        self._cache = []
        self._tokens = []
        self._model = self._language_model = self._tokenizer = None
        release_model(self.model_name)
