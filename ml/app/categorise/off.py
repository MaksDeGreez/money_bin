"""Categorisation switched off (`CATEGORISE_BACKEND=off`).

For labelling with no suggestions on screen: a categoriser cannot be evaluated
on labels it pre-filled, the label memory included, so the owner labels some
receipts with every suggestion switched off. The Rails app reads the same
setting and then asks nothing (docs/domain.md, "Labelling without
suggestions"); a request that arrives anyway is a 501.
"""

from app.backends.base import BackendNotImplementedError
from app.categorise.base import Categorisation, CategoriseInput, Categoriser


class OffCategoriser(Categoriser):
    name = "off"
    model_name = "off"
    model_version = "off"

    def categorise(self, request: CategoriseInput) -> Categorisation:
        raise BackendNotImplementedError(
            "Item categorisation is switched off (CATEGORISE_BACKEND=off)."
        )
