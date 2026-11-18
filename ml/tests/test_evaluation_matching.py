"""Name normalisation, similarity and the one-to-one item matching, on hand-built cases."""

import pytest

from evaluation.matching import (
    MATCH_THRESHOLD,
    amount_agreement,
    decimal_or_none,
    match_items,
)
from evaluation.text import (
    levenshtein,
    normalise_merchant,
    normalise_name,
    plain,
    similarity,
)


def it(name: str, amount: str | None) -> dict:
    return {"name": name, "amount": amount}


# --- text ------------------------------------------------------------------------------------


def test_normalisation_folds_case_punctuation_units_and_look_alikes() -> None:
    assert normalise_name("Milk 2.5% 900g") == "milk 2 5 900 g"
    assert normalise_name("MILK 2,5 % 900 Г") == "milk 2 5 900 g"
    assert normalise_name("Молоко 1 Л") == normalise_name("молоко 1л")
    assert normalise_name("М'ясо") == normalise_name("Мʼясо") == normalise_name("Мясо")
    # A Latin C and a Cyrillic С print the same.
    assert normalise_name("Coca-Cola") == normalise_name("Сoса-Сola")
    assert normalise_name("Хліб  *  5 шт") == normalise_name("хліб 5 pcs")
    assert normalise_name("Ｂｒｅａｄ") == "bread"  # full-width letters (NFKC)
    assert normalise_name(None) == normalise_name("") == ""


def test_merchant_normalisation_drops_legal_forms() -> None:
    assert normalise_merchant('ТОВ "Сільпо-Фуд"') == normalise_merchant("Сільпо Фуд")
    assert normalise_merchant("ФОП Іваненко") == normalise_merchant("іваненко")
    assert normalise_merchant("Shop LLC") == "shop"
    assert normalise_merchant(None) == ""


def test_levenshtein_and_similarity_worked_by_hand() -> None:
    assert levenshtein("", "") == 0
    assert levenshtein("abc", "") == 3
    assert levenshtein("", "ab") == 2
    assert levenshtein("kitten", "sitting") == 3
    assert levenshtein("bred", "bread") == 1
    assert similarity("bred", "bread") == pytest.approx(0.8)
    assert similarity("", "") == 1.0
    assert similarity("abc", "xyz") == 0.0


def test_plain_keeps_case_and_collapses_spaces() -> None:
    assert plain("  Milk\t 2,5%  ") == "Milk 2,5%"
    assert plain(None) == ""


# --- amounts ---------------------------------------------------------------------------------


def test_amount_agreement() -> None:
    assert amount_agreement(decimal_or_none("40.00"), decimal_or_none("40.0")) == 1.0
    assert amount_agreement(decimal_or_none("30.00"), decimal_or_none("40.00")) == 0.75
    assert amount_agreement(decimal_or_none("-10.00"), decimal_or_none("10.00")) == 0.0
    assert amount_agreement(None, decimal_or_none("1.00")) == 0.0
    assert decimal_or_none("abc") is None
    assert decimal_or_none("NaN") is None
    assert decimal_or_none(12) is None


# --- matching --------------------------------------------------------------------------------


def counts(predicted: list[dict], reference: list[dict]) -> dict[str, int]:
    matching = match_items(predicted, reference)
    return {variant: len(matching.matched(variant)) for variant in ("strict", "main", "lenient")}


def test_swapped_order_matches_everything() -> None:
    reference = [it("Bread", "20.00"), it("Milk", "40.00"), it("Eggs", "55.10")]
    predicted = list(reversed(reference))
    matching = match_items(predicted, reference)
    assert sorted((p.predicted, p.reference) for p in matching.matched("strict")) == [
        (0, 2),
        (1, 1),
        (2, 0),
    ]


def test_a_missing_item_lowers_recall_only() -> None:
    reference = [it("Bread", "20.00"), it("Milk", "40.00")]
    assert counts([it("Bread", "20.00")], reference) == {"strict": 1, "main": 1, "lenient": 1}


def test_a_duplicated_prediction_matches_once() -> None:
    reference = [it("Bread", "20.00")]
    predicted = [it("Bread", "20.00"), it("Bread", "20.00")]
    assert counts(predicted, reference) == {"strict": 1, "main": 1, "lenient": 1}


def test_two_equal_reference_items_need_two_predictions() -> None:
    reference = [it("Bread", "20.00"), it("Bread", "20.00")]
    assert counts([it("Bread", "20.00")], reference)["main"] == 1
    assert counts([it("Bread", "20.00"), it("Bread", "20.00")], reference)["main"] == 2


def test_a_split_item_matches_at_most_once() -> None:
    reference = [it("Milk 2.5% 1 l", "40.00")]
    predicted = [it("Milk 2.5%", "20.00"), it("1 l", "20.00")]
    # "milk 2 5" against "milk 2 5 1 l": 1 - 4/12 = 0.667, a name match; the amount agrees to
    # 1 - 20/40 = 0.5, so the score is 0.4 + 0.2 = 0.6: lenient only. "1 l" matches nothing,
    # and the one reference item is matched once.
    assert counts(predicted, reference) == {"strict": 0, "main": 0, "lenient": 1}
    predicted = [it("Milk", "20.00"), it("2.5% 1 l", "20.00")]
    # "milk" against "milk 2 5 1 l": 1 - 8/12 = 0.333; "2 5 1 l": 1 - 5/12 = 0.583. No match.
    assert counts(predicted, reference) == {"strict": 0, "main": 0, "lenient": 0}


def test_a_merged_item_matches_one_of_two() -> None:
    reference = [it("Bread white", "20.00"), it("Bread black", "25.00")]
    predicted = [it("Bread white", "45.00")]
    # Name 1.0 with the first; amount 1 - 25/45 = 0.444: score 0.778, a main match, not strict.
    assert counts(predicted, reference) == {"strict": 0, "main": 1, "lenient": 1}


def test_amounts_decide_between_near_identical_names() -> None:
    reference = [it("Yogurt 2%", "30.00"), it("Yogurt 3%", "35.00")]
    predicted = [it("Yogurt 3%", "30.00"), it("Yogurt 2%", "35.00")]
    # Names point one way, amounts the other: the higher total score pairs them by name
    # (0.6 + 0.4 * 0.857 = 0.943 each) rather than by amount (0.6 * 0.875 + 0.4 = 0.925 each).
    matching = match_items(predicted, reference)
    assert sorted((p.predicted, p.reference) for p in matching.pairs) == [(0, 1), (1, 0)]
    assert len(matching.matched("strict")) == 0
    assert len(matching.matched("main")) == 2


def test_a_wrong_amount_with_a_good_name_is_lenient_only() -> None:
    reference = [it("Cheese", "100.00")]
    assert counts([it("Cheese", "10.00")], reference) == {"strict": 0, "main": 0, "lenient": 1}


def test_the_thresholds_are_inclusive() -> None:
    # Name 0.6 exactly (2 of 5 letters differ) with an exact amount: 0.6 * 0.6 + 0.4 = 0.76.
    reference = [it("abcde", "10.00")]
    matching = match_items([it("abcxy", "10.00")], reference)
    assert matching.pairs[0].name == pytest.approx(0.6)
    assert matching.pairs[0].score == pytest.approx(MATCH_THRESHOLD)
    assert counts([it("abcxy", "10.00")], reference) == {"strict": 1, "main": 1, "lenient": 1}
    assert counts([it("abxyz", "10.00")], reference) == {"strict": 0, "main": 0, "lenient": 0}


def test_empty_sides() -> None:
    assert counts([], [it("Bread", "1.00")]) == {"strict": 0, "main": 0, "lenient": 0}
    assert counts([it("Bread", "1.00")], []) == {"strict": 0, "main": 0, "lenient": 0}
    assert counts([it("Bread", "1.00")], [it("Zzz", "1.00")])["lenient"] == 0


def test_variants_nest() -> None:
    reference = [it("Bread", "20.00"), it("Milk", "40.00"), it("Tea", "70.00")]
    predicted = [it("Bred", "20.00"), it("Milk", "39.00"), it("Tea", "7.00")]
    result = counts(predicted, reference)
    assert result["strict"] <= result["main"] <= result["lenient"]
    assert result == {"strict": 1, "main": 2, "lenient": 3}


def test_unknown_variant() -> None:
    with pytest.raises(ValueError):
        match_items([it("a", "1.00")], [it("a", "1.00")]).matched("loose")
