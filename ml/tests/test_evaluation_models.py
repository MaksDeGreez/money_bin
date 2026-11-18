"""Model identity for the pre-fill rule: which names are the same model, which are proved
different, and which are unknown (left out)."""

import pytest

from evaluation.models import compare, identity, prefill_exclusion

SAME = [
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "qwen/qwen3-vl-8b-instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen/Qwen3-VL-8B-Instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-8bit", "mlx-community/Qwen3-VL-8B-Instruct-bf16"),
    ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", "qwen/qwen2.5-vl-7b-instruct"),
    ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", "qwen/qwen-2.5-vl-7b-instruct"),
    ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini-2025-04-14"),
    ("anthropic/claude-sonnet-4.6", "anthropic/claude-4.6-sonnet-20260217"),
    ("anthropic/claude-sonnet-4-6", "anthropic/claude-sonnet-4.6"),
    ("claude-3-5-sonnet-latest", "anthropic/claude-3.5-sonnet"),
    ("google/gemini-2.0-flash-001", "gemini-2.0-flash"),
    ("openai/o4-mini-high", "openai/o4-mini"),
    ("qwen/qwen3-vl-235b-a22b-instruct", "qwen/qwen3-vl-235b-a22b-instruct:free"),
    ("openrouter:qwen/qwen3-vl-235b-a22b-instruct", "Qwen3-VL-235B-A22B-Instruct-2507"),
    ("mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit", "qwen/qwen3-235b-a22b-2507"),
    (
        "mlx-community/Mistral-Small-3.1-24B-Instruct-2503-4bit",
        "mistralai/mistral-small-3.1-24b-instruct",
    ),
    ("unsloth/Qwen3-VL-8B-Instruct-GGUF", "Qwen3-VL-8B-Instruct-Q4_K_M.gguf"),
    ("Qwen3VL-8B-Instruct-Q8_0", "qwen/qwen3-vl-8b-instruct"),
    ("unsloth/gemma-3-27b-it-unsloth-bnb-4bit", "google/gemma-3-27b-it"),
    ("mlx-community/gemma-3-27b-it-qat-4bit", "google/gemma-3-27b-it"),
    ("RedHatAI/Qwen3-VL-8B-Instruct-FP8-dynamic", "qwen/qwen3-vl-8b-instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-mixed-4-6bit", "qwen/qwen3-vl-8b-instruct"),
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit-DWQ-053125", "qwen/qwen3-vl-8b-instruct"),
    ("Qwen/Qwen3-VL-8B-Instruct@main", "qwen/qwen3-vl-8b-instruct"),
    ("meta-llama/llama-4-scout", "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit"),
    ("ollama:qwen2.5vl:7b", "qwen/qwen2.5-vl-7b-instruct"),
]
DIFFERENT = [
    ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "qwen/qwen3-vl-235b-a22b-instruct"),
    ("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", "mlx-community/Qwen3-VL-8B-Instruct-4bit"),
    ("qwen/qwen2.5-vl-7b-instruct", "qwen/qwen2.5-vl-72b-instruct"),
    ("qwen2.5vl:7b", "qwen2.5vl:72b"),
    ("openai/gpt-4.1-mini", "openai/gpt-4.1"),
    ("openai/gpt-4o", "openai/gpt-4o-mini"),
    ("anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.6"),
    ("anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4.5"),
    ("qwen/qwen3-vl-8b-instruct", "qwen/qwen3-vl-8b-thinking"),
    ("qwen/qwen3-8b", "qwen/qwen3-vl-8b-instruct"),
    ("google/gemini-2.5-flash", "google/gemini-2.5-pro"),
    ("openai/gpt-4.1-mini", "anthropic/claude-sonnet-4.6"),
]
UNKNOWN = [
    ("openai/gpt-4", "openai/gpt-4o"),  # an unexplained word ("o")
    ("vendor/model-a", "vendor/model-a-special"),
    ("/Users/someone/models/qwen", "qwen/qwen3-vl-8b-instruct"),
]


@pytest.mark.parametrize(("a", "b"), SAME)
def test_the_same_base_model(a: str, b: str) -> None:
    assert compare(identity(a), identity(b)) == "same"
    assert compare(identity(b), identity(a)) == "same"


@pytest.mark.parametrize(("a", "b"), DIFFERENT)
def test_proved_different(a: str, b: str) -> None:
    assert compare(identity(a), identity(b)) == "different"


@pytest.mark.parametrize(("a", "b"), UNKNOWN)
def test_unknown_when_not_proved(a: str, b: str) -> None:
    assert compare(identity(a), identity(b)) == "unknown"


def test_paths_and_empty_names_are_uncertain() -> None:
    for name in ("/Users/someone/models/qwen", "~/models/qwen", "./qwen", "C:\\models\\qwen", "~"):
        assert not identity(name).certain
    assert not identity("4bit-mlx").certain  # nothing but build words
    assert not identity("2025-04-14").certain
    assert identity("~anthropic/claude-sonnet-latest").certain  # an alias, not a path


RUN_LOCAL = ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "fdcc572e8b05ba9d")
RUN_HOSTED = ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini-2025-04-14")
RUN_FOLDER = ("models/qwen8b", "local")


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
        ("openai/gpt-4o", None, ("openai/gpt-4", None), "unknown"),
        ("/Users/someone/models/qwen", None, RUN_HOSTED, "unknown"),
        # A model loaded from a folder (relative or not): any model's pre-fill is in doubt.
        ("openai/gpt-4.1-mini", None, RUN_FOLDER, "unknown"),
        ("openai/gpt-4.1-mini", None, ("/Users/someone/models/qwen", "local"), "unknown"),
        ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "local", RUN_HOSTED, "unknown"),
        ("source:hand", None, RUN_FOLDER, None),
        ("openai/gpt-4.1-mini", None, ("", None), "unknown"),
        # A pre-fill name that is only a revision hash identifies nothing.
        ("0123456789abcdef", None, RUN_HOSTED, "unknown"),
    ],
)
def test_prefill_exclusion(
    prefilled_by: str | None, version: str | None, run: tuple, expected: str | None
) -> None:
    assert prefill_exclusion(prefilled_by, version, run) == expected


def test_categories_use_their_own_unknown_marker() -> None:
    run = ("categoriser-a", None)
    marker = {"unknown_marker": "source:unknown"}
    assert prefill_exclusion("source:unknown", None, run, **marker) == "unknown"
    assert prefill_exclusion("categoriser-a", None, run, **marker) == "same_model"
    assert prefill_exclusion("categoriser-b", None, run, **marker) == "unknown"
    assert prefill_exclusion("othername-b", None, run, **marker) is None
