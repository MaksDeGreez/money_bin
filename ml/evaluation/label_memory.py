"""The label memory, as the Rails app applies it, for offline runs.

The rule is the app's (`app/queries/label_memory.rb`, `docs/domain.md`, "Label
memory"); this is its twin for the evaluation, which reads files, not the
database. Both normalise names the same way, checked by the shared cases in
`tests/fixtures/item_name_keys.json` that the Ruby and the Python tests read.

- **The key** of an item name: Unicode NFKC, lower case, Latin letters that
  look like Cyrillic ones in print (a, b, c, e, h, i, k, m, o, p, t, x, y)
  turned into those Cyrillic letters, then everything but letters and digits
  dropped (spaces, punctuation, signs). Sizes are kept: they are welded to
  the name in irregular forms, and the same product usually prints the same way.
- **The labels**: only categories among the candidates count (the app's memory
  filters by the candidate list too), so Uncategorised is never repeated.
- **The suggestion**: among the labelled items with the same key, the category
  given most often, when it has a strict majority (more than half). With `n`
  labels of which `k` agree, the confidence is (k + 1) / (n + 1.25): the mean
  of a Beta(1 + k, 0.25 + n - k) posterior, i.e. a weak prior that a name keeps
  its category (prior mean 0.8, worth 1.25 labels). One label gives 0.89, two
  that agree 0.92, four 0.95; a disagreement pulls it down fast (2 of 3: 0.71).
- **Similar items** (`similar`, offline only): the labelled names whose keys
  share the most character trigrams with the name's key (Jaccard similarity at
  least `MIN_SIMILARITY`; the same key counts, as 1), each with its majority
  category. The decision-model categoriser shows them as examples.
"""

import unicodedata
from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass

# Lower-case Latin letters whose upper-case forms look like Cyrillic ones in print.
LATIN_LOOKALIKES = "abcehikmoptxy"
CYRILLIC_LETTERS = "авсенікмортху"
_FOLD = str.maketrans(LATIN_LOOKALIKES, CYRILLIC_LETTERS)

PRIOR_AGREEING = 1.0
PRIOR_DISAGREEING = 0.25
# The least trigram Jaccard similarity of two keys for one to be an example for the other.
MIN_SIMILARITY = 0.35


def name_key(name: str) -> str:
    """The normalised form under which item names are matched."""
    text = unicodedata.normalize("NFKC", name).lower().translate(_FOLD)
    return "".join(char for char in text if unicodedata.category(char)[0] in "LN")


def trigrams(key: str) -> frozenset[str]:
    """The character trigrams of a key (the key itself when shorter)."""
    if len(key) < 3:
        return frozenset({key}) if key else frozenset()
    return frozenset(key[i : i + 3] for i in range(len(key) - 2))


def confidence(agreeing: int, labels: int) -> float:
    return (agreeing + PRIOR_AGREEING) / (labels + PRIOR_AGREEING + PRIOR_DISAGREEING)


@dataclass(frozen=True)
class MemorySuggestion:
    slug: str
    labels: int
    agreeing: int
    confidence: float


class LabelMemory:
    """Labels seen so far, by name key.

    Only labels among `allowed` (the candidate categories, as the app's memory
    only counts those) are kept; None keeps every label.
    """

    def __init__(self, allowed: Iterable[str] | None = None) -> None:
        self._votes: defaultdict[str, Counter[str]] = defaultdict(Counter)
        self._allowed = None if allowed is None else frozenset(allowed)
        # A printed name per key (the first one seen), to show as an example.
        self._names: dict[str, str] = {}
        self._trigrams: dict[str, frozenset[str]] = {}

    def add(self, name: str, slug: str) -> None:
        if self._allowed is not None and slug not in self._allowed:
            return
        key = name_key(name)
        if key:
            self._votes[key][slug] += 1
            self._names.setdefault(key, " ".join(name.split()))
            self._trigrams.setdefault(key, trigrams(key))

    def suggest(self, name: str) -> MemorySuggestion | None:
        votes = self._votes.get(name_key(name))
        if not votes:
            return None
        labels = sum(votes.values())
        slug, agreeing = max(votes.items(), key=lambda pair: (pair[1], pair[0]))
        if agreeing * 2 <= labels:
            return None
        return MemorySuggestion(slug, labels, agreeing, confidence(agreeing, labels))

    def similar(self, name: str, limit: int) -> list[tuple[str, str]]:
        """Up to `limit` labelled (name, majority category) pairs most like `name`, best first.

        Keys without a strict majority are left out, and keys below `MIN_SIMILARITY`. The
        name's own key counts (when the memory answers first, such a name never gets here).
        """
        key = name_key(name)
        grams = trigrams(key)
        if not grams or limit < 1:
            return []
        scored = []
        for other, other_grams in self._trigrams.items():
            similarity = len(grams & other_grams) / len(grams | other_grams)
            if similarity < MIN_SIMILARITY:
                continue
            suggestion = self.suggest(self._names[other])
            if suggestion is not None:
                scored.append((-similarity, other, suggestion.slug))
        scored.sort()
        return [(self._names[other], slug) for _, other, slug in scored[:limit]]
