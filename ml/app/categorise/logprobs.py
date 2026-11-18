"""Scores from a hosted model's token log-probabilities.

A hosted endpoint does not let this code score every category (that needs the
model's logits at chosen points, which only a local model gives). What some
endpoints return is, for each token of the answer, its log-probability and the
few most likely alternatives (`logprobs`, `top_logprobs`). From those:

- the chosen slug's score is the product of the probabilities of the tokens
  that spell it (the tokens overlapping the JSON string value);
- an alternative token at one of those positions that, after the text chosen
  before it, can only lead to ONE other listed slug gives that slug the
  probability of the chosen tokens before it times the alternative's own; an
  alternative that leads to several slugs, or to none, is not attributed;
- the scores are probabilities of disjoint answers, so they add up to at most 1
  (scaled down to 1 if an endpoint's numbers are inconsistent).

Whether an endpoint reports the probabilities before or after the structured
output masked impossible tokens is not documented, so these scores are the
model's token probabilities of its answer, not a distribution over the listed
categories (`score_kind` `token_logprobs`), and they need calibration before
they mean a precision.
"""

import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from app.categorise.base import Candidate, top_candidates


@dataclass(frozen=True)
class _Token:
    text: str
    logprob: float
    start: int
    end: int
    alternatives: tuple[tuple[str, float], ...]


def _number(value: Any) -> float | None:
    """A log-probability: a finite number at most 0 (answers are parsed with `Decimal`)."""
    if isinstance(value, bool) or not isinstance(value, int | float | Decimal):
        return None
    number = float(value)
    return number if math.isfinite(number) and number <= 0.0 else None


def _tokens(content: Sequence[Any]) -> list[_Token] | None:
    tokens = []
    position = 0
    for entry in content:
        if not isinstance(entry, Mapping) or not isinstance(entry.get("token"), str):
            return None
        logprob = _number(entry.get("logprob"))
        if logprob is None:
            return None
        alternatives = []
        for alternative in entry.get("top_logprobs") or []:
            if isinstance(alternative, Mapping) and isinstance(alternative.get("token"), str):
                value = _number(alternative.get("logprob"))
                if value is not None:
                    alternatives.append((alternative["token"], value))
        text = entry["token"]
        tokens.append(_Token(text, logprob, position, position + len(text), tuple(alternatives)))
        position += len(text)
    return tokens


def _value_spans(text: str, count: int) -> list[tuple[int, int]] | None:
    """The character span of each item's string value in the answer text, in order."""
    spans = []
    position = 0
    for number in range(1, count + 1):
        match = re.compile(rf'"{number}"\s*:\s*"([^"\\]*)"').search(text, position)
        if match is None:
            return None
        spans.append((match.start(1), match.end(1)))
        position = match.end()
    return spans


def item_scores(
    answer: str,
    content: Sequence[Any] | None,
    chosen: Sequence[str],
    slugs: Sequence[str],
) -> list[list[Candidate]] | None:
    """Candidates per item from the log-probabilities, or None when they cannot be read.

    `chosen` are the slugs the answer names, in item order. None when there are
    no log-probabilities, or their tokens do not spell the answer.
    """
    if not content:
        return None
    tokens = _tokens(content)
    if tokens is None or "".join(token.text for token in tokens) != answer:
        return None
    spans = _value_spans(answer, len(chosen))
    if spans is None:
        return None
    results = []
    for slug, (start, end) in zip(chosen, spans, strict=True):
        if answer[start:end] != slug:
            return None
        inside = [token for token in tokens if token.start < end and token.end > start]
        scores: dict[str, float] = {}
        before = 0.0
        for token in inside:
            typed = answer[start : max(start, token.start)]
            outside = answer[token.start : start] if token.start < start else ""
            for alternative, logprob in token.alternatives:
                if alternative == token.text or not alternative.startswith(outside):
                    continue
                text = typed + alternative[len(outside) :]
                complete = '"' in text
                text = text.split('"', 1)[0]
                # Counted with the chosen slug: a prefix that could still be it is ambiguous.
                reachable = [
                    other
                    for other in slugs
                    if (other == text if complete else other.startswith(text))
                ]
                if len(reachable) == 1 and reachable[0] != slug:
                    other = reachable[0]
                    scores[other] = scores.get(other, 0.0) + math.exp(before + logprob)
            before += token.logprob
        scores[slug] = math.exp(before)
        total = sum(scores.values())
        if total > 1.0:
            scores = {key: value / total for key, value in scores.items()}
        results.append(top_candidates(scores))
    return results
