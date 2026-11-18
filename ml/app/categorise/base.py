"""The interface of an item categoriser, and what it returns.

A categoriser suggests categories for the items of ONE receipt at a time: the
items are judged together, since the neighbours help (a pharmacy's receipt is
full of medicines). The categories come with each request (`CategoryOption`);
an answer only ever names slugs from them.
"""

from abc import ABC, abstractmethod
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Literal

from app.categorise.prompt import CategoryOption
from app.config import Settings

# Where a score comes from (ml/README.md, "How confidence is computed"):
# - label_probability: the model's probability of each category's full slug, renormalised
#   over the listed slugs only (a local model; the scores of all slugs add up to 1);
# - token_logprobs: the hosted model's own token log-probabilities of its answer, as the
#   endpoint reported them; not renormalised over the slugs;
# - fixed: the endpoint gave no log-probabilities; the answer gets FALLBACK_SCORE;
# - stub: invented by the stub from a hash of the text.
ScoreKind = Literal["label_probability", "token_logprobs", "fixed", "stub"]

MAX_CANDIDATES = 3


@dataclass(frozen=True)
class CategoriseInput:
    """One receipt's items to categorise.

    `merchant` is context for a local model only; a hosted backend never sends it.
    """

    categories: tuple[CategoryOption, ...]
    texts: tuple[str, ...]
    merchant: str | None = None


@dataclass(frozen=True)
class Candidate:
    slug: str
    score: float


@dataclass(frozen=True)
class Categorisation:
    """The suggestions for the items, in their order.

    Each item has 1 to 3 candidates, best first, with scores in 0..1 that add up
    to at most 1. `diagnostics` holds numbers for the evaluation (calls, tokens,
    cost), never item text.
    """

    candidates: list[list[Candidate]]
    score_kind: ScoreKind
    prompt_version: str | None
    diagnostics: Mapping[str, Any] = field(default_factory=dict)


def top_candidates(scores: Mapping[str, float], limit: int = MAX_CANDIDATES) -> list[Candidate]:
    """The `limit` best slugs, best first (ties by slug, so the order is stable)."""
    ranked = sorted(scores.items(), key=lambda pair: (-pair[1], pair[0]))
    return [Candidate(slug, min(1.0, max(0.0, score))) for slug, score in ranked[:limit]]


class Categoriser(ABC):
    """A model that suggests categories for receipt items.

    `start()` runs when the service starts and `stop()` when it shuts down.
    `model_version` may be known only after `start()`.
    """

    name: str
    model_name: str
    model_version: str

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or Settings()

    def start(self) -> None:  # noqa: B027 - optional hook, empty by default
        """Prepare the categoriser (load a model). Called once at startup."""

    def stop(self) -> None:  # noqa: B027 - optional hook, empty by default
        """Release what `start` acquired. Called once at shutdown."""

    @abstractmethod
    def categorise(self, request: CategoriseInput) -> Categorisation:
        """Suggest categories for each item of one receipt, in the order of `request.texts`."""


def slugs_of(categories: Sequence[CategoryOption]) -> list[str]:
    return [category.slug for category in categories]
