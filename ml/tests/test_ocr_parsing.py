import pytest

from app.ocr.parsing import (
    AnswerError,
    OcrParseError,
    RawReceipt,
    parse_answer,
    read_with_repair,
)
from app.ocr.prompt import Repair

VALID = '{"kind": "fiscal", "total": "12,50", "items": [{"name": "Tea", "amount": "12,50"}]}'


def test_a_valid_answer_is_read() -> None:
    raw = parse_answer(VALID)

    assert raw.kind == "fiscal"
    assert raw.total == "12,50"
    assert raw.items is not None
    assert raw.items[0].name == "Tea"
    assert raw.items[0].quantity is None


def test_text_around_the_object_and_code_fences_are_ignored() -> None:
    raw = parse_answer(f"Here is the receipt:\n```json\n{VALID}\n```\nDone.")

    assert raw.total == "12,50"


def test_json_numbers_become_their_exact_text() -> None:
    raw = parse_answer(
        '{"total": 12.50, "items": [{"name": "Tea", "amount": 3, "discount": 0.10}]}'
    )

    assert raw.total == "12.50"
    assert raw.items is not None
    assert raw.items[0].amount == "3"
    assert raw.items[0].discount == "0.10"


def test_numbers_are_parsed_as_decimals_not_floats() -> None:
    raw = parse_answer('{"total": 0.1000000000000000055511151231257827}')

    # A float would have turned this into 0.1.
    assert raw.total == "0.1000000000000000055511151231257827"


def test_missing_keys_count_as_null_and_extra_keys_are_ignored() -> None:
    raw = parse_answer('{"merchant": "Shop", "note": "extra"}')

    assert raw == RawReceipt(merchant="Shop")


@pytest.mark.parametrize(
    ("text", "problem"),
    [
        ("no json here", "contains no JSON object"),
        ("} {", "contains no JSON object"),
        ('{"total": "1.00",}', "not valid JSON"),
        ('{"total": "1.00"', "contains no JSON object"),
        ('{"total": true}', "total: string_type"),
        ('{"total": ["1"]}', "total: string_type"),
        ('{"items": {}}', "items: list_type"),
        ('{"items": [1]}', "items.0: model_type"),
        ('{"items": [{"name": "x", "amount": {}}]}', "items.0.amount: string_type"),
    ],
)
def test_unreadable_answers_name_the_problem(text: str, problem: str) -> None:
    with pytest.raises(AnswerError) as error:
        parse_answer(text)

    assert problem in error.value.problems


def test_problems_never_quote_the_values() -> None:
    with pytest.raises(AnswerError) as error:
        parse_answer('{"merchant": ["Secret Shop"], "total": {"v": "999.99"}}')

    assert "Secret" not in error.value.problems
    assert "999" not in error.value.problems


def test_many_problems_are_cut_short() -> None:
    items = ", ".join(['{"name": true}'] * 9)

    with pytest.raises(AnswerError) as error:
        parse_answer(f'{{"items": [{items}]}}')

    assert error.value.problems.endswith("4 more")


class Model:
    """Answers from a list and records the repair requests."""

    def __init__(self, *answers: str) -> None:
        self.answers = list(answers)
        self.requests: list[Repair | None] = []

    def __call__(self, repair: Repair | None) -> str:
        self.requests.append(repair)
        return self.answers.pop(0)


def test_a_good_first_answer_needs_no_repair() -> None:
    model = Model(VALID)

    parsed = read_with_repair(model)

    assert parsed.repaired is False
    assert parsed.receipt.total == "12,50"
    assert model.requests == [None]


def test_a_bad_first_answer_is_repaired_once() -> None:
    model = Model('{"total": ', VALID)

    parsed = read_with_repair(model)

    assert parsed.repaired is True
    assert parsed.receipt.kind == "fiscal"
    first, second = model.requests
    assert first is None
    assert second == Repair(previous='{"total": ', problems="the answer contains no JSON object")


def test_two_bad_answers_raise_a_parse_error() -> None:
    model = Model("nothing", '{"total": true}')

    with pytest.raises(OcrParseError) as error:
        read_with_repair(model)

    assert len(model.requests) == 2
    assert error.value.problems == (
        "first answer: the answer contains no JSON object; "
        "after one repair pass: total: string_type"
    )
    assert str(error.value).startswith("The model's answer was not valid receipt JSON: ")
    assert error.value.diagnostics == {}
