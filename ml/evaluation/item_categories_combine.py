"""Combine item-category runs into one run: a cascade, a weighted average or a learned combination.

    uv run python -m evaluation.item_categories_combine \\
        --run RUNS/<memory+model run> --run RUNS/<decisions run> \\
        --ground-truth ~/Documents/money_bin_data/exports/ground_truth.jsonl \\
        --out ~/Documents/money_bin_data/runs --method learned

Every input is a run folder of `evaluation.item_categories_run` over the same items. Each run
becomes a matrix of per-category scores (rows: the items every run has; columns: every category
any run names or any label is; a category a run did not list scores 0), and a combination is a new
matrix of the same shape, written as a run folder in the same format (`source: combined`), so the
evaluation scores a combination exactly like a single method.

- `cascade` (`--thresholds T1,...`, one per run but the last): the first run whose best score
  reaches its threshold decides the item, for example the label memory when it is confident, else
  the model. The item gets that run's candidates, in that run's order.
- `average` (`--weights W1,...`, equal by default): a weighted average of the score matrices.
- `learned`: a multinomial logistic regression on the runs' score matrices side by side, plus one
  "no candidates" column per run, cross-validated by receipt and forward in time (`--folds`): the
  receipts with usable labels, in time order (`issued_at`, as the runner orders them), are cut into
  `folds + 1` consecutive blocks, and each block after the first is scored by a model fitted on
  the blocks before it only. So no item is scored by a model fitted on items of its own receipt
  (items of one receipt share a shop and often a category, and would flatter it), nor on a later
  receipt: with the label memory or labelled examples, a later receipt's scores already contain
  earlier receipts' labels, and random folds would let a held-out label in through them. The first
  block, which has nothing earlier to learn from, gets the plain average of the runs instead; the
  rest get a model fitted on every usable label (they are not scored).

The pre-fill rule: an item whose labels were chosen with one of the combined categorisers'
suggestions on screen (the ground truth's `categories_prefilled_by` names a run's model or, for
a run with `--memory`, the label memory; or is `source:unknown`) is neither fitted on nor counted
in the agreement figures, and `run.json` reports how many; `run.json` also lists every combined
categoriser (`categorisers`), so a scorer applies the same rule. The input runs must themselves be
free of leakage (the runner's memory only knows earlier receipts).

`run.json` adds `agreement`: over the usable labelled items, how often all runs give the same best
category and how precise that shared category is (the auto-accept rule "all agree"), the combined
run's accuracy where they disagree, and each pair's agreement. Item names never appear in
`run.json` or on the console; the folder must be outside any git repository.
"""

import argparse
import hashlib
import json
import math
import sys
import warnings
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, TextIO

import numpy as np

from app.decimals import exact_sum
from evaluation.common import UsageError, inside_git_repository, read_jsonl, write_private_json
from evaluation.item_categories_calibrate import UNKNOWN_CATEGORISER
from evaluation.item_categories_run import (
    TASK,
    categoriser_entries,
    read_ground_truth,
    run_categorisers,
)
from evaluation.item_categories_run import _time_order as receipt_time_order
from evaluation.item_scores import Scored
from evaluation.item_scores import summary as score_summary
from evaluation.ocr_run import _open_private, git_commit, make_run_dir

METHODS = ("cascade", "average", "learned")
DEFAULT_FOLDS = 5
MIN_LEARNED_ITEMS = 20
SCORE_PLACES = 6

ItemKey = tuple[str, int]


@dataclass(frozen=True)
class InputRun:
    """One input run: its summary, its name, and its candidates and accounting per item."""

    path: Path
    summary: dict[str, Any]
    candidates: dict[ItemKey, list[tuple[str, float]]]
    seconds: dict[ItemKey, float | None]
    costs: dict[ItemKey, Decimal | None]

    @property
    def name(self) -> str:
        return str(self.summary.get("run_id") or self.path.name)

    @property
    def categorisers(self) -> set[str]:
        """The names the app would record for this run's suggestions (`categories_prefilled_by`)."""
        return set(run_categorisers(self.summary))


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _decimal(value: Any) -> Decimal | None:
    if not isinstance(value, str):
        return None
    try:
        number = Decimal(value)
    except ArithmeticError:
        return None
    return number if number.is_finite() and number >= 0 else None


def read_input(run_dir: Path) -> InputRun:
    """A run folder, every line checked. Errors name the folder and the line, never a value."""
    summary_path = run_dir / "run.json"
    if not summary_path.is_file() or not (run_dir / "predictions.jsonl").is_file():
        raise UsageError(f"not a run folder: {run_dir.name}")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    if not isinstance(summary, dict) or summary.get("task") != TASK:
        raise UsageError(f"{run_dir.name} is not an item_categories run")
    candidates, seconds, costs = {}, {}, {}
    for number, line in enumerate(read_jsonl(run_dir / "predictions.jsonl"), start=1):
        try:
            key = (str(line["receipt_id"]), int(line["position"]))
            items = [(str(c["category_slug"]), float(c["score"])) for c in line["candidates"]]
        except (KeyError, TypeError, ValueError):
            raise UsageError(f"{run_dir.name}: line {number} is not a prediction") from None
        if any(not 0 <= score <= 1 for _, score in items) or key in candidates:
            raise UsageError(f"{run_dir.name}: line {number} is not a valid prediction")
        candidates[key] = items
        seconds[key] = _number(line.get("seconds"))
        costs[key] = _decimal(line.get("cost_usd"))
    return InputRun(run_dir, summary, candidates, seconds, costs)


# The combinations -------------------------------------------------------------------------------


def score_matrix(rows: Sequence[Sequence[tuple[str, float]]], labels: Sequence[str]) -> np.ndarray:
    column = {label: i for i, label in enumerate(labels)}
    matrix = np.zeros((len(rows), len(labels)))
    for row, items in enumerate(rows):
        for slug, score in items:
            matrix[row, column[slug]] = score
    return matrix


def top_three(row: np.ndarray, labels: Sequence[str]) -> list[tuple[str, float]]:
    """The best three non-zero scores of a row, ties broken by label order."""
    order = sorted(range(len(labels)), key=lambda i: (-row[i], i))
    return [(labels[i], float(row[i])) for i in order[:3] if row[i] > 0]


def cascade(
    matrices: Sequence[np.ndarray], thresholds: Sequence[float]
) -> tuple[np.ndarray, list[int]]:
    """Per item, the scores of the first run whose best score reaches its threshold."""
    if len(thresholds) != len(matrices) - 1:
        raise UsageError("a cascade needs one threshold per run but the last")
    result = np.zeros_like(matrices[0])
    deciders = []
    for row in range(matrices[0].shape[0]):
        decider = len(matrices) - 1
        for index, threshold in enumerate(thresholds):
            best = matrices[index][row].max()
            if best > 0 and best >= threshold:
                decider = index
                break
        deciders.append(decider)
        result[row] = matrices[decider][row]
    return result, deciders


def average(matrices: Sequence[np.ndarray], weights: Sequence[float] | None) -> np.ndarray:
    weights = list(weights) if weights is not None else [1.0] * len(matrices)
    if len(weights) != len(matrices) or any(w < 0 for w in weights) or sum(weights) <= 0:
        raise UsageError("--weights needs one non-negative weight per run, not all zero")
    return sum(w * m for w, m in zip(weights, matrices, strict=True)) / sum(weights)


def features(matrices: Sequence[np.ndarray]) -> np.ndarray:
    """The runs' score matrices side by side, plus one 'no candidates' column per run."""
    blocks = []
    for matrix in matrices:
        blocks.append(matrix)
        blocks.append((matrix.max(axis=1, keepdims=True) <= 0).astype(float))
    return np.hstack(blocks)


def _fit_predict(
    x_train: np.ndarray, y_train: np.ndarray, x_test: np.ndarray, n_labels: int, c: float
) -> tuple[np.ndarray, Any]:
    """Probabilities over every label code for `x_test`, from a fit on the training rows."""
    from sklearn.exceptions import ConvergenceWarning
    from sklearn.linear_model import LogisticRegression

    out = np.zeros((x_test.shape[0], n_labels))
    classes = np.unique(y_train)
    if len(classes) == 1:
        # One category only among the training rows: the only answer this fold can give.
        out[:, classes[0]] = 1.0
        return out, None
    model = LogisticRegression(C=c, max_iter=5000)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", ConvergenceWarning)
        model.fit(x_train, y_train)
    out[:, model.classes_] = model.predict_proba(x_test)
    return out, model


def learned(
    matrices: Sequence[np.ndarray],
    labels: Sequence[str],
    truth: Sequence[str | None],
    order: Sequence[int],
    usable: Sequence[bool],
    *,
    folds: int,
    c: float,
    names: Sequence[str],
) -> tuple[np.ndarray, dict[str, Any]]:
    """Forward-in-time, receipt-blocked probabilities for the usable labelled items, and a full
    fit's for the rest. `order[i]` is the time rank of item i's receipt (0: the earliest)."""
    code = {label: i for i, label in enumerate(labels)}
    fit_rows = np.array([i for i, ok in enumerate(usable) if ok and truth[i] in code], dtype=int)
    if len(fit_rows) < MIN_LEARNED_ITEMS:
        raise UsageError(
            f"a learned combination needs at least {MIN_LEARNED_ITEMS} usable labelled items "
            f"(there are {len(fit_rows)})"
        )
    ranks = sorted({order[i] for i in fit_rows})
    if len(ranks) < 2:
        raise UsageError("a learned combination needs labelled items of two receipts or more")
    x = features(matrices)
    y = np.array([code.get(label, -1) if label is not None else -1 for label in truth])
    blocks = [list(block) for block in np.array_split(ranks, min(folds, len(ranks) - 1) + 1)]
    result = np.zeros((len(truth), len(labels)))
    rank_of = np.array(order)
    warm_up = fit_rows[np.isin(rank_of[fit_rows], blocks[0])]
    result[warm_up] = average(matrices, None)[warm_up]
    for block in blocks[1:]:
        train_rows = fit_rows[rank_of[fit_rows] < block[0]]
        test_rows = fit_rows[np.isin(rank_of[fit_rows], block)]
        # The rule this exists for: every receipt fitted on is earlier than every one scored.
        assert rank_of[train_rows].max() < rank_of[test_rows].min()
        result[test_rows], _ = _fit_predict(
            x[train_rows], y[train_rows], x[test_rows], len(labels), c
        )
    others = np.setdiff1d(np.arange(len(truth)), fit_rows)
    full, model = _fit_predict(x[fit_rows], y[fit_rows], x, len(labels), c)
    result[others] = full[others]
    info: dict[str, Any] = {
        "folds": len(blocks) - 1,
        "split": "receipt blocks in time order; each scored by a fit on the earlier blocks",
        "c": c,
        "fitted_items": len(fit_rows),
        "fitted_receipts": len(ranks),
        "warm_up_items": len(warm_up),
        "full_fit_items": len(others),
    }
    if model is not None:
        # How much the full fit leans on each run: its share of the absolute weights.
        width = len(labels) + 1
        weights = np.abs(model.coef_)
        per_run = [float(weights[:, i * width : (i + 1) * width].sum()) for i in range(len(names))]
        total = sum(per_run) or 1.0
        info["weight_share"] = {
            name: round(value / total, 4) for name, value in zip(names, per_run, strict=True)
        }
    return result, info


def agreement(
    tops: Sequence[Sequence[str | None]],
    names: Sequence[str],
    truth: Sequence[str | None],
    scored: Sequence[bool],
    combined: Sequence[str | None],
) -> dict[str, Any]:
    """How often the runs agree on the best category, and how often they are then right."""
    rows = [i for i, ok in enumerate(scored) if ok and truth[i] is not None]
    result: dict[str, Any] = {"items": len(rows)}
    if not rows:
        return result
    agree = [i for i in rows if tops[0][i] is not None and all(t[i] == tops[0][i] for t in tops)]
    agreed = set(agree)
    disagree = [i for i in rows if i not in agreed]

    def share(hits: int, count: int) -> float | None:
        return round(hits / count, 4) if count else None

    result.update(
        {
            "all_agree_items": len(agree),
            "all_agree_share": share(len(agree), len(rows)),
            "all_agree_precision": share(sum(tops[0][i] == truth[i] for i in agree), len(agree)),
            "combined_accuracy": share(sum(combined[i] == truth[i] for i in rows), len(rows)),
            "combined_accuracy_when_disagreeing": share(
                sum(combined[i] == truth[i] for i in disagree), len(disagree)
            ),
            "run_accuracy": {
                name: share(sum(top[i] == truth[i] for i in rows), len(rows))
                for name, top in zip(names, tops, strict=True)
            },
            "pairwise_agreement": {
                f"{names[a]}|{names[b]}": share(
                    sum(tops[a][i] is not None and tops[a][i] == tops[b][i] for i in rows),
                    len(rows),
                )
                for a in range(len(tops))
                for b in range(a + 1, len(tops))
            },
        }
    )
    return result


# The command --------------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.item_categories_combine",
        description="Combine item-category runs into one run folder.",
    )
    parser.add_argument(
        "--run", action="append", required=True, type=Path, help="an input run folder (2 or more)"
    )
    parser.add_argument("--ground-truth", required=True, type=Path, help="ground_truth.jsonl")
    parser.add_argument("--out", required=True, type=Path, help="the folder for run folders")
    parser.add_argument("--method", choices=METHODS, required=True)
    parser.add_argument("--thresholds", help="cascade: one per run but the last, a,b")
    parser.add_argument("--weights", help="average: one per run, a,b,c")
    parser.add_argument("--folds", type=int, default=DEFAULT_FOLDS, help="learned: CV folds")
    parser.add_argument("--c", type=float, default=1.0, help="learned: inverse regularisation")
    args = parser.parse_args(argv)
    if len(args.run) < 2:
        parser.error("give two --run folders or more")
    if args.folds < 2 or args.c <= 0:
        parser.error("--folds must be 2 or more and --c above 0")
    return args


def _floats(text: str | None, option: str) -> list[float] | None:
    if text is None:
        return None
    try:
        values = [float(part) for part in text.split(",")]
    except ValueError:
        raise UsageError(f"{option} takes numbers separated by commas") from None
    if not all(math.isfinite(value) for value in values):
        raise UsageError(f"{option} takes finite numbers")
    return values


def _method_parameters(args: argparse.Namespace) -> dict[str, Any]:
    if args.method == "cascade":
        return {"thresholds": _floats(args.thresholds, "--thresholds")}
    if args.method == "average":
        return {"weights": _floats(args.weights, "--weights")}
    return {"folds": args.folds, "c": args.c}


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    runs_dir = args.out.expanduser().resolve()
    if inside_git_repository(runs_dir):
        raise UsageError("--out is inside a git repository; run folders hold receipt content")
    inputs = [read_input(path.expanduser()) for path in args.run]
    names = [run.name for run in inputs]
    if len(set(names)) != len(names):
        raise UsageError("the same run is given twice")
    parameters = _method_parameters(args)
    if args.method == "cascade" and parameters["thresholds"] is None:
        raise UsageError("--method cascade needs --thresholds")

    common_keys = set(inputs[0].candidates)
    for one in inputs[1:]:
        common_keys &= set(one.candidates)
    every = set().union(*(set(one.candidates) for one in inputs))
    keys = sorted(common_keys)
    if not keys:
        raise UsageError("the runs have no item in common")

    receipts = read_ground_truth(args.ground_truth.expanduser())
    categorisers = sorted(set().union(*(one.categorisers for one in inputs)))
    truth_by_key: dict[ItemKey, str] = {}
    excluded: set[ItemKey] = set()
    for receipt in receipts:
        prefilled = (receipt.categories_prefilled_by or "").strip()
        for item in receipt.items:
            if item.label is None:
                continue
            key = (receipt.ingest_id, item.position)
            truth_by_key[key] = item.label
            if prefilled and (prefilled == UNKNOWN_CATEGORISER or prefilled in categorisers):
                excluded.add(key)
    truth = [truth_by_key.get(key) for key in keys]
    usable = [t is not None and key not in excluded for key, t in zip(keys, truth, strict=True)]

    labels = sorted(
        {slug for one in inputs for key in keys for slug, _ in one.candidates[key]}
        | {t for t in truth if t is not None}
    )
    matrices = [score_matrix([one.candidates[key] for key in keys], labels) for one in inputs]
    time_rank = {
        receipt.ingest_id: rank
        for rank, receipt in enumerate(sorted(receipts, key=receipt_time_order))
    }
    unknown = sorted({receipt_id for receipt_id, _ in keys} - set(time_rank))
    time_rank.update({receipt_id: len(time_rank) + i for i, receipt_id in enumerate(unknown)})
    order = [time_rank[receipt_id] for receipt_id, _ in keys]
    info: dict[str, Any] = {}
    deciders: list[int] | None = None
    if args.method == "cascade":
        combined, deciders = cascade(matrices, parameters["thresholds"])
        info["decided_by"] = {name: deciders.count(i) for i, name in enumerate(names)}
    elif args.method == "average":
        combined = average(matrices, parameters["weights"])
    else:
        combined, info = learned(
            matrices, labels, truth, order, usable, folds=args.folds, c=args.c, names=names
        )

    # Each run's best category as the run itself ranked it (ties keep the run's order).
    tops = [
        [one.candidates[key][0][0] if one.candidates[key] else None for key in keys]
        for one in inputs
    ]
    lines = []
    scored_items = []
    combined_top: list[str | None] = []
    for row, key in enumerate(keys):
        if deciders is not None:
            # The deciding run's own candidates, in its own order.
            chosen = inputs[deciders[row]].candidates[key]
            best = [(slug, score) for slug, score in chosen if score > 0][:3]
        else:
            best = top_three(combined[row], labels)
        combined_top.append(best[0][0] if best else None)
        seconds = [one.seconds[key] for one in inputs]
        costs = [one.costs[key] for one in inputs]
        lines.append(
            {
                "receipt_id": key[0],
                "position": key[1],
                "candidates": [
                    {"category_slug": slug, "score": round(score, SCORE_PLACES)}
                    for slug, score in best
                ],
                "source": "combined",
                "seconds": None if None in seconds else f"{sum(seconds):.3f}",  # type: ignore[arg-type]
                "cost_usd": None
                if any(cost is None for cost in costs)
                else format(exact_sum(c for c in costs if c is not None), "f"),
                "error": None,
            }
        )
        if usable[row]:
            label = truth[row]
            assert label is not None
            scored_items.append(
                Scored(tuple(slug for slug, _ in best), best[0][1] if best else 0.0, label)
            )

    started_at = datetime.now(UTC)
    material = json.dumps(
        [args.method, parameters, [one.summary.get("prompt_version") for one in inputs], names],
        sort_keys=True,
    )
    run_dir = make_run_dir(
        runs_dir, f"{started_at.strftime('%Y%m%dT%H%M%SZ')}-combined-{args.method}-items"
    )
    with _open_private(run_dir / "predictions.jsonl") as predictions:
        for line in lines:
            predictions.write(json.dumps(line, ensure_ascii=False) + "\n")
    summary: dict[str, Any] = {
        "task": TASK,
        "run_id": run_dir.name,
        "backend": "combined",
        "model_name": f"combined:{args.method}",
        "model_version": None,
        "prompt_version": hashlib.sha256(material.encode()).hexdigest()[:12],
        "method": args.method,
        "parameters": parameters,
        "method_info": info,
        "inputs": [
            {
                "run_id": one.name,
                "backend": one.summary.get("backend"),
                "model_name": one.summary.get("model_name"),
                "model_version": one.summary.get("model_version"),
                "prompt_version": one.summary.get("prompt_version"),
                "categories_version": one.summary.get("categories_version"),
            }
            for one in inputs
        ],
        "categorisers": categorisers,
        # Every categoriser behind every input, for the harness's pre-fill rule.
        "combined_from": [
            entry for one in inputs for entry in categoriser_entries(dict(one.summary))
        ],
        "score_kinds": {"combined": len(keys)},
        # Never claimed: a learned combination's probabilities are fitted to the labels, but its
        # warm-up block holds the plain average of the inputs' raw scores.
        "calibrated": False,
        "scores_calibrated": False,
        "git": git_commit(),
        "started_at": started_at.isoformat(),
        "counts": {
            "items": len(keys),
            "items_not_in_every_run": len(every) - len(common_keys),
            "labelled_items": sum(t is not None for t in truth),
            "excluded_by_prefill": sum(
                1 for key, t in zip(keys, truth, strict=True) if t is not None and key in excluded
            ),
            "scored_items": sum(usable),
            "labels": len(labels),
        },
        "agreement": agreement(tops, names, truth, usable, combined_top),
        "scores_on_usable_items": score_summary(scored_items),
    }
    write_private_json(run_dir / "run.json", summary)
    print_summary(summary, out)
    return summary


def print_summary(summary: dict[str, Any], out: TextIO) -> None:
    counts = summary["counts"]
    print(f"run {summary['run_id']}", file=out)
    print(
        "items {items} ({items_not_in_every_run} not in every run left out), labelled "
        "{labelled_items}, excluded by the pre-fill rule {excluded_by_prefill}, scored "
        "{scored_items}".format(**counts),
        file=out,
    )
    agreement = summary["agreement"]
    if agreement.get("items"):
        print(
            f"all agree on {agreement['all_agree_share']} of the scored items, precision "
            f"{agreement['all_agree_precision']}; combined accuracy "
            f"{agreement['combined_accuracy']}",
            file=out,
        )
    scores = summary["scores_on_usable_items"]
    if scores.get("items"):
        accepted = scores["accepted_at_95_precision"]
        print(
            f"top-3 {scores['top3_accuracy']}; auto-accepted at 95% precision "
            f"{accepted['share']} (threshold {accepted['threshold']})",
            file=out,
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        run(args)
    except UsageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
