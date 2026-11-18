"""The stub categoriser: invented suggestions in the final shapes, from a hash.

It never looks at a model. The same text and category list always give the
same answer, so the Rails app and the tests can work without one.
"""

import hashlib

from app.categorise.base import (
    Categorisation,
    CategoriseInput,
    Categoriser,
    top_candidates,
)


def _weight(text: str, slug: str) -> float:
    """A positive weight that depends only on the text and the slug.

    The power makes the weights uneven, so one slug usually wins clearly, as
    with a real classifier.
    """
    digest = hashlib.sha256(f"{text}\x00{slug}".encode()).digest()
    return ((int.from_bytes(digest[:4], "big") + 1) / 2**32) ** 4


def stub_scores(text: str, slugs: list[str]) -> dict[str, float]:
    """Shares of one distribution over all slugs: in 0..1, adding up to 1."""
    weights = {slug: _weight(text, slug) for slug in slugs}
    total = sum(weights.values())
    return {slug: round(weight / total, 4) for slug, weight in weights.items()}


class StubCategoriser(Categoriser):
    name = "stub"
    model_name = "stub-categoriser"
    model_version = "0.2.0"

    def categorise(self, request: CategoriseInput) -> Categorisation:
        slugs = [category.slug for category in request.categories]
        return Categorisation(
            candidates=[top_candidates(stub_scores(text, slugs)) for text in request.texts],
            score_kind="stub",
            prompt_version=None,
        )
