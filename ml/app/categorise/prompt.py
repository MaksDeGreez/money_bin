"""The item categorisation prompt, shared by every model backend.

The categories are not written here: each request brings them (slug, name,
description, group), because the Rails app owns them. The prompt lists them
grouped by group, explains how receipt items are printed, shows a few invented
examples, and asks for one JSON object that maps each item's number to one
category slug from the list.

`PROMPT_VERSION` is a short hash of every fixed text and example below, so a
stored or evaluated answer says which prompt produced it. The category list a
request brought has its own hash (`categories_version`).

Two variants of the user message exist, and only two:

- `local_messages(categories, texts, merchant)`: for a model on this machine;
  the shop's name, when known, is given as context.
- `hosted_messages(categories, texts)`: for a hosted model; it takes the item
  names and nothing else, so no merchant, amount, date or id can reach it.
"""

import hashlib
import json
from collections.abc import Sequence
from dataclasses import dataclass

SYSTEM_PROMPT = (
    "You sort the items of Ukrainian shop receipts into spending categories. "
    "You answer with one JSON object and nothing else."
)

_INTRO = (
    "The spending categories, by group. "
    "Each line is a category slug, its name and what belongs in it:"
)

_INSTRUCTIONS = """\
How receipt items are printed: in Ukrainian (sometimes in Russian or English), in capitals or \
not, often abbreviated and run together without spaces. Words are cut short (Мол = молоко, \
Ковб. = ковбаса, Хл = хліб, д/ = для), a weight, a volume or a pack size is stuck to the name \
(900г, 0,5л, №20, 4шт), and brands are often in Latin letters.

For each item, decide what the product is, then choose the category it belongs in. The other \
items of the same receipt help: on a receipt full of medicines an unclear item is most likely a \
medicine, and next to cat food it is most likely for the pet.
- Food and drinks bought in a shop to take home are groceries; beer, wine, spirits and \
cigarettes are alcohol and tobacco.
- A meal, a coffee or a snack made and served on the spot is eating out: at a cafe, bar or \
restaurant, or as takeaway and fast food.
- Cleaning products, toiletries and other personal-care products are household supplies.
- Choose only from the categories listed. When nothing fits, choose other spending.

Examples of items and their categories:
{examples}

Answer with one JSON object: the item numbers as keys, in order, and one category slug from the \
list as each value, for example {{"1": "{first}", "2": "{second}"}}. Only the slugs, nothing \
else."""

# Invented examples of printed item names and the category each obviously belongs in.
EXAMPLES: tuple[tuple[str, str], ...] = (
    ("Йогурт Пол.2,5%270г", "groceries/groceries"),
    ("ГорілкаКласична0,5л", "alcohol-tobacco/alcohol-tobacco"),
    ("Шампунь д/волосся 400мл", "household-shopping/household-supplies"),
    ("Корм д/собак сух.2кг", "household-shopping/pets"),
    ("Аспірин таб.500мг№10", "health/health-pharmacy"),
    ("ЕСПРЕСО ПОДВІЙНЕ", "eating-out/cafes-bars-restaurants"),
    ("А-95 32,15л", "car/fuel"),
)

_MERCHANT = "The shop: {merchant}"
_ITEMS = "The items of one receipt, in printed order:"


def _version() -> str:
    parts = [
        SYSTEM_PROMPT,
        _INTRO,
        _INSTRUCTIONS,
        json.dumps(EXAMPLES, ensure_ascii=False),
        _MERCHANT,
        _ITEMS,
    ]
    return hashlib.sha256("\x00".join(parts).encode()).hexdigest()[:12]


PROMPT_VERSION = _version()


@dataclass(frozen=True)
class CategoryOption:
    """One category the answer may name. The Rails app sends these."""

    slug: str
    name: str
    description: str
    group: str


def categories_version(categories: Sequence[CategoryOption]) -> str:
    """A short hash of the category list, in its order, with every field."""
    rows = [[c.slug, c.name, c.description, c.group] for c in categories]
    text = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def category_lines(categories: Sequence[CategoryOption]) -> str:
    """The categories, grouped by group in the order the groups first appear."""
    groups: dict[str, list[CategoryOption]] = {}
    for category in categories:
        groups.setdefault(category.group, []).append(category)
    lines = []
    for group, members in groups.items():
        lines.append(group)
        for category in members:
            description = category.description.strip()
            line = f"- {category.slug}: {category.name}"
            lines.append(f"{line}. {description}" if description else line)
    return "\n".join(lines)


def _examples(slugs: set[str]) -> list[tuple[str, str]]:
    """The examples whose category is in the list (a smaller list drops the others)."""
    return [(name, slug) for name, slug in EXAMPLES if slug in slugs]


def system_message(categories: Sequence[CategoryOption]) -> str:
    """The fixed instructions and the category list: the same for every receipt.

    It holds no receipt data, so a local backend can keep it computed between receipts.
    """
    slugs = [category.slug for category in categories]
    examples = _examples(set(slugs)) or [("", slugs[0])]
    shown = "\n".join(f"- {name} -> {slug}" for name, slug in examples if name)
    first = examples[0][1]
    second = examples[1][1] if len(examples) > 1 else first
    instructions = _INSTRUCTIONS.format(examples=shown or "(none)", first=first, second=second)
    return f"{SYSTEM_PROMPT}\n\n{_INTRO}\n{category_lines(categories)}\n\n{instructions}"


def _item_lines(texts: Sequence[str]) -> str:
    # One line per item: a line break inside a name would make a fake item.
    return "\n".join(f"{number}. {' '.join(text.split())}" for number, text in enumerate(texts, 1))


def local_messages(
    categories: Sequence[CategoryOption], texts: Sequence[str], merchant: str | None
) -> list[dict[str, str]]:
    """The chat for a model on this machine: the shop's name is context when known."""
    parts = []
    if merchant and merchant.strip():
        parts.append(_MERCHANT.format(merchant=" ".join(merchant.split())))
    parts.append(f"{_ITEMS}\n{_item_lines(texts)}")
    return [
        {"role": "system", "content": system_message(categories)},
        {"role": "user", "content": "\n\n".join(parts)},
    ]


def hosted_messages(
    categories: Sequence[CategoryOption], texts: Sequence[str]
) -> list[dict[str, str]]:
    """The chat for a hosted model: the item names only, never the shop or anything else."""
    return [
        {"role": "system", "content": system_message(categories)},
        {"role": "user", "content": f"{_ITEMS}\n{_item_lines(texts)}"},
    ]


def answer_schema(slugs: Sequence[str], count: int) -> dict[str, object]:
    """The JSON schema of the answer: keys "1".."count", each one slug from the list."""
    choice = {"type": "string", "enum": list(slugs)}
    keys = [str(number) for number in range(1, count + 1)]
    return {
        "type": "object",
        "properties": {key: choice for key in keys},
        "required": keys,
        "additionalProperties": False,
    }
