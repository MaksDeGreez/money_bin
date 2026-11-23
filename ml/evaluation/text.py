"""The one place that says how two item names (or two merchant names) are compared.

`normalise_name` turns a name into a comparable form, step by step:

1. Unicode NFKC (full-width and compatibility forms become plain letters and digits), then
   `str.casefold()` (case is ignored).
2. Apostrophes (`'`, `’`, `ʼ`, `‘`, backtick) are removed, so `м'ясо` and `мʼясо` are one word.
3. Every character that is not a letter or a digit becomes a space (punctuation, `%`, `*`, quotes,
   slashes; a decimal comma and a decimal point both become a space, so `2,5` and `2.5` agree).
4. A space is put between digits and letters (`900г` reads as `900 г`).
5. Look-alike letters are folded: every Cyrillic letter of a look-alike class is written as its
   Latin letter (`а е о р с у х і ї к м н т в ј ѕ һ` → `a e o p c y x i ï k m h t b j s h`), on
   every token, so a model that reads a Latin `C` for a Cyrillic `С` is not punished for it. Both
   sides go through this, so it never makes two different words equal unless they differ only in
   such letters. Digits are never folded (`0`/`О`, `3`/`З`, `6`/`б` stay apart). The classes, and
   the letters left out on purpose, are in `ml/README.md`, "The evaluation harness".
6. Units are spelled one way, per token, recognised by their folded spelling (so `KГ` with a Latin
   `K` is a unit too): `кг` → `kg`; `г`, `гр` → `g`; `л` → `l`; `мл` → `ml`; `шт` → `pcs`;
   `уп` → `pack`.
7. Runs of spaces become one; leading and trailing spaces go.

The fold comes after case folding, so the table needs only small letters and a class whose letters
look alike only as capitals (`В`/`B`) still joins the small ones: the case of a word never decides
whether two scripts compare equal. Units and legal forms come after the fold, so a look-alike letter
inside one does not stop it being recognised. `NORMALISATION_VERSION` names this rule (1: the 13
classes without `ї ј ѕ һ`, units and legal forms recognised before the fold); the harness writes it
to `index.json`, since every name metric depends on it.

`normalise_merchant` does the same and also drops the legal-form words (`ТОВ`, `ФОП`, `ПП`, `ПрАТ`,
`ПАТ`, `АТ`, `ДП`, `КП`, `LLC`, `Ltd`, and `TOV`, `FOP`) wherever they stand, since a register
prints the shop's legal name in more than one way; they too are recognised by their folded
spelling, so `TОВ` with a Latin `T` goes, and so does a Latin `AT`.

`similarity` is the character-level ratio `1 - levenshtein(a, b) / max(len(a), len(b))` of two
normalised names (1.0 when both are empty): 1 for equal names, 0 for names with nothing in common.
`levenshtein` counts single-character insertions, deletions and substitutions.
"""

import unicodedata

# 1: the 13 classes of `а е о р с у х і к м н т в`, units and legal forms recognised before the
# fold; 2: also `ї ј ѕ һ`, units and legal forms recognised by their folded spelling. Any change to
# the tables or the steps below is a new version (`tests/test_evaluation_matching.py` pins them).
NORMALISATION_VERSION = 2
APOSTROPHES = str.maketrans("", "", "'’ʼ‘`")
UNITS = {
    "кг": "kg",
    "г": "g",
    "гр": "g",
    "л": "l",
    "мл": "ml",
    "шт": "pcs",
    "уп": "pack",
}
# Lower-case Cyrillic letters whose capital (receipts are mostly printed in capitals) or small form
# looks like a Latin letter in upright print, each written as that Latin letter. Applied after case
# folding, so one entry covers both cases of both scripts. Letters alike only in italics (п/n, и/u,
# г/r, ь/b, т/m) and ё are left out; see `ml/README.md`, "The evaluation harness".
LOOK_ALIKES = str.maketrans("аеорсухікмнтвїјѕһ", "aeopcyxikmhtbïjsh")
LEGAL_FORMS = frozenset(
    {"тов", "фоп", "пп", "прат", "пат", "ат", "дп", "кп", "llc", "ltd", "tov", "fop"}
)
# The same tables by folded spelling. Every folded unit keeps a Cyrillic letter no class covers
# (`г л ш п`), so no Latin word becomes a unit; a Latin `at` or `tob` does count as a legal form.
FOLDED_UNITS = {unit.translate(LOOK_ALIKES): spelling for unit, spelling in UNITS.items()}
FOLDED_LEGAL_FORMS = frozenset(form.translate(LOOK_ALIKES) for form in LEGAL_FORMS)


def _tokens(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text).casefold().translate(APOSTROPHES)
    characters: list[str] = []
    previous = ""
    for character in text:
        if not character.isalnum():
            character = " "
        elif previous and previous != " " and previous.isdigit() != character.isdigit():
            characters.append(" ")
        characters.append(character)
        previous = character
    return "".join(characters).split()


def _folded(text: str) -> list[str]:
    return [token.translate(LOOK_ALIKES) for token in _tokens(text)]


def _finish(tokens: list[str]) -> str:
    return " ".join(FOLDED_UNITS.get(token, token) for token in tokens)


def normalise_name(text: str | None) -> str:
    """An item name in its comparable form (see the module docstring)."""
    if not text:
        return ""
    return _finish(_folded(text))


def normalise_merchant(text: str | None) -> str:
    """A merchant name in its comparable form: as `normalise_name`, without legal-form words."""
    if not text:
        return ""
    return _finish([token for token in _folded(text) if token not in FOLDED_LEGAL_FORMS])


def levenshtein(a: str, b: str) -> int:
    """The edit distance of two strings: insertions, deletions and substitutions of characters."""
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, char_a in enumerate(a, start=1):
        current = [i]
        for j, char_b in enumerate(b, start=1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (char_a != char_b),
                )
            )
        previous = current
    return previous[-1]


def similarity(a: str, b: str) -> float:
    """The character-level ratio of two already normalised strings, between 0 and 1."""
    longest = max(len(a), len(b))
    if longest == 0:
        return 1.0
    return 1.0 - levenshtein(a, b) / longest


def plain(text: str | None) -> str:
    """A name with only NFC and collapsed whitespace: what the raw character error rate reads."""
    if not text:
        return ""
    return " ".join(unicodedata.normalize("NFC", text).split())
