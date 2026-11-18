"""Scores from hosted log-probabilities, and calibration."""

import json
import math
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.categorise.base import Candidate, Categorisation, top_candidates
from app.categorise.calibration import (
    FORMAT,
    FORMAT_VERSION,
    Calibration,
    CalibrationError,
    calibrate,
    load_calibration,
)
from app.categorise.logprobs import item_scores
from app.config import Settings
from app.main import create_app
from tests.categorise_helpers import CATEGORIES, SLUGS

SLUG_LIST = ["eating-out/cafes-bars-restaurants", "eating-out/takeaway-fast-food", "car/fuel"]


def tokens(*pieces: tuple[str, float, list[tuple[str, float]]]) -> list[dict[str, Any]]:
    return [
        {
            "token": text,
            "logprob": logprob,
            "top_logprobs": [{"token": t, "logprob": lp} for t, lp in alternatives],
        }
        for text, logprob, alternatives in pieces
    ]


def test_multi_token_slugs_and_an_alternative_that_names_one_other_slug() -> None:
    answer = '{"1": "eating-out/cafes-bars-restaurants"}'
    content = tokens(
        ('{"1": "', 0.0, []),
        ("eating", math.log(0.9), [("car", math.log(0.05))]),
        ("-out/", 0.0, []),
        ("caf", math.log(0.8), [("take", math.log(0.15)), ("x", math.log(0.01))]),
        ("es-bars-restaurants", 0.0, []),
        ('"}', 0.0, []),
    )

    (candidates,) = item_scores(answer, content, ["eating-out/cafes-bars-restaurants"], SLUG_LIST)

    scores = {c.slug: c.score for c in candidates}
    assert math.isclose(scores["eating-out/cafes-bars-restaurants"], 0.9 * 0.8)
    assert math.isclose(scores["eating-out/takeaway-fast-food"], 0.9 * 0.15)
    assert math.isclose(scores["car/fuel"], 0.05)
    assert candidates[0].slug == "eating-out/cafes-bars-restaurants"


def test_a_token_across_the_opening_quote_and_an_ambiguous_alternative() -> None:
    answer = '{"1": "car/fuel"}'
    content = tokens(
        ('{"1":', 0.0, []),
        (' "car', math.log(0.6), [(' "eating', math.log(0.3)), ("eat", math.log(0.05))]),
        ("/fuel", 0.0, []),
        ('"}', 0.0, []),
    )

    (candidates,) = item_scores(answer, content, ["car/fuel"], SLUG_LIST)

    # ' "eating' leads to two slugs: not attributed; "eat" lacks the quote: not attributed.
    assert [(c.slug, round(c.score, 6)) for c in candidates] == [("car/fuel", 0.6)]


def test_an_alternative_that_completes_a_value_names_that_slug() -> None:
    answer = '{"1": "car/fuel"}'
    slugs = ["car/fuel", "car/fuel-cards", "car/fuelling"]
    content = tokens(
        ('{"1": "car/', math.log(0.7), []),
        ('fuel"}', math.log(0.9), [('fuel-cards"}', math.log(0.08)), ("fuel", math.log(0.01))]),
    )

    (candidates,) = item_scores(answer, content, ["car/fuel"], slugs)

    scores = {c.slug: c.score for c in candidates}
    assert math.isclose(scores["car/fuel"], 0.7 * 0.9)
    # Closed by its quote, the alternative names exactly "car/fuel-cards".
    assert math.isclose(scores["car/fuel-cards"], 0.7 * 0.08)
    # "fuel" without a quote could still be "car/fuel-cards" or "car/fuelling": not attributed.
    assert "car/fuelling" not in scores


@pytest.mark.parametrize(
    "content",
    [
        None,
        [],
        [{"token": "x", "logprob": -0.1}],
        [{"token": 5, "logprob": -0.1}],
        [{"token": '{"1": "car/fuel"}', "logprob": 0.5}],
        [{"token": '{"1": "car/fuel"}', "logprob": True}],
        ["not a mapping"],
    ],
)
def test_unusable_log_probabilities_give_none(content: Any) -> None:
    assert item_scores('{"1": "car/fuel"}', content, ["car/fuel"], SLUG_LIST) is None


def test_log_probabilities_that_do_not_match_the_answer_give_none() -> None:
    content = [{"token": '{"1": "car/fuel"}', "logprob": Decimal("-0.1")}]

    assert item_scores('{"1": "car/fuel"}', content, ["car/fuel", "car/fuel"], SLUG_LIST) is None
    assert item_scores('{"1": "car/fuel"}', content, ["eating-out/x"], SLUG_LIST) is None


def test_inconsistent_numbers_are_scaled_to_add_up_to_one() -> None:
    answer = '{"1": "car/fuel"}'
    content = tokens(('{"1": "', 0.0, []), ("car/fuel", -0.01, [("eating-out/take", -0.01)]))
    content.append({"token": '"}', "logprob": 0.0, "top_logprobs": None})

    (candidates,) = item_scores(answer, content, ["car/fuel"], SLUG_LIST)

    assert math.isclose(sum(c.score for c in candidates), 1.0)


def test_top_candidates_clips_and_orders() -> None:
    assert top_candidates({"b": 0.2, "a": 0.2, "c": 1.2, "d": -0.1}) == [
        Candidate("c", 1.0),
        Candidate("a", 0.2),
        Candidate("b", 0.2),
    ]


# Calibration ---------------------------------------------------------------


def calibration_document(**overrides: Any) -> dict[str, Any]:
    document = {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "backend": "stub",
        "model_name": "stub-categoriser",
        "prompt_version": None,
        "score_kind": "stub",
        "xs": [0.2, 0.6, 0.9],
        "ys": [0.1, 0.5, 0.97],
        "labelled_items": 120,
    }
    document.update(overrides)
    return document


def write(tmp_path: Path, document: Any) -> Path:
    path = tmp_path / "calibration.json"
    path.write_text(json.dumps(document) if not isinstance(document, str) else document)
    return path


def test_the_mapping_is_linear_between_breakpoints_and_flat_beyond(tmp_path: Path) -> None:
    calibration = load_calibration(write(tmp_path, calibration_document()))

    assert calibration.map(0.0) == 0.1
    assert calibration.map(0.4) == pytest.approx(0.3)
    assert calibration.map(0.9) == 0.97
    assert calibration.map(1.0) == 0.97


def test_a_flat_step_maps_to_its_right_value() -> None:
    calibration = Calibration("stub", "m", None, "stub", (0.2, 0.2, 0.8), (0.1, 0.4, 0.9), 50)

    assert calibration.map(0.2) == 0.1
    assert calibration.map(0.5) == pytest.approx(0.65)


def test_applying_keeps_the_best_and_fits_the_others_below_one() -> None:
    calibration = Calibration("stub", "m", None, "stub", (0.0, 1.0), (0.5, 1.0), 50)

    best, *others = calibration.apply(
        [Candidate("a", 0.6), Candidate("b", 0.3), Candidate("c", 0.1)]
    )

    assert best == Candidate("a", 0.8)
    assert sum(c.score for c in others) == pytest.approx(0.2)
    assert [c.slug for c in others] == ["b", "c"]
    assert calibration.apply([]) == []


def test_calibrate_applies_only_to_a_matching_answer() -> None:
    calibration = Calibration("mlx", "m", "p1", "label_probability", (0.0, 1.0), (0.0, 0.5), 50)
    answer = Categorisation([[Candidate("a", 1.0)]], "label_probability", "p1")

    assert calibrate(answer, calibration, "mlx", "m") == ([[Candidate("a", 0.5)]], True)
    assert calibrate(answer, None, "mlx", "m") == (answer.candidates, False)
    other = Categorisation([[Candidate("a", 1.0)]], "label_probability", "p2")
    assert calibrate(other, calibration, "mlx", "m")[1] is False
    fixed = Categorisation([[Candidate("a", 0.5)]], "fixed", "p1")
    assert calibrate(fixed, calibration, "mlx", "m")[1] is False


@pytest.mark.parametrize(
    ("document", "message"),
    [
        ("not json", "not JSON"),
        ({"format": "other"}, "not an item categoriser"),
        (calibration_document(format_version=2), "format version"),
        (calibration_document(xs=[]), "xs"),
        (calibration_document(xs=[0.1, "x", 0.9]), "non-number"),
        (calibration_document(xs=[0.1, 0.5]), "differ in length"),
        (calibration_document(ys=[0.9, 0.5, 0.1]), "not increasing"),
        (calibration_document(ys=[0.1, 0.5, 1.5]), "outside"),
        (calibration_document(backend=""), "no backend"),
        (calibration_document(prompt_version=3), "prompt_version"),
        (calibration_document(labelled_items=True), "labelled_items"),
    ],
)
def test_a_bad_calibration_file_is_refused(tmp_path: Path, document: Any, message: str) -> None:
    with pytest.raises(CalibrationError, match=message):
        load_calibration(write(tmp_path, document))


def test_a_missing_calibration_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(CalibrationError, match="cannot be read"):
        load_calibration(tmp_path / "nope.json")


def test_the_service_applies_a_matching_calibration(tmp_path: Path) -> None:
    path = write(tmp_path, calibration_document(xs=[0.0, 1.0], ys=[0.0, 0.5]))
    app = create_app(Settings(categorise_calibration_file=path))

    with TestClient(app) as client:
        health = client.get("/health").json()
        answer = client.post(
            "/categorise", json={"texts": ["Мол900г"], "categories": CATEGORIES}
        ).json()

    assert health["categoriser"]["calibration"] is True
    assert answer["calibrated"] is True
    best = answer["results"][0]["candidates"][0]
    assert best["score"] <= 0.5
    assert best["category_slug"] in SLUGS


def test_a_calibration_for_another_model_stops_the_service(tmp_path: Path) -> None:
    path = write(tmp_path, calibration_document(model_name="another-model"))
    app = create_app(Settings(categorise_calibration_file=path))

    with pytest.raises(CalibrationError, match="fitted for stub 'another-model'"), TestClient(app):
        pass


def test_an_alternative_that_could_still_be_the_chosen_slug_is_not_attributed() -> None:
    answer = '{"1": "eating-out/cafes-bars-restaurants"}'
    content = tokens(
        ('{"1": "', 0.0, []),
        ("eating-out/caf", math.log(0.7), [("eat", math.log(0.2))]),
        ('es-bars-restaurants"}', 0.0, []),
    )

    (candidates,) = item_scores(answer, content, ["eating-out/cafes-bars-restaurants"], SLUG_LIST)

    # "eat" leads to both eating-out slugs: neither gets its probability.
    assert [(c.slug, round(c.score, 6)) for c in candidates] == [
        ("eating-out/cafes-bars-restaurants", 0.7)
    ]
