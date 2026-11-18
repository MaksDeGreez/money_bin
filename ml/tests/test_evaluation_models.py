"""Model identity for the pre-fill rule: which names are the same model."""

import pytest

from evaluation.models import identities, identity, prefill_exclusion

SAME = [
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "qwen/qwen3-vl-8b-instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen/Qwen3-VL-8B-Instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-8bit", "mlx-community/Qwen3-VL-8B-Instruct-bf16"),
    ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", "qwen/qwen2.5-vl-7b-instruct"),
    ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini-2025-04-14"),
    ("anthropic/claude-sonnet-4.6", "anthropic/claude-4.6-sonnet-20260217"),
    ("anthropic/claude-sonnet-4-6", "anthropic/claude-sonnet-4.6"),
    ("qwen/qwen3-vl-235b-a22b-instruct", "qwen/qwen3-vl-235b-a22b-instruct:free"),
    ("openrouter:qwen/qwen3-vl-235b-a22b-instruct", "Qwen3-VL-235B-A22B-Instruct-2507"),
    ("unsloth/Qwen3-VL-8B-Instruct-GGUF", "Qwen3-VL-8B-Instruct-Q4_K_M"),
]
DIFFERENT = [
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "qwen/qwen3-vl-235b-a22b-instruct"),
    ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", "mlx-community/Qwen3-VL-8B-Instruct-4bit"),
    ("openai/gpt-4.1-mini", "openai/gpt-4.1"),
    ("anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.6"),
    ("qwen/qwen3-vl-8b-instruct", "qwen/qwen3-vl-8b-thinking"),
]


@pytest.mark.parametrize(("a", "b"), SAME)
def test_the_same_base_model(a: str, b: str) -> None:
    assert identity(a) == identity(b)
    assert identity(a).certain


@pytest.mark.parametrize(("a", "b"), DIFFERENT)
def test_different_models(a: str, b: str) -> None:
    assert identity(a) != identity(b)


def test_paths_are_uncertain() -> None:
    for name in ("/Users/someone/models/qwen", "~/models/qwen", "./qwen", "C:\\models\\qwen"):
        assert not identity(name).certain
    assert not identity("4bit-mlx").certain  # nothing but build words


def test_revisions_are_not_names() -> None:
    assert identities("0123456789abcdef0123456789abcdef01234567", "local", None, "") == []
    assert len(identities("vendor/model-20260101")) == 1


RUN_LOCAL = ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "fdcc572e8b05ba9d")
RUN_HOSTED = ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini-2025-04-14")


@pytest.mark.parametrize(
    ("prefilled_by", "version", "run", "expected"),
    [
        (None, None, RUN_LOCAL, None),
        ("source:hand", None, RUN_LOCAL, None),
        ("source:dps_xml", None, RUN_LOCAL, None),
        ("source:unknown-model", None, RUN_LOCAL, "unknown"),
        ("source:something-new", None, RUN_LOCAL, "unknown"),
        ("qwen/qwen3-vl-8b-instruct", None, RUN_LOCAL, "same_model"),
        ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "fdcc572e", RUN_LOCAL, "same_model"),
        ("qwen/qwen3-vl-235b-a22b-instruct", None, RUN_LOCAL, None),
        ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini-2025-04-14", RUN_HOSTED, "same_model"),
        # The record names the dated slug only through its version.
        ("vendor/alias", "openai/gpt-4.1-mini-2025-04-14", RUN_HOSTED, "same_model"),
        ("mlx-community/Qwen3-VL-8B-Instruct-4bit", None, RUN_HOSTED, None),
        ("/Users/someone/models/qwen", None, RUN_HOSTED, "unknown"),
        # The run's own model is a local folder: any model's pre-fill is in doubt.
        ("openai/gpt-4.1-mini", None, ("/Users/someone/models/qwen", "local"), "unknown"),
        ("source:hand", None, ("/Users/someone/models/qwen", "local"), None),
        ("openai/gpt-4.1-mini", None, ("", None), "unknown"),
    ],
)
def test_prefill_exclusion(
    prefilled_by: str | None, version: str | None, run: tuple, expected: str | None
) -> None:
    assert prefill_exclusion(prefilled_by, version, run) == expected


def test_categories_use_their_own_unknown_marker() -> None:
    run = ("categoriser-a", None)
    assert prefill_exclusion("source:unknown", None, run, unknown_marker="source:unknown") == (
        "unknown"
    )
    assert prefill_exclusion("categoriser-a", None, run, unknown_marker="source:unknown") == (
        "same_model"
    )
    assert prefill_exclusion("categoriser-b", None, run, unknown_marker="source:unknown") is None
