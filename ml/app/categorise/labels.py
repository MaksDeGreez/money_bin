"""Scoring a closed set of labels with a local language model.

The answer is a JSON object, `{"1": "<slug>", "2": "<slug>", ...}`. For each
item the model may only write one of the listed slugs, and instead of letting
it pick token by token (greedy constrained decoding, which gives the
probability of the path it took and nothing about the others), every slug is
scored:

- each slug is tokenised (followed by the closing `",`, or `"}` for the last item) and the token
  sequences form a trie;
- at every node where the slugs part ways, the model's logits for the allowed
  next tokens are renormalised among those tokens only (a softmax over them);
  along a stretch where only one slug remains, the constrained probability is 1;
- a slug's probability is the product along its path. The probabilities of all
  slugs add up to 1: this is the model's own distribution over the listed
  categories, as constrained decoding would see it.

Only the nodes where slugs part ways need a model call: the tokens leading to
one are fed in one call, scored, then taken back out of the KV cache
(`rewind`). The best slug is then written into the answer, and the next item
is scored with all earlier answers in its context, as in a normal generation.

The model sits behind the small `TokenModel` protocol, so the tests use a fake.
"""

import math
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Protocol

ANSWER_START = '{"1": "'
# What closes a value: the quote and what follows it, written as the model writes them (a
# tokeniser has `",` and `"}` as tokens of their own), so a slug's last branch is scored on the
# natural token.
VALUE_END = '",'
LAST_VALUE_END = '"}'


def separator(number: int) -> str:
    """What follows a closed value (`",`) before the value for item `number`."""
    return f' "{number}": "'


class NextToken(Protocol):
    def __call__(self, ids: Sequence[int]) -> Sequence[float]:
        """The model's logits for these candidate next tokens (in the order given)."""
        ...  # pragma: no cover


class TokenModel(Protocol):
    """A loaded language model with one KV cache. Used only from the MLX worker thread."""

    model_name: str
    model_version: str

    def encode(self, text: str) -> list[int]:
        """Token ids of `text`, without special tokens."""
        ...  # pragma: no cover

    def chat_tokens(self, messages: Sequence[dict[str, str]], answer_start: str) -> list[int]:
        """The chat (with the assistant turn opened) followed by `answer_start`, as token ids."""
        ...  # pragma: no cover

    def prefill(self, tokens: Sequence[int]) -> NextToken:
        """Make `tokens` the cache's whole content, reusing what it already holds of them."""
        ...  # pragma: no cover

    def feed(self, tokens: Sequence[int]) -> NextToken:
        """Append `tokens` to the cache."""
        ...  # pragma: no cover

    def rewind(self, count: int) -> None:
        """Drop the last `count` tokens from the cache."""
        ...  # pragma: no cover

    def close(self) -> None: ...  # pragma: no cover


@dataclass
class _Node:
    children: dict[int, "_Node"] = field(default_factory=dict)
    label: int | None = None


@dataclass(frozen=True)
class LabelSet:
    """The labels' token sequences and their trie."""

    sequences: tuple[tuple[int, ...], ...]
    root: _Node

    @classmethod
    def build(cls, model: TokenModel, labels: Sequence[str], close: str = VALUE_END) -> "LabelSet":
        end = model.encode(close)
        sequences = tuple(tuple(model.encode(label) + end) for label in labels)
        root = _Node()
        for index, sequence in enumerate(sequences):
            node = root
            for token in sequence:
                if node.label is not None:
                    raise ValueError("a label's tokens are the start of another label's")
                node = node.children.setdefault(token, _Node())
            if node.children or node.label is not None:
                raise ValueError("a label's tokens are the start of another label's")
            node.label = index
        return cls(sequences, root)


@dataclass
class ScoreStats:
    model_calls: int = 0
    prompt_tokens: int = 0


def _log_softmax(values: Sequence[float]) -> list[float]:
    top = max(values)
    total = math.log(sum(math.exp(value - top) for value in values)) + top
    return [value - total for value in values]


def _score_node(
    model: TokenModel, node: _Node, next_token: NextToken, stats: ScoreStats
) -> dict[int, float]:
    """Log-probabilities of every label below `node`, constrained to the labels."""
    ids = list(node.children)
    logits = list(next_token(ids))
    scores: dict[int, float] = {}
    for token, log_probability in zip(ids, _log_softmax(logits), strict=True):
        path = [token]
        child = node.children[token]
        # Along a stretch where only one label remains, its probability is 1.
        while child.label is None and len(child.children) == 1:
            (token, child), *_ = child.children.items()
            path.append(token)
        if child.label is not None:
            scores[child.label] = log_probability
            continue
        stats.model_calls += 1
        below = _score_node(model, child, model.feed(path), stats)
        model.rewind(len(path))
        for label, value in below.items():
            scores[label] = log_probability + value
    return scores


def score_items(
    model: TokenModel,
    messages: Sequence[dict[str, str]],
    labels: Sequence[str],
    count: int,
) -> tuple[list[list[float]], ScoreStats]:
    """The probability of each label for each of `count` items, from one chat.

    Returns one list per item with a probability per label (in the order of
    `labels`, adding up to 1), and the number of model calls.
    """
    label_set = LabelSet.build(model, labels)
    last_set = LabelSet.build(model, labels, LAST_VALUE_END)
    prompt = model.chat_tokens(messages, ANSWER_START)
    stats = ScoreStats(model_calls=1, prompt_tokens=len(prompt))
    next_token = model.prefill(prompt)
    results: list[list[float]] = []
    for number in range(1, count + 1):
        current = last_set if number == count else label_set
        log_probabilities = _score_node(model, current.root, next_token, stats)
        values = [math.exp(log_probabilities[index]) for index in range(len(labels))]
        total = sum(values)
        probabilities = [value / total for value in values]
        results.append(probabilities)
        if number < count:
            best = max(range(len(labels)), key=lambda index: probabilities[index])
            stats.model_calls += 1
            next_token = model.feed(
                [*label_set.sequences[best], *model.encode(separator(number + 1))]
            )
    return results, stats
