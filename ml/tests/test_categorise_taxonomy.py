"""The category hand-over: the same parser for requests and for offline scripts."""

import json
from pathlib import Path
from typing import Any

import pytest

from app.categorise.prompt import CategoryOption
from app.categorise.taxonomy import (
    CATEGORY_SLUG,
    TaxonomyError,
    parse_categories,
    read_categories_file,
)
from app.schemas import CATEGORY_SLUG as SCHEMA_SLUG
from tests.categorise_helpers import CATEGORIES, OPTIONS


def test_rows_become_options_in_order_with_spaces_tidied() -> None:
    rows = [{**CATEGORIES[0], "name": "  Groceries \n", "description": None}, CATEGORIES[1]]

    options = parse_categories(rows)

    assert options[0] == CategoryOption("groceries/groceries", "Groceries", "", "Groceries")
    assert options[1] == OPTIONS[1]


def test_an_exported_file_is_read(tmp_path: Path) -> None:
    path = tmp_path / "item_categories.json"
    path.write_text(json.dumps({"categories": CATEGORIES}, ensure_ascii=False))

    assert read_categories_file(path) == OPTIONS


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ([CATEGORIES[0], "x"], "not an object"),
        ([{**CATEGORIES[0], "group": 3}, CATEGORIES[1]], "group is not text"),
        ([{**CATEGORIES[0], "name": "x" * 121}, CATEGORIES[1]], "longer than 120"),
        ([CATEGORIES[0], CATEGORIES[0]], "twice"),
    ],
)
def test_bad_rows_are_refused(rows: list[Any], message: str) -> None:
    with pytest.raises(TaxonomyError, match=message):
        parse_categories(rows)


def test_a_bad_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(TaxonomyError, match="cannot be read"):
        read_categories_file(tmp_path / "missing.json")
    (tmp_path / "bad.json").write_text("{}")
    with pytest.raises(TaxonomyError, match="no list"):
        read_categories_file(tmp_path / "bad.json")


def test_the_api_and_the_hand_over_accept_the_same_slugs() -> None:
    assert SCHEMA_SLUG == CATEGORY_SLUG
