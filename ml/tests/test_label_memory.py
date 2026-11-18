"""The label memory's twin for offline runs: the shared name keys and the rule."""

import json
from pathlib import Path

import pytest

from evaluation.label_memory import LabelMemory, confidence, name_key

CASES = json.loads(
    (Path(__file__).parent / "fixtures" / "item_name_keys.json").read_text(encoding="utf-8")
)["cases"]


@pytest.mark.parametrize(("name", "key"), CASES)
def test_name_keys_match_the_shared_cases(name: str, key: str) -> None:
    assert name_key(name) == key


def test_confidence_grows_with_agreeing_labels_and_drops_with_disagreement() -> None:
    assert confidence(1, 1) == pytest.approx(0.889, abs=1e-3)
    assert confidence(2, 2) == pytest.approx(0.923, abs=1e-3)
    assert confidence(4, 4) == pytest.approx(0.952, abs=1e-3)
    assert confidence(2, 3) == pytest.approx(0.706, abs=1e-3)


def test_the_memory_suggests_a_strict_majority_only() -> None:
    memory = LabelMemory()
    memory.add("Мол 900г", "groceries/groceries")
    memory.add("МОЛ900Г", "groceries/groceries")
    memory.add("Хліб", "groceries/groceries")
    memory.add("Хліб", "other/other-spending")
    memory.add("--", "other/other-spending")

    suggestion = memory.suggest("мол 900 г")
    assert suggestion is not None
    assert (suggestion.slug, suggestion.labels, suggestion.agreeing) == (
        "groceries/groceries",
        2,
        2,
    )
    assert suggestion.confidence == pytest.approx(confidence(2, 2))
    assert memory.suggest("Хліб") is None  # one each: no majority
    assert memory.suggest("Сир") is None
    assert memory.suggest("--") is None  # an empty key is never stored
