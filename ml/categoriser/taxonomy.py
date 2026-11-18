"""The app's category taxonomy (`db/seeds/taxonomy.yml`): which group and category names exist.

The history importer sends a line whose names are not in the taxonomy to Uncategorised, so the
categoriser drops such a row too: it must never learn or suggest a category the app cannot store.
Names are compared exactly after squishing whitespace, as the importer compares them.
"""

from __future__ import annotations

from pathlib import Path

import yaml

DEFAULT_TAXONOMY = Path(__file__).resolve().parents[2] / "db" / "seeds" / "taxonomy.yml"


class TaxonomyError(Exception):
    """The taxonomy file is missing or not in the expected shape."""


def load_taxonomy(path: Path = DEFAULT_TAXONOMY) -> frozenset[tuple[str, str]]:
    """The (group, category) name pairs of the taxonomy."""
    if not path.is_file():
        raise TaxonomyError(f"the taxonomy file {path} does not exist")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        pairs = {
            (_squish(group["group"]), _squish(category["name"]))
            for group in data["taxonomy"]
            for category in group["categories"]
        }
    except (yaml.YAMLError, KeyError, TypeError, AttributeError):
        raise TaxonomyError(f"the taxonomy file {path} is not in the expected shape") from None
    if not pairs:
        raise TaxonomyError(f"the taxonomy file {path} has no categories")
    return frozenset(pairs)


def _squish(value: str) -> str:
    return " ".join(value.split())
