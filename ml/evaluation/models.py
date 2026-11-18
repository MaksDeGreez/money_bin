"""Model identity: when two model names mean the same model, for the pre-fill rule.

The app records names exactly as the ML service reports them, but one model has several names: a
local quantised build (`mlx-community/Qwen3-VL-8B-Instruct-4bit`), the hosted id
(`qwen/qwen3-vl-8b-instruct`), a dated slug as `model_version` (`openai/gpt-4.1-mini-2025-04-14`,
`anthropic/claude-4.6-sonnet-20260217`). For the pre-fill rule they are one model: the same weights
answer much the same, so a person correcting one's answer leans towards all of them.

**The identity of a name** (`identity`), step by step:

1. Case is ignored and surrounding spaces dropped.
2. A backend prefix (`mlx:`, `openrouter:`, ...) and a routing suffix after `:` (`:free`,
   `:nitro`, `:thinking`) are dropped.
3. Only the last path segment counts: the publisher or host (`mlx-community/`, `qwen/`, `openai/`)
   does not change the model.
4. A date at the end is dropped (`-2025-04-14`, `-20260217`, a four-digit release such as `-2507`),
   and so is a llama.cpp quantisation (`-Q4_K_M`).
5. The rest is split into tokens at `-`, `_`, `.` and spaces; tokens that only describe the build
   are dropped: quantisation and number formats (`4bit`, `8bit`, `bf16`, `fp8`, `int4`, `mxfp4`,
   `w4a16`, `awq`, `gptq`, `dwq`), packaging (`mlx`, `gguf`, `hf`) and the instruction-tuning word
   (`instruct`, `chat`, `it`).
6. The identity is the sorted list of the remaining tokens, so the order of the words does not
   matter (`claude-4.6-sonnet` and `claude-sonnet-4-6` are one model).

So the same base model is the same whatever its quantisation, host, publisher or dated slug, while a
different size of a family (`8b` against `235b-a22b`), a different family or generation (`qwen2.5`
against `qwen3`), or a different tier (`gpt-4.1` against `gpt-4.1-mini`) is a different model.

**When in doubt, leave it out.** A name is *uncertain* when it is a path on disk (a local folder
model: its folder name says nothing reliable) or leaves no token. For the rule:

- a record pre-filled by `source:hand` or `source:dps_xml` (and an imported record, with no
  `prefilled_by`) counts for every model;
- a record pre-filled by `source:unknown-model`, by any other `source:` value, by an uncertain name,
  or by a model when the run's own model name is uncertain, is left out of every run (reason
  `unknown`);
- otherwise it is left out of a run whose model name or model version has the same identity as
  `prefilled_by` or `prefilled_model_version` (reason `same_model`).

Categories follow the same rules with `categories_prefilled_by` (`source:unknown`: left out for
every categoriser).
"""

import re
from dataclasses import dataclass

BACKEND_PREFIXES = ("mlx:", "openrouter:", "stub:", "local:", "hosted:")
COUNTS_FOR_EVERY_MODEL = frozenset({"source:hand", "source:dps_xml"})
BUILD_TOKENS = frozenset(
    {"mlx", "gguf", "hf", "awq", "gptq", "dwq", "instruct", "chat", "it", "bit", "quant"}
)
BUILD_PATTERN = re.compile(r"\A(?:\d+bit|q\d\w*|[a-z]*fp\d+|bf\d+|int\d+|w\d+a\d+)\Z")
DATE_SUFFIX = re.compile(r"[-_](?:\d{4}-\d{2}-\d{2}|\d{8}|\d{4})\Z")
# A llama.cpp quantisation at the end (`-Q4_K_M`, `.IQ3_XS`), whose `_` would split it into tokens.
GGUF_SUFFIX = re.compile(r"[-_.]i?q\d+(?:_[a-z0-9]+)*\Z")
# A model version that is a revision, not a name: a commit hash or a fixed word.
NOT_A_NAME = re.compile(r"\A(?:[0-9a-f]{7,64}|local|not-started|not-configured)\Z")


@dataclass(frozen=True)
class Identity:
    tokens: tuple[str, ...]
    certain: bool


def is_path(name: str) -> bool:
    return name.startswith(("/", "~", "./", "../")) or "\\" in name


def identity(name: str) -> Identity:
    text = name.strip()
    if is_path(text):
        return Identity((), certain=False)
    text = text.casefold()
    for prefix in BACKEND_PREFIXES:
        if text.startswith(prefix):
            text = text[len(prefix) :]
    text = text.rsplit("/", 1)[-1].split(":", 1)[0]
    previous = None
    while previous != text:
        previous = text
        text = GGUF_SUFFIX.sub("", DATE_SUFFIX.sub("", text))
    tokens = [
        token
        for token in re.split(r"[-_.\s]+", text)
        if token and token not in BUILD_TOKENS and not BUILD_PATTERN.match(token)
    ]
    return Identity(tuple(sorted(tokens)), certain=bool(tokens))


def identities(*names: str | None) -> list[Identity]:
    """The identities of the names that are names (not empty, not a revision hash)."""
    return [
        identity(name)
        for name in names
        if isinstance(name, str) and name.strip() and not NOT_A_NAME.match(name.strip().casefold())
    ]


def prefill_exclusion(
    prefilled_by: str | None,
    prefilled_version: str | None,
    run_names: tuple[str | None, ...],
    *,
    unknown_marker: str = "source:unknown-model",
) -> str | None:
    """Why a record pre-filled by `prefilled_by` is left out of a run of `run_names` (`same_model`
    or `unknown`), or None when it counts. See the module docstring."""
    if prefilled_by is None or not prefilled_by.strip():
        return None
    value = prefilled_by.strip()
    if value in COUNTS_FOR_EVERY_MODEL:
        return None
    if value.startswith("source:") or value == unknown_marker:
        return "unknown"
    prefill = identities(value, prefilled_version)
    run = identities(*run_names)
    if not run or any(not item.certain for item in (*prefill, *run)):
        return "unknown"
    if any(a.tokens == b.tokens for a in prefill for b in run):
        return "same_model"
    return None
