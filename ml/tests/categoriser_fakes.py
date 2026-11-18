"""A fake sentence encoder for the categoriser tests: no torch, no weights, no network."""

from __future__ import annotations

import hashlib
from collections.abc import Sequence

import numpy as np


class FakeEncoder:
    """Hashes character trigrams into a small vector, so similar texts get similar vectors."""

    def __init__(self, key: str = "fake-encoder@1", dimensions: int = 16) -> None:
        self._key = key
        self.dimensions = dimensions
        self.calls: list[list[str]] = []

    @property
    def key(self) -> str:
        return self._key

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        self.calls.append(list(texts))
        vectors = np.zeros((len(texts), self.dimensions), dtype=np.float32)
        for i, text in enumerate(texts):
            padded = f"  {text.lower()}  "
            for j in range(len(padded) - 2):
                digest = hashlib.sha256(padded[j : j + 3].encode()).digest()
                vectors[i, digest[0] % self.dimensions] += 1.0
        return vectors

    @property
    def encoded_texts(self) -> list[str]:
        return [text for call in self.calls for text in call]
