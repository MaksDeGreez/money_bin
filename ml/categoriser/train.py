"""Train and evaluate the transaction categoriser on a history export.

    uv run python -m categoriser.train EXPORT_DIR [--out DIR] [--seed N]

Steps: verify and read the export; build one labelled row per transaction; cut the last 20% of the
rows by date off as the test set (whole days); cut a validation slice off the end of the training
period; choose the regularisation strength on the validation slice; fit the baselines and the final
model on the whole training period; evaluate every system once on the test set; write the model file
and a metrics JSON into the output folder (outside any git repository).

The console shows counts and metrics only. The metrics JSON holds category names and numbers only.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from collections import Counter
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import joblib
import numpy as np
import scipy
import sklearn

from categoriser.baselines import (
    MajorityBaseline,
    PayeeMccBaseline,
    Predictions,
    model_predictions,
)
from categoriser.dataset import Row, build_rows
from categoriser.export import ExportError, load_export
from categoriser.features import FEATURE_VERSION, build_model, features
from categoriser.metrics import Encoded, difference, evaluate, headline, mcnemar, per_class
from categoriser.split import SplitError, split_by_date

METRICS_VERSION = 1
MODEL_NAME = "transaction-categoriser"
DEFAULT_OUT = Path.home() / "Documents" / "money_bin_data" / "models"
DEFAULT_SEED = 42
DEFAULT_C_GRID = (0.1, 0.3, 1.0, 3.0, 10.0)
MIN_ROWS = 20


class TrainingError(Exception):
    """The training cannot run (bad arguments, output folder in a repository, too little data)."""


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = run(
            export_dir=Path(args.export_dir).expanduser(),
            out_dir=Path(args.out).expanduser(),
            seed=args.seed,
            test_fraction=args.test_fraction,
            validation_fraction=args.validation_fraction,
            c_grid=tuple(args.c_grid),
            resamples=args.resamples,
            min_df=args.min_df,
            echo=print,
        )
    except (ExportError, SplitError, TrainingError) as error:
        print(f"The training stopped: {error}", file=sys.stderr)
        return 1
    print(f"Model:   {result['model_path']}")
    print(f"Metrics: {result['metrics_path']}")
    return 0


def run(
    *,
    export_dir: Path,
    out_dir: Path,
    seed: int = DEFAULT_SEED,
    test_fraction: float = 0.2,
    validation_fraction: float = 0.15,
    c_grid: Sequence[float] = DEFAULT_C_GRID,
    resamples: int = 1000,
    min_df: int = 2,
    echo: Callable[[str], Any] = print,
) -> dict[str, Any]:
    """Run the whole training and evaluation; return the metrics and the paths written."""
    if not c_grid or any(c <= 0 for c in c_grid):
        raise TrainingError("every C must be above 0")
    if resamples < 1:
        raise TrainingError("resamples must be at least 1")
    _refuse_repository(out_dir)

    export = load_export(export_dir)
    rows, row_counts = build_rows(export)
    echo(
        f"Export: {row_counts['transactions']} transactions, "
        f"{row_counts['transfer_legs_excluded']} transfer legs excluded, "
        f"{row_counts['labelled_rows']} labelled rows"
    )
    if len(rows) < MIN_ROWS:
        raise TrainingError(f"only {len(rows)} labelled rows; at least {MIN_ROWS} are needed")

    outer = split_by_date(rows, test_fraction)
    train, test = outer.head, outer.tail
    inner = split_by_date(train, validation_fraction)
    fit_rows, validation = inner.head, inner.tail
    echo(
        f"Split: train {len(train)} rows (validation {len(validation)} from {inner.cut}), "
        f"test {len(test)} rows from {outer.cut}"
    )

    # Tuning: everything is fitted on the rows before the validation slice and scored on the slice.
    tuning = []
    for c in c_grid:
        model = build_model(c=c, seed=seed, min_df=min_df).fit(
            features(fit_rows), _labels(fit_rows)
        )
        score = _macro_f1(validation, model_predictions(model, validation))
        tuning.append({"c": c, "validation_macro_f1": score})
        echo(f"Tuning: C={c:g} validation macro-F1 {score:.4f}")
    best_c = max(tuning, key=lambda entry: (entry["validation_macro_f1"], -entry["c"]))["c"]

    baseline_scores = {}
    for baseline in (MajorityBaseline(), PayeeMccBaseline()):
        baseline.fit(fit_rows)
        baseline_scores[baseline.name] = _macro_f1(validation, baseline.predict(validation))
    best_baseline = max(sorted(baseline_scores), key=lambda name: baseline_scores[name])

    # The final systems: fitted on the whole training period, evaluated once on the test set.
    started = time.perf_counter()
    model = build_model(c=best_c, seed=seed, min_df=min_df).fit(features(train), _labels(train))
    fit_seconds = time.perf_counter() - started
    majority = MajorityBaseline().fit(train)
    payee_mcc = PayeeMccBaseline().fit(train)
    systems: dict[str, Predictions] = {
        majority.name: majority.predict(test),
        payee_mcc.name: payee_mcc.predict(test),
        "model": model_predictions(model, test),
    }
    echo(f"Model: C={best_c:g}, fitted in {fit_seconds:.1f} s")

    y_test = _labels(test)
    encoded = Encoded(y_test, systems)
    overall = evaluate(encoded, resamples=resamples, seed=seed)
    bootstrap = overall.pop("_bootstrap")
    correct = {name: encoded.top1[name] == encoded.true for name in encoded.systems}

    train_payees = {row.payee for row in train if row.payee}
    segments = _segments(test, train_payees)
    segment_results = {}
    for name, mask in segments.items():
        result = evaluate(encoded, mask, resamples=resamples, seed=seed, detail=False)
        result.pop("_bootstrap", None)
        segment_results[name] = result

    train_labels = Counter(_labels(train))
    unseen = [label for label in sorted(set(y_test)) if label not in train_labels]
    metrics: dict[str, Any] = {
        "metrics_version": METRICS_VERSION,
        "model_name": MODEL_NAME,
        "feature_version": FEATURE_VERSION,
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "export": {
            "manifest_sha256": export.manifest_sha256,
            "date_from": export.date_from,
            "date_to": export.date_to,
        },
        "reproducibility": {
            "seed": seed,
            "git": _git_state(),
            "python": platform.python_version(),
            "libraries": {
                "scikit-learn": sklearn.__version__,
                "numpy": np.__version__,
                "scipy": scipy.__version__,
                "joblib": joblib.__version__,
            },
            "parameters": {
                "test_fraction": test_fraction,
                "validation_fraction": validation_fraction,
                "c_grid": list(c_grid),
                "min_df": min_df,
                "bootstrap_resamples": resamples,
            },
        },
        "rows": row_counts,
        "split": {
            "train": _period(train),
            "validation": _period(validation),
            "test": _period(test),
            "test_share": len(test) / len(rows),
        },
        "profile": {"train": _profile(train, set()), "test": _profile(test, train_payees)},
        "labels": {
            "train_categories": len(train_labels),
            "test_categories": len(set(y_test)),
            "test_categories_not_in_train": unseen,
            "test_rows_with_category_not_in_train": sum(1 for y in y_test if y not in train_labels),
        },
        "tuning": {
            "grid": tuning,
            "chosen_c": best_c,
            "baseline_validation_macro_f1": baseline_scores,
            "best_baseline": best_baseline,
        },
        "training_seconds": round(fit_seconds, 3),
        "test": overall,
        "model_minus_best_baseline_ci95": difference(bootstrap, "model", best_baseline),
        "mcnemar_model_vs_best_baseline": {
            "baseline": best_baseline,
            **_rename(mcnemar(correct["model"], correct[best_baseline])),
        },
        "segments": segment_results,
        "per_class": per_class(encoded, train_labels),
    }

    run_id = f"{datetime.now(UTC):%Y%m%dT%H%M%SZ}-{export.manifest_sha256[:12]}"
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    model_path = out_dir / f"{MODEL_NAME}-{run_id}.joblib"
    metrics_path = out_dir / f"{MODEL_NAME}-{run_id}.metrics.json"
    artifact = {
        "pipeline": model,
        "model_name": MODEL_NAME,
        "feature_version": FEATURE_VERSION,
        "manifest_sha256": export.manifest_sha256,
        "trained_until": str(train[-1].occurred_on),
        "c": best_c,
        "seed": seed,
        "labels": [str(label) for label in model.classes_],
        "libraries": metrics["reproducibility"]["libraries"],
    }
    _write_private(model_path, lambda handle: joblib.dump(artifact, handle, compress=3))
    metrics["model_file"] = model_path.name
    _write_private(
        metrics_path,
        lambda handle: handle.write((json.dumps(metrics, indent=2) + "\n").encode("utf-8")),
    )
    _echo_summary(echo, metrics)
    return {"metrics": metrics, "model_path": model_path, "metrics_path": metrics_path}


def _labels(rows: Sequence[Row]) -> list[str]:
    return [row.label for row in rows]


def _macro_f1(rows: Sequence[Row], predictions: Predictions) -> float:
    encoded = Encoded(_labels(rows), {"system": predictions})
    scores = headline(
        encoded.true, encoded.top1["system"], encoded.in_top3["system"], len(encoded.labels)
    )
    return scores["macro_f1"]


def _segments(test: Sequence[Row], train_payees: set[str]) -> dict[str, np.ndarray]:
    bank = np.array([row.has_bank_fields for row in test], dtype=bool)
    seen = np.array([bool(row.payee) and row.payee in train_payees for row in test], dtype=bool)
    return {
        "with_bank_fields": bank,
        "without_bank_fields": ~bank,
        "payee_seen_in_train": seen,
        "payee_unseen_or_missing": ~seen,
    }


def _period(rows: Sequence[Row]) -> dict[str, Any]:
    return {
        "rows": len(rows),
        "first_date": str(rows[0].occurred_on),
        "last_date": str(rows[-1].occurred_on),
        "days": len({row.occurred_on for row in rows}),
    }


def _profile(rows: Sequence[Row], train_payees: set[str]) -> dict[str, float]:
    n = len(rows)
    profile = {
        "with_bank_fields": sum(row.has_bank_fields for row in rows) / n,
        "with_mcc": sum(bool(row.mcc) for row in rows) / n,
        "with_bank_description": sum(bool(row.bank_description) for row in rows) / n,
        "with_payee": sum(bool(row.payee) for row in rows) / n,
        "with_comment": sum(bool(row.comment) for row in rows) / n,
        "expenses": sum(row.amount < 0 for row in rows) / n,
    }
    if train_payees:
        profile["payee_seen_in_train"] = sum(row.payee in train_payees for row in rows) / n
    return profile


def _rename(result: dict[str, Any]) -> dict[str, Any]:
    renamed = dict(result)
    renamed["model_only_correct"] = renamed.pop("a_only_correct")
    renamed["baseline_only_correct"] = renamed.pop("b_only_correct")
    return renamed


def _refuse_repository(out_dir: Path) -> None:
    """The model's vocabulary holds payee names: it must never land inside a git repository."""
    resolved = out_dir.expanduser().resolve()
    for folder in (resolved, *resolved.parents):
        if (folder / ".git").exists():
            raise TrainingError("the output folder is inside a git repository; choose one outside")


def _write_private(path: Path, write: Callable[[Any], Any]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        write(handle)


def _git_state() -> dict[str, Any]:
    here = Path(__file__).resolve().parent
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=here, capture_output=True, text=True, check=True
        ).stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain"], cwd=here, capture_output=True, text=True, check=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return {"sha": None, "dirty": None}
    return {"sha": sha, "dirty": bool(status.strip())}


def _echo_summary(echo: Callable[[str], Any], metrics: dict[str, Any]) -> None:
    echo("Test set (95% bootstrap intervals):")
    echo(f"  {'system':<10} {'macro-F1':>22} {'weighted-F1':>22} {'top-3':>22}")
    for name, values in metrics["test"]["systems"].items():
        cells = [
            f"{values[m]['value']:.3f} [{values[m]['ci95'][0]:.3f}, {values[m]['ci95'][1]:.3f}]"
            for m in ("macro_f1", "weighted_f1", "top3_accuracy")
        ]
        echo(f"  {name:<10} " + " ".join(f"{cell:>22}" for cell in cells))
    for segment, result in metrics["segments"].items():
        if not result["systems"]:
            continue
        parts = ", ".join(
            f"{name} {values['macro_f1']['value']:.3f}"
            for name, values in result["systems"].items()
        )
        echo(f"  segment {segment} ({result['rows']} rows): macro-F1 {parts}")
    test_ = metrics["mcnemar_model_vs_best_baseline"]
    echo(
        f"McNemar, model vs {test_['baseline']}: model only right {test_['model_only_correct']}, "
        f"baseline only right {test_['baseline_only_correct']}, "
        f"exact p = {test_['exact_p_value']:.3g}"
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m categoriser.train",
        description="Train and evaluate the transaction categoriser on a history export.",
    )
    parser.add_argument("export_dir", help="the export folder (MANIFEST.json and four JSONL files)")
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="where the model file and the metrics JSON go; must be outside any git repository "
        "(default: %(default)s)",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="random seed")
    parser.add_argument("--test-fraction", type=float, default=0.2)
    parser.add_argument("--validation-fraction", type=float, default=0.15)
    parser.add_argument(
        "--c-grid",
        type=float,
        nargs="+",
        default=list(DEFAULT_C_GRID),
        help="the inverse regularisation strengths tried on the validation slice",
    )
    parser.add_argument("--resamples", type=int, default=1000, help="bootstrap resamples")
    parser.add_argument("--min-df", type=int, default=2, help="minimum rows per n-gram")
    return parser


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
