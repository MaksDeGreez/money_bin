"""Shared helpers of the categorisation tests: an invented category list and a fake model."""

import math
import re
from collections.abc import Mapping, Sequence

from app.categorise.labels import ANSWER_START, NextToken
from app.categorise.prompt import CategoryOption

# A small list in the request's shape. The slugs follow the app's form; the texts are invented.
CATEGORIES: list[dict[str, str]] = [
    {
        "slug": "groceries/groceries",
        "name": "Groceries",
        "description": "Food and everyday groceries.",
        "group": "Groceries",
    },
    {
        "slug": "eating-out/cafes-bars-restaurants",
        "name": "Cafes, bars & restaurants",
        "description": "Meals and drinks at cafes.",
        "group": "Eating out",
    },
    {
        "slug": "eating-out/takeaway-fast-food",
        "name": "Takeaway & fast food",
        "description": "Takeaway and fast food.",
        "group": "Eating out",
    },
    {
        "slug": "household-shopping/household-supplies",
        "name": "Household supplies",
        "description": "Household goods.",
        "group": "Household & shopping",
    },
    {
        "slug": "household-shopping/pets",
        "name": "Pets",
        "description": "Pet food and pet care.",
        "group": "Household & shopping",
    },
    {
        "slug": "health/health-pharmacy",
        "name": "Health & pharmacy",
        "description": "Pharmacy and medicine.",
        "group": "Health",
    },
    {
        "slug": "other/other-spending",
        "name": "Other spending",
        "description": "",
        "group": "Other",
    },
]

OPTIONS: tuple[CategoryOption, ...] = tuple(CategoryOption(**row) for row in CATEGORIES)
SLUGS: list[str] = [row["slug"] for row in CATEGORIES]


class FakeTokenModel:
    """A character-level stand-in for a language model with a KV cache.

    Tokens are code points. For item N the model prefers the characters of
    `answers[N]` (a logit of `strength` against 0 for any other character), so
    the probabilities are known in closed form. It records every call and
    checks that the cache is never rewound past what it holds.
    """

    model_name = "example/fake-text-model"
    model_version = "fake-revision"

    def __init__(self, answers: Mapping[int, str], strength: float = 2.0) -> None:
        self.answers = answers
        self.strength = strength
        self.cache: list[int] = []
        self.calls: list[tuple[str, int]] = []
        self.messages: list[Sequence[Mapping[str, str]]] = []
        self.closed = False

    def encode(self, text: str) -> list[int]:
        return [ord(char) for char in text]

    def chat_tokens(self, messages: Sequence[Mapping[str, str]], answer_start: str) -> list[int]:
        self.messages.append(messages)
        text = "".join(f"<{m['role']}>{m['content']}" for m in messages) + "<assistant>"
        return self.encode(text + answer_start)

    def _next(self) -> NextToken:
        text = "".join(chr(token) for token in self.cache)
        match = list(re.finditer(r'"(\d+)": "([^"]*)$', text))
        number, typed = (int(match[-1].group(1)), match[-1].group(2)) if match else (0, "")
        wanted = self.answers.get(number, "") + '"'

        def logits(ids: Sequence[int]) -> list[float]:
            return [
                self.strength if (typed + chr(token)) == wanted[: len(typed) + 1] else 0.0
                for token in ids
            ]

        return logits

    def prefill(self, tokens: Sequence[int]) -> NextToken:
        self.calls.append(("prefill", len(tokens)))
        self.cache = list(tokens)
        return self._next()

    def feed(self, tokens: Sequence[int]) -> NextToken:
        self.calls.append(("feed", len(tokens)))
        self.cache.extend(tokens)
        return self._next()

    def rewind(self, count: int) -> None:
        assert 0 < count <= len(self.cache) - len(ANSWER_START)
        self.calls.append(("rewind", count))
        del self.cache[len(self.cache) - count :]

    def close(self) -> None:
        self.closed = True


def constrained_probability(slug: str, slugs: Sequence[str], wanted: str, strength: float) -> float:
    """The probability of `slug` under the fake model, computed by brute force.

    At each character position the allowed characters are those that continue
    some slug (plus the closing quote); the wanted character gets `strength`.
    """
    probability = 1.0
    texts = [s + '"' for s in slugs]
    target = slug + '"'
    goal = wanted + '"'
    for index in range(len(target)):
        prefix = target[:index]
        allowed = sorted({t[index] for t in texts if t.startswith(prefix) and len(t) > index})
        if len(allowed) == 1:
            continue
        weights = {
            char: math.exp(strength if (prefix + char) == goal[: index + 1] else 0.0)
            for char in allowed
        }
        probability *= weights[target[index]] / sum(weights.values())
    return probability
