"""Name normalisation, similarity and the one-to-one item matching, on hand-built cases."""

import pytest

from evaluation.matching import (
    MATCH_THRESHOLD,
    amount_agreement,
    decimal_or_none,
    match_items,
)
from evaluation.text import (
    LEGAL_FORMS,
    LOOK_ALIKES,
    NORMALISATION_VERSION,
    UNITS,
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


def test_a_whole_word_in_the_other_script_folds() -> None:
    # Every letter of `СОСА` is Cyrillic, every letter of `COCA` Latin.
    assert normalise_name("СОСА КОКО") == normalise_name("COCA KOKO") == "coca koko"
    assert similarity(normalise_name("ТЕХАС"), normalise_name("TEXAC")) == 1.0


def test_case_and_script_mix_freely() -> None:
    # Capitals and small letters of both scripts, in any mix, end the same.
    spellings = ["Coca", "COCA", "сОСа", "СoСa", "cOcA", "СОСА", "сoca"]
    assert {normalise_name(spelling) for spelling in spellings} == {"coca"}
    # `В`/`B` look alike only as capitals; small `в` still joins `b`, since case goes first.
    assert normalise_name("ВЕВ") == normalise_name("веb") == normalise_name("BEB")
    assert normalise_name("НОМ") == normalise_name("hом") == normalise_name("HOM")


def test_yi_and_the_rare_cyrillic_letters_fold() -> None:
    assert normalise_name("ЇЖАК") == normalise_name("ÏЖAK") == normalise_name("їжак")
    assert normalise_name("ї") == normalise_name("Ï") == "ï"
    # A combining diaeresis is composed by NFKC first.
    assert normalise_name("ї") == normalise_name("ï") == "ï"
    # ї is not і: the diaeresis is a letter of its own.
    assert normalise_name("ї") != normalise_name("і")
    assert normalise_name("ЈЅҺ") == normalise_name("јѕһ") == normalise_name("JSH") == "jsh"


def test_letters_alike_only_in_italics_and_digits_stay_apart() -> None:
    for cyrillic, latin in [("п", "n"), ("и", "u"), ("г", "r"), ("ь", "b"), ("т", "m")]:
        assert normalise_name(f"x{cyrillic}x") != normalise_name(f"x{latin}x")
    assert normalise_name("ё") != normalise_name("ë")
    assert normalise_name("ё") != normalise_name("е")
    # Digits are never folded: `О`/`0`, `З`/`3`, `б`/`6`.
    assert normalise_name("1О0") == "1 o 0"
    assert normalise_name("ЗОО") != normalise_name("300")
    assert normalise_name("З") != normalise_name("3")
    assert normalise_name("б") != normalise_name("6")


@pytest.mark.parametrize(
    ("a", "b"),
    [
        ("СОСА-КОЛА 0,5Л", "Coca-Кола 0.5 l"),
        ("ЇЖАК", "Ïжак"),
        ("Молоко 2,5%", "MOЛOKO 2.5"),
        # Partly alike: a similarity between the threshold and 1.
        ("СМЕТАНА 15% 400Г", "Cmetaha 15 % 40 r"),
    ],
)
def test_similarity_is_symmetric(a: str, b: str) -> None:
    assert similarity(normalise_name(a), normalise_name(b)) == similarity(
        normalise_name(b), normalise_name(a)
    )
    forward = match_items([it(a, "1.00")], [it(b, "1.00")])
    backward = match_items([it(b, "1.00")], [it(a, "1.00")])
    assert len(forward.matched("main")) == 1
    for variant in ("main", "strict", "lenient"):
        assert [pair.name for pair in forward.matched(variant)] == [
            pair.name for pair in backward.matched(variant)
        ]


def test_a_look_alike_swap_inside_a_unit_or_a_legal_form() -> None:
    # Units and legal forms are recognised by their folded spelling: one Latin letter in them
    # costs nothing, as anywhere else.
    for cyrillic, swapped, unit in [
        ("1 ШТ", "1 ШT", "1 pcs"),
        ("1 УП", "1 YП", "1 pack"),
        ("100 ГР", "100 ГP", "100 g"),
        ("1 КГ", "1 KГ", "1 kg"),
        ("500 МЛ", "500 MЛ", "500 ml"),
    ]:
        assert normalise_name(cyrillic) == normalise_name(swapped) == unit
    assert normalise_merchant("TОВ Квітка") == normalise_merchant("ТОВ Квітка")
    assert normalise_merchant("ФOП Іваненко") == normalise_merchant("Іваненко")
    # A unit is still a token of its own, and no Latin word becomes one.
    assert normalise_name("гречка") != normalise_name("g")
    assert normalise_name("kr yn") == "kr yn"


def test_the_tables_are_pinned_to_the_version() -> None:
    # A change to any table is a new rule: move NORMALISATION_VERSION with it.
    assert NORMALISATION_VERSION == 2
    assert {chr(key): chr(value) for key, value in LOOK_ALIKES.items()} == dict(
        zip("аеорсухікмнтвїјѕһ", "aeopcyxikmhtbïjsh", strict=True)
    )
    assert UNITS == {
        "кг": "kg",
        "г": "g",
        "гр": "g",
        "л": "l",
        "мл": "ml",
        "шт": "pcs",
        "уп": "pack",
    }
    assert sorted(LEGAL_FORMS) == sorted(
        ["тов", "фоп", "пп", "прат", "пат", "ат", "дп", "кп", "llc", "ltd", "tov", "fop"]
    )


def test_merchant_normalisation_drops_legal_forms() -> None:
    assert normalise_merchant('ТОВ "Квітка-Фуд"') == normalise_merchant("Квітка Фуд")
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
    # Name 1.0 with the first; amount 1 - 25/45 = 0.444: score 0.5 + 0.222 = 0.722, below 0.8.
    assert counts(predicted, reference) == {"strict": 0, "main": 0, "lenient": 1}
    predicted = [it("Bread white", "24.00")]
    # Amount 1 - 4/24 = 0.833: score 0.917, a main match with the first item only.
    assert counts(predicted, reference) == {"strict": 0, "main": 1, "lenient": 1}


def test_amounts_tell_apart_equal_names() -> None:
    reference = [it("Yogurt 2%", "30.00"), it("Yogurt 2%", "45.00")]
    predicted = [it("Yogurt 2%", "45.00"), it("Yogurt 2%", "30.00")]
    matching = match_items(predicted, reference)
    assert [(p.predicted, p.reference) for p in matching.matched("strict")] == [(0, 1), (1, 0)]
    assert [(p.predicted, p.reference) for p in matching.matched("main")] == [(0, 1), (1, 0)]


def test_near_identical_names_with_swapped_amounts() -> None:
    reference = [it("Yogurt 2%", "30.00"), it("Yogurt 3%", "35.00")]
    predicted = [it("Yogurt 3%", "30.00"), it("Yogurt 2%", "35.00")]
    # By name: 0.5 + 0.5 * (1 - 5/35) = 0.929 each. By amount: 0.5 * 0.875 + 0.5 = 0.9375 each.
    # Both give two main pairs; the higher total pairs them by amount, which also makes them
    # strict (the names are 0.875 alike, above 0.6).
    matching = match_items(predicted, reference)
    assert [(p.predicted, p.reference) for p in matching.matched("main")] == [(0, 0), (1, 1)]
    assert counts(predicted, reference) == {"strict": 2, "main": 2, "lenient": 2}


def test_an_extra_prediction_never_takes_a_match_away() -> None:
    reference = [it("abcdefghij", "10.00"), it("abcdefxxxx", "9.00")]
    right = [it("abcdefghij", "10.00")]
    assert counts(right, reference) == {"strict": 1, "main": 1, "lenient": 1}
    # The junk line is 10/11 like the first item and 0.6 like nothing else: it may pair up for
    # lenient (the first prediction then takes the second item, name 0.6), never for main.
    junk = [*right, it("abcdefghijk", "20.00")]
    assert counts(junk, reference) == {"strict": 1, "main": 1, "lenient": 2}


def test_a_wrong_amount_with_a_good_name_is_lenient_only() -> None:
    reference = [it("Cheese", "100.00")]
    assert counts([it("Cheese", "10.00")], reference) == {"strict": 0, "main": 0, "lenient": 1}
    # 40% off the larger amount is the limit for an exact name: 1 - 40/100 = 0.6, score 0.8.
    assert counts([it("Cheese", "60.00")], reference)["main"] == 1
    assert counts([it("Cheese", "59.99")], reference)["main"] == 0


def test_the_thresholds_are_inclusive() -> None:
    # Name 0.6 exactly (2 of 5 letters differ) with an exact amount: 0.5 * 0.6 + 0.5 = 0.8.
    reference = [it("abcde", "10.00")]
    (pair,) = match_items([it("abcxy", "10.00")], reference).matched("main")
    assert pair.name == pytest.approx(0.6)
    assert pair.score == pytest.approx(MATCH_THRESHOLD)
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
