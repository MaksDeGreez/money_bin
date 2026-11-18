import json

import pytest

from app.ocr import prompt
from app.ocr.prompt import (
    ANSWER_SCHEMA,
    MAX_REPAIR_QUOTE,
    PROMPT_VERSION,
    SYSTEM_PROMPT,
    Repair,
    build_messages,
    user_prompt,
)


def test_the_prompt_version_is_a_short_stable_hash() -> None:
    assert len(PROMPT_VERSION) == 12
    assert int(PROMPT_VERSION, 16) >= 0
    assert prompt._version() == PROMPT_VERSION


def test_the_prompt_version_changes_with_the_schema(monkeypatch: pytest.MonkeyPatch) -> None:
    changed = {**ANSWER_SCHEMA, "required": ["items"]}
    monkeypatch.setattr(prompt, "ANSWER_SCHEMA", changed)

    assert prompt._version() != PROMPT_VERSION


def test_the_prompt_version_changes_with_the_instructions(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prompt, "_INSTRUCTIONS", prompt._INSTRUCTIONS + " ")

    assert prompt._version() != PROMPT_VERSION


def test_one_image_is_one_document() -> None:
    text = user_prompt(1)

    assert text.startswith("The image shows one paper document.")
    assert "overlapping" not in text


@pytest.mark.parametrize("count", [2, 3])
def test_several_images_are_parts_of_one_receipt(count: int) -> None:
    text = user_prompt(count)

    assert text.startswith(f"The {count} images are overlapping photos of ONE long receipt")
    assert "list each item only once" in text


def test_the_prompt_explains_the_field_mapping_and_slips() -> None:
    text = user_prompt(1)

    assert "card_slip" in text
    assert "last four digits" in text
    assert "fiscal number of the CASH REGISTER" in text
    assert "fiscal number of THIS RECEIPT" in text
    assert "Kyiv local time" in text


def test_no_images_is_an_error() -> None:
    with pytest.raises(ValueError, match="at least one image"):
        user_prompt(0)


def test_the_repair_prompt_quotes_the_answer_and_the_problems() -> None:
    text = user_prompt(1, Repair(previous='{"total": ', problems="not valid JSON"))

    assert "Problems: not valid JSON" in text
    assert '{"total": ' in text
    assert text.endswith("answer with the complete, corrected JSON object only.")


def test_the_repair_prompt_quotes_at_most_the_limit() -> None:
    text = user_prompt(1, Repair(previous="x" * (MAX_REPAIR_QUOTE + 50), problems="p"))

    assert "x" * MAX_REPAIR_QUOTE in text
    assert "x" * (MAX_REPAIR_QUOTE + 1) not in text


def test_messages_are_a_system_and_a_user_message() -> None:
    messages = build_messages(2)

    assert [message["role"] for message in messages] == ["system", "user"]
    assert messages[0]["content"] == SYSTEM_PROMPT
    assert messages[1]["content"] == user_prompt(2)


def test_the_schema_requires_every_field_and_allows_no_others() -> None:
    assert set(ANSWER_SCHEMA["required"]) == set(ANSWER_SCHEMA["properties"])
    assert ANSWER_SCHEMA["additionalProperties"] is False
    item = ANSWER_SCHEMA["properties"]["items"]["items"]
    assert set(item["required"]) == set(item["properties"])
    assert item["additionalProperties"] is False
    json.dumps(ANSWER_SCHEMA)  # serialisable for a constrained decoder
