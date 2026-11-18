"""The label scoring over a trie, with a fake character-level model."""

import math

import pytest

from app.categorise.labels import ANSWER_START, LabelSet, score_items, separator
from tests.categorise_helpers import SLUGS, FakeTokenModel, constrained_probability

MESSAGES = [{"role": "system", "content": "instructions"}, {"role": "user", "content": "items"}]


def test_every_label_gets_its_constrained_probability_and_they_add_up_to_one() -> None:
    model = FakeTokenModel({1: "household-shopping/pets"}, strength=1.5)

    results, _ = score_items(model, MESSAGES, SLUGS, 1)

    (probabilities,) = results
    assert math.isclose(sum(probabilities), 1.0)
    for slug, probability in zip(SLUGS, probabilities, strict=True):
        expected = constrained_probability(slug, SLUGS, "household-shopping/pets", 1.5)
        assert math.isclose(probability, expected, rel_tol=1e-9), slug
    assert max(range(len(SLUGS)), key=lambda i: probabilities[i]) == SLUGS.index(
        "household-shopping/pets"
    )


def test_a_label_outside_the_list_spreads_the_probability() -> None:
    model = FakeTokenModel({1: "made/up"})

    (probabilities,), _ = score_items(model, MESSAGES, SLUGS, 1)

    assert math.isclose(sum(probabilities), 1.0)
    assert max(probabilities) < 0.5


def test_items_are_scored_in_one_chat_with_the_earlier_answers_written_in() -> None:
    answers = {1: "groceries/groceries", 2: "health/health-pharmacy", 3: "other/other-spending"}
    model = FakeTokenModel(answers, strength=4.0)

    results, stats = score_items(model, MESSAGES, SLUGS, 3)

    best = [SLUGS[max(range(len(SLUGS)), key=lambda i: p[i])] for p in results]
    assert best == list(answers.values())
    text = "".join(chr(token) for token in model.cache)
    # The cache ends where item 3 is answered; items 1 and 2 hold their best slugs.
    assert text.endswith(
        ANSWER_START
        + 'groceries/groceries"'
        + separator(2)
        + 'health/health-pharmacy"'
        + separator(3)
    )
    assert [call[0] for call in model.calls].count("prefill") == 1
    assert stats.model_calls == sum(1 for call in model.calls if call[0] != "rewind")
    assert stats.prompt_tokens == model.calls[0][1]
    assert model.messages == [MESSAGES]


def test_only_the_points_where_labels_part_ways_cost_a_model_call() -> None:
    model = FakeTokenModel({1: "groceries/groceries"})

    _, stats = score_items(model, MESSAGES, ["aaaa/bbbb", "aaaa/cccc"], 1)

    # The shared "aaaa/" has probability 1: it is fed in one call, up to where they part.
    assert model.calls[1:] == [("feed", 5), ("rewind", 5)]
    assert stats.model_calls == 2


def test_a_deeper_split_is_fed_and_rewound() -> None:
    model = FakeTokenModel({1: "ab/cd"})

    (probabilities,), stats = score_items(model, MESSAGES, ["ab/cd", "ab/ce", "xy/z"], 1)

    assert [call[0] for call in model.calls] == ["prefill", "feed", "rewind"]
    assert stats.model_calls == 2
    assert math.isclose(sum(probabilities), 1.0)
    assert probabilities[0] > probabilities[1]


def test_a_label_that_starts_another_is_refused() -> None:
    class SplitModel(FakeTokenModel):
        def encode(self, text: str) -> list[int]:
            # A tokeniser that never emits the closing quote makes "a/b" a prefix of "a/bc".
            return [ord(char) for char in text if char != '"']

    with pytest.raises(ValueError, match="start of another"):
        LabelSet.build(SplitModel({}), ["a/b", "a/bc"])
    with pytest.raises(ValueError, match="start of another"):
        LabelSet.build(SplitModel({}), ["a/bc", "a/b"])
