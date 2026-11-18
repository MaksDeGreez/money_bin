"""Model identity: when two model names mean the same model, for the pre-fill rule.

The app records names exactly as the ML service reports them, but one model has several names: a
local quantised build (`mlx-community/Qwen3-VL-8B-Instruct-4bit`), the hosted id
(`qwen/qwen3-vl-8b-instruct`), a dated slug as `model_version` (`openai/gpt-4.1-mini-2025-04-14`,
`anthropic/claude-4.6-sonnet-20260217`). For the pre-fill rule they are one model: the same weights
answer much the same, so a person correcting one's answer leans towards all of them.

The rule must not be bypassed by a spelling, so two names count as **different models only with
proof**, and everything unexplained counts as **unknown** (the record is left out and counted).

**Reading a name** (`identity`):

1. Case is ignored; a backend prefix (`mlx:`, `openrouter:`, ...), a revision (`@main`), a file
   extension (`.gguf`) and a llama.cpp quantisation (`-Q4_K_M`) are dropped; only the last path
   segment counts (the publisher or host does not change the model); a routing suffix after `:`
   (`:free`, `:nitro`, `:thinking`) is dropped, any other `:` part (an Ollama size tag, `:7b`) is
   kept as words.
2. The name is cut at `-`, `_`, `.`, spaces, and between letters and digits (`qwen2.5vl` and
   `qwen-2.5-vl` both give `qwen 2 5 vl`), keeping sizes whole (`7b`, `235b`, `a22b`, `16e`).
3. Words that describe a build, not a model, are dropped: quantisation and number formats (`4bit`,
   `bf16`, `fp8`, `int4`, `mxfp4`, `w4a16`, `awq`, `gptq`, `dwq`, `bnb`, `qat`, `mixed`,
   `dynamic`), packaging (`mlx`, `gguf`, `hf`, `unsloth`), `instruct`, `chat`, `it`, `latest`,
   `preview`, `exp`, a reasoning effort (`high`, `low`), and every number of three or more digits
   (dates and releases: `2025 04 14`, `20260217`, `2507`, `001`).

What is left is the model's **family** (its first word: `qwen`, `llama`, `gemma`, `gpt`, `claude`,
`o`), its **sizes** (`8b`, `235b`, `a22b`), its **versions** (small numbers: `2 5`, `3`, `4 1`) and
its other words, among them **tier words** that name a different model of a family (`mini`, `nano`,
`pro`, `flash`, `lite`, `sonnet`, `opus`, `haiku`, `vl`, `thinking`, `coder`, `scout`, ...).

**Comparing two names** (`compare`): different families, two different size sets, two different
version lists, or a tier word on one side only prove different models (`different`); the same words
and versions (a size or a version given on one side only does not matter) are the same model
(`same`); anything else (a word the rules do not know) is `unknown`. A name that is a path on disk,
whose version is `local` (a model loaded from a folder: `ml/app/backends/mlx.py` reports that), or
that leaves no word, is `unknown` too.

**The rule** (`prefill_exclusion`): a record pre-filled by `source:hand` or `source:dps_xml` (or an
imported record, with no `prefilled_by`) counts for every model. It is left out of a run as
`same_model` when any of the record's names (`prefilled_by`, `prefilled_model_version`) is the same
model as any of the run's (`model_name`, `model_version`), and as `unknown` when the record says
`source:unknown-model` (or another `source:` value), or when not every pair is proved different. So
8B against 235B-A22B, Qwen2.5 against Qwen3, `gpt-4.1` against `gpt-4.1-mini` are different models,
and a name the rules cannot read leaves the receipt out. Categories follow the same rules with
`categories_prefilled_by` (`source:unknown`: left out for every categoriser).
"""

import re
from dataclasses import dataclass

BACKEND_PREFIXES = ("mlx:", "openrouter:", "stub:", "local:", "hosted:", "ollama:")
COUNTS_FOR_EVERY_MODEL = frozenset({"source:hand", "source:dps_xml"})
ROUTING_SUFFIXES = frozenset(
    {"free", "nitro", "floor", "online", "thinking", "extended", "beta", "latest"}
)
BUILD_WORDS = frozenset(
    {
        "mlx",
        "gguf",
        "hf",
        "awq",
        "gptq",
        "dwq",
        "bnb",
        "qat",
        "mixed",
        "dynamic",
        "unsloth",
        "instruct",
        "chat",
        "it",
        "latest",
        "preview",
        "exp",
        "high",
        "low",
        "bit",
        "quant",
        "quantized",
    }
)
BUILD_PATTERN = re.compile(r"\A(?:\d+bit|[a-z]*fp\d+|bf\d+|int\d+|w\d+a\d+|q\d+(?:_[a-z0-9]+)*)\Z")
TIER_WORDS = frozenset(
    {
        "mini",
        "nano",
        "micro",
        "small",
        "medium",
        "large",
        "pro",
        "flash",
        "lite",
        "max",
        "plus",
        "turbo",
        "ultra",
        "sonnet",
        "opus",
        "haiku",
        "vl",
        "omni",
        "thinking",
        "reasoning",
        "coder",
        "math",
        "scout",
        "maverick",
        "vision",
        "audio",
        "embed",
        "embedding",
        "guard",
    }
)
GGUF_SUFFIX = re.compile(r"[-_.]i?q\d+(?:_[a-z0-9]+)*\Z")
MIXED_BITS = re.compile(r"[-_]mixed[-_]\d+[-_]\d+bit")
DATE = re.compile(r"(?<!\d)\d{4}[-_.]\d{2}[-_.]\d{2}(?!\d)")
SIZE = re.compile(r"\A(?:\d+(?:\.\d+)?[bm]|a\d+b|\d+e)\Z")
PIECE = re.compile(r"a\d+b(?![a-z])|\d+[bm](?![a-z])|\d+e(?![a-z])|[a-z]+|\d+")
# A model version that is a revision, not a name: a commit hash or a fixed word.
REVISION = re.compile(r"\A(?:[0-9a-f]{7,64}|not-started|not-configured)\Z")


@dataclass(frozen=True)
class Identity:
    family: str
    sizes: frozenset[str]
    versions: tuple[str, ...]
    words: frozenset[str]
    certain: bool

    @property
    def tiers(self) -> frozenset[str]:
        return self.words & TIER_WORDS


UNKNOWN = Identity("", frozenset(), (), frozenset(), certain=False)


def is_path(name: str) -> bool:
    text = name.strip()
    return text.startswith(("/", "~/", "./", "../")) or text == "~" or "\\" in text


def _pieces(text: str) -> list[str]:
    pieces: list[str] = []
    for coarse in re.split(r"[-_.\s]+", text):
        if not coarse or coarse in BUILD_WORDS or BUILD_PATTERN.match(coarse):
            continue
        pieces.extend(PIECE.findall(coarse))
    return [
        piece
        for piece in pieces
        if piece not in BUILD_WORDS and not (piece.isdigit() and len(piece) >= 3)
    ]


def identity(name: str) -> Identity:
    text = name.strip()
    if not text or is_path(text):
        return UNKNOWN
    text = text.casefold()
    for prefix in BACKEND_PREFIXES:
        if text.startswith(prefix):
            text = text[len(prefix) :]
    text = text.split("@", 1)[0].rsplit("/", 1)[-1]
    text = re.sub(r"\.gguf\Z", "", text)
    if ":" in text:
        base, suffix = text.split(":", 1)
        text = base if suffix in ROUTING_SUFFIXES else f"{base}-{suffix}"
    text = GGUF_SUFFIX.sub("", MIXED_BITS.sub("", DATE.sub("", text)))
    pieces = _pieces(text)
    if not pieces or not pieces[0].isalpha():
        return UNKNOWN
    rest = pieces[1:]
    return Identity(
        family=pieces[0],
        sizes=frozenset(piece for piece in rest if SIZE.match(piece)),
        versions=tuple(piece for piece in rest if piece.isdigit()),
        words=frozenset(piece for piece in rest if not piece.isdigit() and not SIZE.match(piece)),
        certain=True,
    )


def compare(a: Identity, b: Identity) -> str:
    """`same`, `different` (proved) or `unknown`; see the module docstring."""
    if not a.certain or not b.certain:
        return "unknown"
    if a.family != b.family:
        return "different"
    if a.sizes and b.sizes and a.sizes != b.sizes:
        return "different"
    if a.versions and b.versions and a.versions != b.versions:
        return "different"
    if a.tiers != b.tiers:
        return "different"
    if a.words == b.words:
        return "same"
    return "unknown"


def _identities(*values: str | None) -> list[Identity]:
    """The identities of the names among `values` (revision hashes skipped); a version `local`
    (a model loaded from a folder) makes the whole set unknown."""
    texts = [value.strip() for value in values if isinstance(value, str) and value.strip()]
    if any(text.casefold() == "local" for text in texts):
        return [UNKNOWN]
    return [identity(text) for text in texts if not REVISION.match(text.casefold())]


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
    prefill = _identities(value, prefilled_version)
    run = _identities(*run_names)
    if not prefill or not run:
        return "unknown"
    outcomes = [compare(a, b) for a in prefill for b in run]
    if "same" in outcomes:
        return "same_model"
    if all(outcome == "different" for outcome in outcomes):
        return None
    return "unknown"
