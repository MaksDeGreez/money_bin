"""Sentence embeddings of the row texts, computed on this machine and cached on disk.

An `Encoder` turns texts into vectors. The real ones (`TransformerEncoder`) run a multilingual
sentence-embedding model (multilingual E5, base or large) from the local Hugging Face cache with
PyTorch, on the Apple GPU when there is one: the mean of the last hidden states over the tokens,
scaled to unit length. No model code is downloaded or trusted (no `trust_remote_code`). torch and
transformers are imported lazily: they are in the `embeddings` dependency group, which installs only
on macOS on Apple silicon, so CI and the tests never load them (the tests use a fake encoder).
Transaction text never leaves the machine: the models load with `local_files_only`, so nothing is
fetched, let alone sent, while texts are encoded.

`EmbeddingCache` keeps every vector in a SQLite file outside the repository, keyed by the SHA-256 of
the encoder's key (model, pinned revision, prefix, pooling, maximum length) and the text, so a
repeated run encodes nothing it has seen and a different model or setting never reuses a vector.
The cache holds vectors of personal text: it lives in the private data folder, file mode 600.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np

DEFAULT_CACHE = Path.home() / "Documents" / "money_bin_data" / "cache" / "embeddings"
CACHE_FILE = "embeddings.sqlite3"


class EmbeddingError(Exception):
    """The encoder cannot run (libraries not installed, model weights not in the local cache)."""


class Encoder(Protocol):
    """Turns texts into vectors. `key` names everything that changes the vectors."""

    @property
    def key(self) -> str: ...

    def encode(self, texts: Sequence[str]) -> np.ndarray: ...


@dataclass(frozen=True)
class EncoderSpec:
    name: str
    model_id: str
    revision: str  # a pinned commit of the model repository
    prefix: str = ""
    max_length: int = 128

    @property
    def key(self) -> str:
        return (
            f"{self.model_id}@{self.revision}|prefix={self.prefix}|pooling=mean"
            f"|max_length={self.max_length}"
        )


# Multilingual E5 (XLM-RoBERTa, trained for multilingual sentence embeddings). E5 expects a
# "query: " prefix for texts that are not retrieval passages.
ENCODERS: dict[str, EncoderSpec] = {
    "e5-base": EncoderSpec(  # 278M parameters, 768 dimensions
        name="e5-base",
        model_id="intfloat/multilingual-e5-base",
        revision="d128750597153bb5987e10b1c3493a34e5a4502a",
        prefix="query: ",
    ),
    "e5-large": EncoderSpec(  # 560M parameters, 1024 dimensions
        name="e5-large",
        model_id="intfloat/multilingual-e5-large",
        revision="3d7cfbdacd47fdda877c5cd8a79fbcc4f2a574f3",
        prefix="query: ",
    ),
}


def text_key(encoder_key: str, text: str) -> str:
    """The cache key of one text under one encoder."""
    return hashlib.sha256(f"{encoder_key}\0{text}".encode()).hexdigest()


class EmbeddingCache:
    """Vectors by `text_key`, in one SQLite file."""

    def __init__(self, folder: Path) -> None:
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = folder / CACHE_FILE
        if not path.exists():
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
        self._db = sqlite3.connect(path)
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS vectors (key TEXT PRIMARY KEY, dim INTEGER, vector BLOB)"
        )

    def get(self, keys: Sequence[str]) -> dict[str, np.ndarray]:
        found: dict[str, np.ndarray] = {}
        for start in range(0, len(keys), 500):
            chunk = list(keys[start : start + 500])
            marks = ",".join("?" * len(chunk))
            query = f"SELECT key, dim, vector FROM vectors WHERE key IN ({marks})"
            for key, dim, blob in self._db.execute(query, chunk):
                vector = np.frombuffer(blob, dtype=np.float32)
                if len(vector) == dim:
                    found[key] = vector
        return found

    def put(self, items: dict[str, np.ndarray]) -> None:
        with self._db:
            self._db.executemany(
                "INSERT OR REPLACE INTO vectors (key, dim, vector) VALUES (?, ?, ?)",
                [
                    (key, len(vector), np.asarray(vector, dtype=np.float32).tobytes())
                    for key, vector in items.items()
                ],
            )

    def __len__(self) -> int:
        return int(self._db.execute("SELECT COUNT(*) FROM vectors").fetchone()[0])

    def close(self) -> None:
        self._db.close()


class CachedEncoder:
    """An encoder in front of the cache: each distinct text is encoded once, ever."""

    def __init__(self, encoder: Encoder, cache: EmbeddingCache, batch: int = 256) -> None:
        self.encoder = encoder
        self.cache = cache
        self.batch = batch
        self.encoded = 0  # texts this object sent to the encoder (cache misses)

    @property
    def key(self) -> str:
        return self.encoder.key

    def prepare(self) -> None:
        """Load the encoder's model now (a cache hit never loads it)."""
        prepare = getattr(self.encoder, "prepare", None)
        if prepare is not None:
            prepare()

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        """One unit-length float32 vector per text, in order."""
        keys = [text_key(self.encoder.key, text) for text in texts]
        found = self.cache.get(sorted(set(keys)))
        missing: dict[str, str] = {}
        for key, text in zip(keys, texts, strict=True):
            if key not in found:
                missing.setdefault(key, text)
        pending = list(missing.items())
        for start in range(0, len(pending), self.batch):
            chunk = pending[start : start + self.batch]
            vectors = _unit(np.asarray(self.encoder.encode([text for _, text in chunk])))
            if len(vectors) != len(chunk):
                raise EmbeddingError("the encoder returned a wrong number of vectors")
            fresh = {
                key: vector.astype(np.float32)
                for (key, _), vector in zip(chunk, vectors, strict=True)
            }
            self.cache.put(fresh)
            found.update(fresh)
            self.encoded += len(chunk)
        if not keys:
            return np.zeros((0, 0), dtype=np.float32)
        return np.vstack([found[key] for key in keys]).astype(np.float32)


def _unit(vectors: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    return vectors / np.where(norms > 0, norms, 1.0)


class TransformerEncoder:  # pragma: no cover - needs torch, transformers and local model weights
    """A sentence-embedding model from the local Hugging Face cache, run with PyTorch."""

    def __init__(self, spec: EncoderSpec, batch_size: int = 64) -> None:
        self.spec = spec
        self.batch_size = batch_size
        self._model = None
        self._tokenizer = None

    @property
    def key(self) -> str:
        return self.spec.key

    def _load(self) -> None:
        # Never reach the Hub while texts are being encoded: everything comes from the local cache.
        os.environ["HF_HUB_OFFLINE"] = "1"
        try:
            import torch
            from transformers import AutoModel, AutoTokenizer
        except ImportError:
            raise EmbeddingError(
                "torch and transformers are not installed: the embeddings dependency group "
                "installs only on macOS on Apple silicon (uv sync in ml/)"
            ) from None
        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        options = {"revision": self.spec.revision, "local_files_only": True}
        try:
            self._tokenizer = AutoTokenizer.from_pretrained(self.spec.model_id, **options)
            model = AutoModel.from_pretrained(self.spec.model_id, **options)
        except OSError:
            raise EmbeddingError(
                f"the weights of {self.spec.model_id} at revision {self.spec.revision[:12]} are "
                "not in the local Hugging Face cache; download them once with "
                f"`uv run hf download {self.spec.model_id} --revision {self.spec.revision}`"
            ) from None
        model.eval()
        self._model = model.to(self._device)

    def prepare(self) -> None:
        if self._model is None:
            self._load()

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        self.prepare()
        prefixed = [self.spec.prefix + text for text in texts]
        torch = self._torch
        out = []
        with torch.inference_mode():
            for start in range(0, len(prefixed), self.batch_size):
                batch = self._tokenizer(
                    prefixed[start : start + self.batch_size],
                    padding=True,
                    truncation=True,
                    max_length=self.spec.max_length,
                    return_tensors="pt",
                ).to(self._device)
                hidden = self._model(**batch).last_hidden_state
                mask = batch["attention_mask"].unsqueeze(-1).to(hidden.dtype)
                pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
                out.append(pooled.float().cpu().numpy())
        return np.vstack(out).astype(np.float32)
