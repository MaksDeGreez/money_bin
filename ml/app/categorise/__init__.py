"""Item categorisation: the categorisers (chosen by `CATEGORISE_BACKEND`) and their prompt."""

from app.backends.mlx_worker import MlxWorker
from app.categorise.base import (
    Candidate,
    Categorisation,
    CategoriseInput,
    Categoriser,
)
from app.categorise.decisions import DecisionsCategoriser
from app.categorise.mlx import MlxCategoriser
from app.categorise.off import OffCategoriser
from app.categorise.openrouter import OpenRouterCategoriser
from app.categorise.stub import StubCategoriser
from app.config import Settings

CATEGORISERS: dict[str, type[Categoriser]] = {
    StubCategoriser.name: StubCategoriser,
    MlxCategoriser.name: MlxCategoriser,
    OpenRouterCategoriser.name: OpenRouterCategoriser,
    OffCategoriser.name: OffCategoriser,
    DecisionsCategoriser.name: DecisionsCategoriser,
}
# The categorisers that suggest anything (`off` is the switch, not a model).
SUGGESTING = tuple(sorted(name for name in CATEGORISERS if name != OffCategoriser.name))


class UnknownCategoriserError(ValueError):
    """Raised at startup when `CATEGORISE_BACKEND` names no known categoriser."""


def create_categoriser(
    name: str, settings: Settings | None = None, worker: MlxWorker | None = None
) -> Categoriser:
    """Build the categoriser with this name, or fail with a list of the valid names.

    `worker` is the MLX worker thread to share with an MLX OCR backend.
    """
    key = name.strip().lower()
    if key not in CATEGORISERS:
        valid = ", ".join(sorted(CATEGORISERS))
        raise UnknownCategoriserError(f"Unknown CATEGORISE_BACKEND {name!r}. Valid names: {valid}.")
    if key == MlxCategoriser.name:
        return MlxCategoriser(settings, worker=worker)
    return CATEGORISERS[key](settings)


__all__ = [
    "CATEGORISERS",
    "SUGGESTING",
    "Candidate",
    "Categorisation",
    "CategoriseInput",
    "Categoriser",
    "UnknownCategoriserError",
    "create_categoriser",
]
