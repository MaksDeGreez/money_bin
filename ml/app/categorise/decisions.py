"""The decision-model item categoriser (`CATEGORISE_BACKEND=decisions`).

A decision model answers a closed question with a probability for every option, which is what a
category needs: the answer cannot name a category outside the list, and the probabilities give a
confidence without parsing text or reading token log-probabilities. The client is
`app.decisions.DecisionsClient` (`DECISIONS_MODEL`), over the hosted OCR backend's zero-retention
code. Reasons and measurements: `docs/decisions/0016-decision-model-categoriser.md`.

**Strategies** (`DECISIONS_STRATEGY`):

- `flat`: one `choice` question per item over every listed category. Each option is labelled
  "Group / Name" (the name alone when it is the group's) and described by its description;
- `two-stage`: first a `choice` over the groups (each described by its categories), then a
  `choice` within the group for the `EXPAND_GROUPS` most likely groups of more than one category
  that have at least `EXPAND_MIN` probability (the most likely such group always). A category's
  score is P(group) x P(category | group); a category alone in its group scores P(group) with no
  second question. Categories of groups not opened get no score, so an item's scores add up to
  at most 1.

`verify` (offline for now; not part of `/categorise`): one `noul` question per proposed category,
"does this item belong to <category>?", whose probability becomes the proposal's score. It turns
another categoriser's answer into one with a confidence from an independent model.

**What is sent.** `state` holds item names only: with `DECISIONS_RECEIPT_CONTEXT` (the default)
one field per item of the receipt, `line_1`, `line_2`, ... (the neighbours show what kind of shop
it was), else one field `item` per request; and, when the request carries them, `examples`: names
of similar items a person labelled, each with its category's label. The questions hold the fixed
instructions below and the category names and descriptions (public text of the repository). The
merchant, amounts, dates and ids are not read here, so they cannot be sent. Names are trimmed and
their whitespace collapsed (the service does that already), and cut at `MAX_NAME_CHARS`.

**Batching.** Each item is its own question (the question key is not shown to the model, so each
question carries its full option text). A receipt's questions go in as few requests as fit
`DECISIONS_MAX_QUESTIONS` and `MAX_REQUEST_BYTES` (well below the ~32,000 bytes past which the
model switches to a slower, less accurate long-input mode). All requests of a receipt share its
`OPENROUTER_TIMEOUT` deadline.

**Answers.** Every answer is checked (`app.decisions.parse_answers`). The service needs at least one
candidate per item, so a refused item fails the receipt (422 `decisions_refused`; the app shows no
suggestion and does not retry). The probabilities vary by a few hundredths between identical calls;
each item is asked once and the answer kept, never asked again until two calls agree.
"""

import hashlib
import json
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from app.backends.base import BackendError
from app.backends.openrouter import Call, Transport, accounting
from app.categorise.base import (
    MAX_CANDIDATES,
    Candidate,
    Categorisation,
    CategoriseInput,
    Categoriser,
    top_candidates,
)
from app.categorise.prompt import CategoryOption
from app.config import Settings
from app.decisions import (
    Choice,
    ChoiceAnswer,
    Decision,
    DecisionsClient,
    Noul,
    NoulAnswer,
    Question,
    Refusal,
)

SCORE_KIND = "decision_probability"
# The request body stays below this many bytes (UTF-8 JSON).
MAX_REQUEST_BYTES = 24_000
# The most receipt lines given as context in one request (the asked ones always included).
MAX_CONTEXT_LINES = 40
MAX_NAME_CHARS = 120
EXPAND_GROUPS = 2
EXPAND_MIN = 0.05

ITEM_INTRO = (
    "is one line of a shop receipt: a product name as the till printed it, usually abbreviated "
    "and in Ukrainian."
)
RECEIPT_NOTE = (
    "The other `line_` fields are the other lines of the same receipt; they show what kind of shop "
    "it was."
)
EXAMPLES_NOTE = (
    "`examples` lists products a person has already categorised, each with its category; similar "
    "products usually share it."
)
FLAT_ASK = "Which spending category does the product in `{key}` belong to?"
GROUP_ASK = "Which group of spending categories does the product in `{key}` belong to?"
WITHIN_ASK = (
    "The product in `{key}` belongs to the group of spending categories “{group}”. Which category "
    "of that group is it?"
)
VERIFY_ASK = (
    "Does the product in `{key}` belong to the spending category “{label}”? That category is: "
    "{description}"
)
TEMPLATES = (ITEM_INTRO, RECEIPT_NOTE, EXAMPLES_NOTE, FLAT_ASK, GROUP_ASK, WITHIN_ASK, VERIFY_ASK)


def prompt_version(strategy: str, receipt_context: bool, *, examples: bool = False) -> str:
    """A hash of the fixed texts, the strategy (`flat`, `two-stage` or `verify`), the context
    shape and whether examples were shown (the category list has its own hash,
    `categories_version`). Each mode has its own, so a calibration fitted on one (verified
    yes-probabilities, answers with examples) never applies to another (`calibration.py` matches
    on the prompt version)."""
    text = json.dumps([TEMPLATES, strategy, receipt_context, examples, EXPAND_GROUPS, EXPAND_MIN])
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def refused() -> BackendError:
    return BackendError(
        422, "decisions_refused", "The decision model declined to categorise an item."
    )


def too_large() -> BackendError:
    return BackendError(
        422,
        "decisions_request_too_large",
        "One item's question with its category list is too long for the decision model's "
        "normal input mode; shorten the category descriptions.",
    )


def clean_name(name: str) -> str:
    return " ".join(name.split())[:MAX_NAME_CHARS]


# The category list as options --------------------------------------------------------------------


@dataclass(frozen=True)
class Options:
    """The request's categories as option labels, and their groups in order of appearance."""

    categories: tuple[CategoryOption, ...]
    labels: dict[str, str]  # slug -> label
    by_label: dict[str, str]  # label -> slug
    groups: dict[str, tuple[CategoryOption, ...]]  # group name -> its categories

    @classmethod
    def of(cls, categories: Sequence[CategoryOption]) -> "Options":
        labels = {
            c.slug: c.name if c.name == c.group else f"{c.group} / {c.name}" for c in categories
        }
        if len(set(labels.values())) != len(labels):
            labels = {c.slug: c.slug for c in categories}
        groups: dict[str, list[CategoryOption]] = {}
        for category in categories:
            groups.setdefault(category.group, []).append(category)
        return cls(
            categories=tuple(categories),
            labels=labels,
            by_label={label: slug for slug, label in labels.items()},
            groups={name: tuple(members) for name, members in groups.items()},
        )

    @staticmethod
    def text(category: CategoryOption) -> str:
        return category.description or category.name

    def flat_criteria(self) -> dict[str, str]:
        return {self.labels[c.slug]: self.text(c) for c in self.categories}

    def group_criteria(self) -> dict[str, str]:
        criteria = {}
        for name, members in self.groups.items():
            if len(members) == 1:
                criteria[name] = self.text(members[0])
            else:
                criteria[name] = "Categories: " + "; ".join(
                    f"{c.name} ({self.text(c).rstrip('.')})" for c in members
                )
        return criteria

    def within_labels(self, group: str) -> dict[str, str]:
        """Option label -> slug within a group: the names, or the slugs when names repeat."""
        members = self.groups[group]
        if len({c.name for c in members}) != len(members):
            return {c.slug: c.slug for c in members}
        return {c.name: c.slug for c in members}

    def within_criteria(self, group: str) -> dict[str, str]:
        slugs = {c.slug: c for c in self.groups[group]}
        return {label: self.text(slugs[slug]) for label, slug in self.within_labels(group).items()}


# Requests -----------------------------------------------------------------------------------------


@dataclass
class _Ask:
    item: int
    key: str
    question: Question


@dataclass
class _Work:
    """One receipt's requests: the input, the context mode, the accounting."""

    request: CategoriseInput
    receipt_context: bool
    options: Options
    deadline: float
    calls: list[Call] = field(default_factory=list)
    questions: int = 0

    def key(self, index: int) -> str:
        """The question key of an item: unique in the receipt, never shown to the model."""
        return f"line_{index + 1}"

    def state_field(self, index: int) -> str:
        """The state field that holds the item's name, as the instructions name it."""
        return f"line_{index + 1}" if self.receipt_context else "item"

    def has_examples(self, index: int) -> bool:
        examples = self.request.examples
        return bool(examples) and any(slug in self.options.labels for _, slug in examples[index])

    def instructions(self, index: int, ask: str) -> str:
        parts = [f"`{self.state_field(index)}` {ITEM_INTRO}"]
        if self.receipt_context:
            parts.append(RECEIPT_NOTE)
        if self.has_examples(index):
            parts.append(EXAMPLES_NOTE)
        parts.append(ask)
        return " ".join(parts)

    def state(self, items: Sequence[int]) -> dict[str, Any]:
        """Item names, and labelled examples when the request has them. Nothing else."""
        texts = self.request.texts
        if self.receipt_context:
            lines = list(dict.fromkeys(items))
            for index in range(len(texts)):
                if len(lines) >= MAX_CONTEXT_LINES:
                    break
                if index not in lines:
                    lines.append(index)
            state: dict[str, Any] = {
                f"line_{index + 1}": clean_name(texts[index]) for index in sorted(lines)
            }
        else:
            (index,) = set(items)
            state = {"item": clean_name(texts[index])}
        examples: dict[tuple[str, str], None] = {}
        if self.request.examples:
            for index in dict.fromkeys(items):
                for name, slug in self.request.examples[index]:
                    if slug in self.options.labels:
                        examples[(clean_name(name), slug)] = None
        if examples:
            state["examples"] = [
                {"item": name, "category": self.options.labels[slug]} for name, slug in examples
            ]
        return state


class DecisionsCategoriser(Categoriser):
    name = "decisions"

    def __init__(
        self,
        settings: Settings | None = None,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        super().__init__(settings)
        self.client = DecisionsClient(self.settings, transport=transport, clock=clock)
        self.model_name = self.client.model_name
        self.strategy = self.settings.decisions_strategy
        self.receipt_context = self.settings.decisions_receipt_context
        self.max_questions = self.settings.decisions_max_questions

    @property
    def model_version(self) -> str:  # type: ignore[override]
        return self.client.model_version

    @property
    def prompt_version(self) -> str:
        """The prompt version of `/categorise` answers (the service never sends examples)."""
        return prompt_version(self.strategy, self.receipt_context)

    def start(self) -> None:
        self.client.start()

    def stop(self) -> None:
        self.client.stop()

    # Requests ------------------------------------------------------------------------------

    def _size(self, work: _Work, asks: Sequence[_Ask]) -> int:
        body = {
            "model": self.client.model or "",
            "state": work.state([ask.item for ask in asks]),
            "questions": {ask.key: ask.question.as_json() for ask in asks},
            # More than the real preferences take (a few endpoint slugs, the privacy constants).
            "provider": {
                "only": ["x" * 60] * 4,
                "allow_fallbacks": True,
                "zdr": True,
                "data_collection": "deny",
            },
        }
        return len(json.dumps(body, ensure_ascii=False).encode())

    def _chunks(self, work: _Work, asks: Sequence[_Ask]) -> list[list[_Ask]]:
        """The asks cut into requests: one item per request without receipt context, else by
        `max_questions` and `MAX_REQUEST_BYTES`."""
        if not work.receipt_context:
            by_item: dict[int, list[_Ask]] = {}
            for ask in asks:
                by_item.setdefault(ask.item, []).append(ask)
            return [chunk for group in by_item.values() for chunk in self._cut(work, group)]
        return self._cut(work, asks)

    def _cut(self, work: _Work, asks: Sequence[_Ask]) -> list[list[_Ask]]:
        chunks: list[list[_Ask]] = []
        current: list[_Ask] = []
        for ask in asks:
            trial = [*current, ask]
            if current and (
                len(trial) > self.max_questions or self._size(work, trial) > MAX_REQUEST_BYTES
            ):
                chunks.append(current)
                current = [ask]
            else:
                current = trial
        if current:
            chunks.append(current)
        if any(len(chunk) == 1 and self._size(work, chunk) > MAX_REQUEST_BYTES for chunk in chunks):
            raise too_large()
        return chunks

    def _ask(self, work: _Work, asks: Sequence[_Ask]) -> dict[str, Any]:
        """Every ask answered, in as few requests as fit. Raises `BackendError`."""
        answers: dict[str, Any] = {}
        for chunk in self._chunks(work, asks):
            decision: Decision = self.client.decide(
                work.state([ask.item for ask in chunk]),
                {ask.key: ask.question for ask in chunk},
                work.deadline,
                work.calls,
            )
            work.questions += len(chunk)
            answers.update(decision.answers)
        return answers

    def _work(self, request: CategoriseInput) -> _Work:
        if request.examples and len(request.examples) != len(request.texts):
            raise ValueError("examples, when given, are one tuple per item")
        return _Work(
            request=request,
            receipt_context=self.receipt_context,
            options=Options.of(request.categories),
            deadline=time.perf_counter() + self.settings.openrouter_timeout,
        )

    def _result(self, work: _Work, candidates: list[list[Candidate]], mode: str) -> Categorisation:
        examples = any(work.has_examples(i) for i in range(len(work.request.texts)))
        return Categorisation(
            candidates=candidates,
            score_kind=SCORE_KIND,  # type: ignore[arg-type]
            prompt_version=prompt_version(mode, self.receipt_context, examples=examples),
            diagnostics={
                **accounting(work.calls),
                "strategy": self.strategy,
                "receipt_context": self.receipt_context,
                "questions": work.questions,
            },
        )

    def _run(
        self, work: _Work, body: Callable[[], list[list[Candidate]]], mode: str
    ) -> Categorisation:
        try:
            candidates = body()
        except BackendError as error:
            error.diagnostics = accounting(work.calls)
            raise
        return self._result(work, candidates, mode)

    # Strategies ---------------------------------------------------------------------------

    def categorise(self, request: CategoriseInput) -> Categorisation:
        """Categorise one receipt's items with the configured strategy."""
        work = self._work(request)
        if self.strategy == "two-stage":
            return self._run(work, lambda: self._two_stage(work), self.strategy)
        return self._run(work, lambda: self._flat(work), self.strategy)

    def _flat(self, work: _Work) -> list[list[Candidate]]:
        criteria = work.options.flat_criteria()
        asks = [
            _Ask(i, work.key(i), Choice(work.instructions(i, FLAT_ASK.format(key=name)), criteria))
            for i in range(len(work.request.texts))
            for name in [work.state_field(i)]
        ]
        answers = self._ask(work, asks)
        result = []
        for ask in asks:
            answer = answers[ask.key]
            if isinstance(answer, Refusal):
                raise refused()
            assert isinstance(answer, ChoiceAnswer)
            scores = {work.options.by_label[label]: p for label, p in answer.normalised().items()}
            candidates = [c for c in top_candidates(scores) if c.score > 0]
            result.append(candidates or top_candidates(scores, 1))
        return result

    def _two_stage(self, work: _Work) -> list[list[Candidate]]:
        options = work.options
        group_criteria = options.group_criteria()
        texts = work.request.texts
        first = [
            _Ask(
                i,
                work.key(i),
                Choice(work.instructions(i, GROUP_ASK.format(key=name)), group_criteria),
            )
            for i in range(len(texts))
            for name in [work.state_field(i)]
        ]
        answers = self._ask(work, first)
        scores: list[dict[str, float]] = [{} for _ in texts]
        second: list[_Ask] = []
        opened: dict[str, tuple[int, str, float]] = {}
        for ask in first:
            answer = answers[ask.key]
            if isinstance(answer, Refusal):
                raise refused()
            assert isinstance(answer, ChoiceAnswer)
            groups = answer.normalised()
            ranked = sorted(groups, key=lambda name: (-groups[name], list(groups).index(name)))
            # A category alone in its group needs no second question, so only groups of
            # several categories compete for the `EXPAND_GROUPS` places.
            several = [name for name in ranked if len(options.groups[name]) > 1]
            to_open = [
                name
                for rank, name in enumerate(several[:EXPAND_GROUPS])
                if rank == 0 or groups[name] >= EXPAND_MIN
            ]
            for name, probability in groups.items():
                members = options.groups[name]
                if len(members) == 1:
                    scores[ask.item][members[0].slug] = probability
                elif name in to_open:
                    key = f"{work.key(ask.item)}_g{ranked.index(name) + 1}"
                    instructions = work.instructions(
                        ask.item, WITHIN_ASK.format(key=work.state_field(ask.item), group=name)
                    )
                    second.append(
                        _Ask(ask.item, key, Choice(instructions, options.within_criteria(name)))
                    )
                    opened[key] = (ask.item, name, probability)
        if second:
            answers = self._ask(work, second)
            for ask in second:
                answer = answers[ask.key]
                index, name, probability = opened[ask.key]
                if isinstance(answer, Refusal):
                    if ask.key.endswith("_g1"):
                        # The most likely group overall was refused: no answer is better than
                        # one from the groups the model found less likely. A refusal for any
                        # other group only drops that group.
                        raise refused()
                    continue
                assert isinstance(answer, ChoiceAnswer)
                labels = options.within_labels(name)
                for category, value in answer.normalised().items():
                    scores[index][labels[category]] = probability * value
        result = []
        for item_scores in scores:
            candidates = top_candidates({s: p for s, p in item_scores.items() if p > 0})
            if not candidates:
                raise refused()
            result.append(candidates)
        return result

    def verify(
        self, request: CategoriseInput, proposals: Sequence[Sequence[str]]
    ) -> Categorisation:
        """Check the categories another categoriser proposed (offline; not part of `/categorise`).

        `proposals[i]`: up to `MAX_CANDIDATES` slugs proposed for item i, best first; slugs not in
        the request's categories are skipped. Each becomes one `noul` question; its probability is
        the proposal's score, and the verified proposals are ranked by it. An item with nothing to
        verify, or whose questions were all refused, gets no candidates. Unlike `categorise`, the
        scores are separate yes-probabilities and may add up to more than 1; that is why `verify`
        is not part of `/categorise`.
        """
        if len(proposals) != len(request.texts):
            raise ValueError("verify needs one list of proposals per item")
        work = self._work(request)

        def body() -> list[list[Candidate]]:
            options = work.options
            asks = []
            asked: dict[str, tuple[int, int, str]] = {}
            for index, slugs in enumerate(proposals):
                known = [s for s in dict.fromkeys(slugs) if s in options.labels]
                for rank, slug in enumerate(known[:MAX_CANDIDATES]):
                    category = next(c for c in options.categories if c.slug == slug)
                    key = f"{work.key(index)}_c{rank + 1}"
                    ask = VERIFY_ASK.format(
                        key=work.state_field(index),
                        label=options.labels[slug],
                        description=options.text(category),
                    )
                    asks.append(_Ask(index, key, Noul(work.instructions(index, ask))))
                    asked[key] = (index, rank, slug)
            answers = self._ask(work, asks) if asks else {}
            verified: list[list[tuple[int, str, float]]] = [[] for _ in request.texts]
            for key, (index, rank, slug) in asked.items():
                answer = answers[key]
                if isinstance(answer, NoulAnswer):
                    verified[index].append((rank, slug, answer.probability))
            return [
                [
                    Candidate(slug, probability)
                    for _, slug, probability in sorted(entries, key=lambda e: (-e[2], e[0]))
                ]
                for entries in verified
            ]

        return self._run(work, body, "verify")


def criteria_size(categories: Sequence[CategoryOption]) -> Mapping[str, int]:
    """Bytes of option text one question carries, per strategy (for the batching notes)."""
    options = Options.of(categories)

    def size(criteria: Mapping[str, str]) -> int:
        return len(json.dumps(criteria, ensure_ascii=False).encode())

    within = [size(options.within_criteria(g)) for g, m in options.groups.items() if len(m) > 1]
    return {
        "flat": size(options.flat_criteria()),
        "group": size(options.group_criteria()),
        "within_max": max(within, default=0),
    }
