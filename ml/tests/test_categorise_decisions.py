"""The decision-model categoriser: what is sent, how probabilities become candidates, batching."""

import json
from collections.abc import Mapping
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.backends import BackendError
from app.categorise.base import CategoriseInput
from app.categorise.decisions import (
    EXAMPLES_NOTE,
    MAX_REQUEST_BYTES,
    RECEIPT_NOTE,
    DecisionsCategoriser,
    Options,
    criteria_size,
    prompt_version,
)
from app.categorise.prompt import CategoryOption
from app.main import create_app
from tests.categorise_helpers import CATEGORIES, OPTIONS
from tests.decisions_helpers import (
    DECIDER,
    FakeDecisions,
    decision_settings,
    default_responder,
    even_answer,
)
from tests.test_openrouter_backend import Clock

MERCHANT = "Магазин Секретний"
TEXTS = ("Мол2,5%900г", "Парацетамол №10", "Корм д/котів")


def make(
    responder: Any = default_responder, **overrides: Any
) -> tuple[DecisionsCategoriser, FakeDecisions]:
    transport = FakeDecisions(responder)
    categoriser = DecisionsCategoriser(
        decision_settings(**overrides), transport=transport, clock=Clock()
    )
    return categoriser, transport


def pick(choices: Mapping[str, str]) -> Any:
    """A responder choosing, per question key, the given option (else the first)."""

    def respond(body: Mapping[str, Any]) -> dict[str, Any]:
        answers = {}
        for key, question in body["questions"].items():
            if question["type"] == "noul":
                answers[key] = {"type": "noul", "noul": float(choices.get(key, 0.5))}
            else:
                answers[key] = even_answer(question, choices.get(key))
        return answers

    return respond


def test_the_flat_request_holds_the_item_names_and_the_category_text_only() -> None:
    categoriser, transport = make()

    result = categoriser.categorise(CategoriseInput(OPTIONS, TEXTS, MERCHANT))

    (post,) = transport.posts
    body = post["body"]
    assert set(body) == {"model", "state", "questions", "provider"}
    assert body["model"] == DECIDER
    assert body["state"] == {"line_1": TEXTS[0], "line_2": TEXTS[1], "line_3": TEXTS[2]}
    assert list(body["questions"]) == ["line_1", "line_2", "line_3"]
    question = body["questions"]["line_2"]
    assert question["type"] == "choice"
    assert question["criteria"] == {
        "Groceries": "Food and everyday groceries.",
        "Eating out / Cafes, bars & restaurants": "Meals and drinks at cafes.",
        "Eating out / Takeaway & fast food": "Takeaway and fast food.",
        "Household & shopping / Household supplies": "Household goods.",
        "Household & shopping / Pets": "Pet food and pet care.",
        "Health / Health & pharmacy": "Pharmacy and medicine.",
        # Without a description the name stands in.
        "Other / Other spending": "Other spending",
    }
    assert "`line_2`" in question["instructions"]
    assert RECEIPT_NOTE in question["instructions"]
    assert EXAMPLES_NOTE not in question["instructions"]
    sent = json.dumps(body, ensure_ascii=False)
    assert "Секретний" not in sent and "shop:" not in sent
    assert result.score_kind == "decision_probability"
    assert result.prompt_version == prompt_version("flat", True)
    assert result.diagnostics["questions"] == 3
    assert result.diagnostics["model_calls"] == 1
    assert result.diagnostics["cost_usd"] == "0.000018"
    assert result.diagnostics["prompt_tokens"] == 424


def test_flat_candidates_are_the_three_most_probable_categories() -> None:
    categoriser, _ = make(pick({"line_1": "Health / Health & pharmacy"}))

    result = categoriser.categorise(CategoriseInput(OPTIONS, TEXTS[:1]))

    (candidates,) = result.candidates
    assert candidates[0].slug == "health/health-pharmacy"
    assert candidates[0].score == pytest.approx(0.7)
    assert len(candidates) == 3
    assert [c.score for c in candidates[1:]] == pytest.approx([0.05, 0.05])
    assert sum(c.score for c in candidates) <= 1


def test_two_stage_multiplies_the_group_and_the_category_probabilities() -> None:
    def respond(body: Mapping[str, Any]) -> dict[str, Any]:
        answers = {}
        for key, question in body["questions"].items():
            options = list(question["criteria"])
            if key == "line_1":  # the groups
                probabilities = {o: 0.0 for o in options}
                probabilities.update(
                    {"Household & shopping": 0.6, "Groceries": 0.3, "Eating out": 0.1}
                )
                best = "Household & shopping"
            elif key == "line_1_g1":
                probabilities = {"Household supplies": 0.25, "Pets": 0.75}
                best = "Pets"
            else:
                probabilities = {"Cafes, bars & restaurants": 0.5, "Takeaway & fast food": 0.5}
                best = options[0]
            answers[key] = {"type": "choice", "choice": best, "probabilities": probabilities}
        return answers

    categoriser, transport = make(respond, decisions_strategy="two-stage")

    result = categoriser.categorise(CategoriseInput(OPTIONS, TEXTS[2:]))

    first, second = (post["body"] for post in transport.posts)
    assert list(first["questions"]["line_1"]["criteria"]) == [
        "Groceries",
        "Eating out",
        "Household & shopping",
        "Health",
        "Other",
    ]
    assert first["questions"]["line_1"]["criteria"]["Eating out"] == (
        "Categories: Cafes, bars & restaurants (Meals and drinks at cafes); "
        "Takeaway & fast food (Takeaway and fast food)"
    )
    # The two most likely groups with more than one category are opened; Groceries needs no call.
    assert set(second["questions"]) == {"line_1_g1", "line_1_g3"}
    assert "“Household & shopping”" in second["questions"]["line_1_g1"]["instructions"]
    (candidates,) = result.candidates
    assert [(c.slug, round(c.score, 4)) for c in candidates] == [
        ("household-shopping/pets", 0.45),
        ("groceries/groceries", 0.3),
        ("household-shopping/household-supplies", 0.15),
    ]
    assert result.prompt_version == prompt_version("two-stage", True)


def test_two_stage_opens_a_second_group_only_above_the_minimum() -> None:
    def respond(body: Mapping[str, Any]) -> dict[str, Any]:
        answers = {}
        for key, question in body["questions"].items():
            options = list(question["criteria"])
            if key == "line_1":
                probabilities = {o: 0.0 for o in options}
                probabilities.update({"Eating out": 0.97, "Household & shopping": 0.03})
                answers[key] = {
                    "type": "choice",
                    "choice": "Eating out",
                    "probabilities": probabilities,
                }
            else:
                answers[key] = even_answer(question)
        return answers

    categoriser, transport = make(respond, decisions_strategy="two-stage")
    result = categoriser.categorise(CategoriseInput(OPTIONS, TEXTS[:1]))

    assert set(transport.posts[1]["body"]["questions"]) == {"line_1_g1"}
    assert result.candidates[0][0].slug == "eating-out/cafes-bars-restaurants"


def test_a_refused_item_fails_the_receipt_with_its_accounting() -> None:
    def respond(body: Mapping[str, Any]) -> dict[str, Any]:
        answers = default_responder(body)
        answers["line_2"] = {"type": "refusal"}
        return answers

    categoriser, _ = make(respond)
    with pytest.raises(BackendError) as raised:
        categoriser.categorise(CategoriseInput(OPTIONS, TEXTS))
    assert raised.value.code == "decisions_refused"
    assert raised.value.status_code == 422
    assert raised.value.diagnostics["model_calls"] == 1

    two_stage, _ = make(respond, decisions_strategy="two-stage")
    with pytest.raises(BackendError, match="declined"):
        two_stage.categorise(CategoriseInput(OPTIONS, TEXTS))


def test_without_receipt_context_each_item_goes_alone() -> None:
    categoriser, transport = make(decisions_receipt_context=False)

    categoriser.categorise(CategoriseInput(OPTIONS, TEXTS[:2]))

    assert [post["body"]["state"] for post in transport.posts] == [
        {"item": TEXTS[0]},
        {"item": TEXTS[1]},
    ]
    question = transport.posts[0]["body"]["questions"]["item"]
    assert RECEIPT_NOTE not in question["instructions"]
    assert "`item`" in question["instructions"]


def test_requests_are_cut_by_question_count_and_keep_the_whole_receipt_as_context() -> None:
    categoriser, transport = make(decisions_max_questions=2)

    result = categoriser.categorise(CategoriseInput(OPTIONS, TEXTS))

    assert [list(post["body"]["questions"]) for post in transport.posts] == [
        ["line_1", "line_2"],
        ["line_3"],
    ]
    assert all(len(post["body"]["state"]) == 3 for post in transport.posts)
    assert result.diagnostics["model_calls"] == 2
    assert result.diagnostics["cost_usd"] == "0.000036"


def test_requests_stay_under_the_size_limit() -> None:
    long = [
        CategoryOption(f"group-{i}/category-{i}", f"Category {i}", "x" * 400, f"Group {i}")
        for i in range(40)
    ]
    texts = tuple(f"Item {i}" for i in range(12))
    categoriser, transport = make()

    categoriser.categorise(CategoriseInput(tuple(long), texts))

    assert len(transport.posts) > 1
    for post in transport.posts:
        size = len(json.dumps(post["body"], ensure_ascii=False).encode())
        assert size <= MAX_REQUEST_BYTES
    asked = [key for post in transport.posts for key in post["body"]["questions"]]
    assert asked == [f"line_{i + 1}" for i in range(12)]


def test_examples_are_sent_as_names_with_category_labels() -> None:
    examples = (
        (("Молоко 3,2% 1л", "groceries/groceries"),),
        (("Unlisted", "not/listed"),),
        (),
    )
    categoriser, transport = make()

    categoriser.categorise(CategoriseInput(OPTIONS, TEXTS, None, examples))

    body = transport.posts[0]["body"]
    assert body["state"]["examples"] == [{"item": "Молоко 3,2% 1л", "category": "Groceries"}]
    assert EXAMPLES_NOTE in body["questions"]["line_1"]["instructions"]
    assert EXAMPLES_NOTE not in body["questions"]["line_2"]["instructions"]
    with pytest.raises(ValueError):
        categoriser.categorise(CategoriseInput(OPTIONS, TEXTS, None, examples[:1]))


def test_verify_scores_each_proposal_by_its_yes_probability() -> None:
    categoriser, transport = make(pick({"line_1_c1": 0.2, "line_1_c2": 0.9, "line_2_c1": 0.6}))

    result = categoriser.verify(
        CategoriseInput(OPTIONS, TEXTS),
        [
            ["groceries/groceries", "household-shopping/pets", "not/listed"],
            ["health/health-pharmacy"],
            [],
        ],
    )

    (post,) = transport.posts
    questions = post["body"]["questions"]
    assert set(questions) == {"line_1_c1", "line_1_c2", "line_2_c1"}
    assert questions["line_1_c2"]["type"] == "noul"
    assert (
        "“Household & shopping / Pets”? That category is: Pet food and pet care."
        in (questions["line_1_c2"]["instructions"])
    )
    assert [[(c.slug, c.score) for c in item] for item in result.candidates] == [
        [("household-shopping/pets", 0.9), ("groceries/groceries", 0.2)],
        [("health/health-pharmacy", 0.6)],
        [],
    ]
    with pytest.raises(ValueError):
        categoriser.verify(CategoriseInput(OPTIONS, TEXTS), [])


def test_verify_without_proposals_sends_nothing() -> None:
    categoriser, transport = make()
    result = categoriser.verify(CategoriseInput(OPTIONS, TEXTS[:1]), [[]])
    assert result.candidates == [[]]
    assert transport.posts == []


def test_labels_fall_back_to_slugs_when_names_repeat() -> None:
    twins = (
        CategoryOption("a-group/one", "Same", "", "A"),
        CategoryOption("a-group/two", "Same", "", "A"),
    )
    options = Options.of(twins)
    assert options.flat_criteria() == {"a-group/one": "Same", "a-group/two": "Same"}


def test_criteria_size_reports_the_option_text_per_question() -> None:
    sizes = criteria_size(OPTIONS)
    assert sizes["flat"] > sizes["group"] > 0
    assert sizes["within_max"] > 0


def test_through_the_api_the_merchant_never_leaves() -> None:
    categoriser, transport = make()
    app = create_app(decision_settings(), categoriser=categoriser)

    with TestClient(app) as client:
        response = client.post(
            "/categorise",
            json={"texts": list(TEXTS), "merchant": MERCHANT, "categories": CATEGORIES},
        )

    assert response.status_code == 200, response.text
    document = response.json()
    assert document["backend"] == "decisions"
    assert document["score_kind"] == "decision_probability"
    assert document["cost_usd"] == "0.000018"
    assert len(document["results"]) == 3
    assert all(
        MERCHANT not in json.dumps(post["body"], ensure_ascii=False) for post in transport.posts
    )
