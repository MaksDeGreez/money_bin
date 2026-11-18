"""The category list a categoriser chooses from, as the Rails app hands it over.

The app owns the taxonomy and its slugs (`Categories::ItemCandidates`). It hands
the candidate categories over in one shape, in two places:

- in every `/categorise` request, as `categories`;
- for offline scripts, as a JSON file written by
  `bin/rails "categories:export_items[FILE]"`: `{"categories": [...]}`.

Each category is `{"slug", "name", "description", "group"}`: the slug in the
app's form (`group-part/category-part`), the category's name, its one-line
description (may be empty) and its group's name. `parse_categories` turns
either into `CategoryOption`s with the same checks; nothing here builds a slug.

    from app.categorise.taxonomy import read_categories_file
    categories = read_categories_file(Path("item_categories.json"))
"""

import json
import re
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

from app.categorise.prompt import CategoryOption

# A category slug as the Rails app builds it: a category, never a group.
CATEGORY_SLUG = r"^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$"
MIN_CATEGORIES = 2
MAX_CATEGORIES = 100
MAX_NAME_LENGTH = 120
MAX_DESCRIPTION_LENGTH = 500

_SLUG = re.compile(CATEGORY_SLUG)


class TaxonomyError(ValueError):
    """The category list is not in the hand-over shape. The message names the problem, not data."""


def _text(row: Mapping[str, Any], key: str, index: int, *, required: bool, limit: int) -> str:
    value = row.get(key, "")
    if value is None and not required:
        value = ""
    if not isinstance(value, str):
        raise TaxonomyError(f"category {index}: {key} is not text")
    value = " ".join(value.split())
    if required and not value:
        raise TaxonomyError(f"category {index}: {key} is empty")
    if len(value) > limit:
        raise TaxonomyError(f"category {index}: {key} is longer than {limit} characters")
    return value


def parse_categories(rows: Iterable[Any]) -> tuple[CategoryOption, ...]:
    """Check the rows and return them as `CategoryOption`s, in their order."""
    options = []
    for index, row in enumerate(rows):
        if not isinstance(row, Mapping):
            raise TaxonomyError(f"category {index} is not an object")
        slug = row.get("slug")
        if not isinstance(slug, str) or not _SLUG.match(slug) or len(slug) > MAX_NAME_LENGTH:
            raise TaxonomyError(f"category {index}: the slug is not a category slug")
        options.append(
            CategoryOption(
                slug=slug,
                name=_text(row, "name", index, required=True, limit=MAX_NAME_LENGTH),
                description=_text(
                    row, "description", index, required=False, limit=MAX_DESCRIPTION_LENGTH
                ),
                group=_text(row, "group", index, required=True, limit=MAX_NAME_LENGTH),
            )
        )
    if not MIN_CATEGORIES <= len(options) <= MAX_CATEGORIES:
        raise TaxonomyError(f"the list needs {MIN_CATEGORIES} to {MAX_CATEGORIES} categories")
    if len({option.slug for option in options}) != len(options):
        raise TaxonomyError("the list names a slug twice")
    return tuple(options)


def read_categories_file(path: Path) -> tuple[CategoryOption, ...]:
    """The categories of an exported file (`{"categories": [...]}`)."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise TaxonomyError(f"{path.name} cannot be read ({error.strerror})") from None
    except ValueError:
        raise TaxonomyError(f"{path.name} is not JSON") from None
    rows = document.get("categories") if isinstance(document, dict) else None
    if not isinstance(rows, list):
        raise TaxonomyError(f"{path.name} has no list of categories")
    return parse_categories(rows)
