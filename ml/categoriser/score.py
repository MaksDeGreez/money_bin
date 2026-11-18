"""Score the test set once, for the one configuration a selection run chose.

    uv run python -m categoriser.score EXPORT_DIR --selection FILE [--out DIR]

This is the only step that unseals the test set. It reads the selection JSON written by
`categoriser.selection`, checks that the export, the taxonomy and the split are the ones the
selection used, refits the chosen configuration on the whole training period (the fitting rows and
the validation slice) with every tuned value kept as it was chosen, refits the first version and the
rule baselines the same way, and scores them all on the test set: the metrics of the first version,
plus the paired comparison of the final model with the first version on the same rows.

A test set is scored once. The command refuses when the output folder already holds a final score
of the same export; `--rescore-reason` overrides that and the reason is recorded in the metrics. The
metrics JSON records which configuration was scored, from which selection file, and when.

The console shows counts and metrics only; the JSON holds category names and numbers only.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import joblib

from categoriser.baselines import MajorityBaseline, PayeeMccBaseline, Predictions
from categoriser.common import (
    DEFAULT_OUT,
    MODEL_NAME,
    TrainingError,
    check_options,
    environment,
    labels,
    load_rows,
    period,
    profile,
    refuse_repository,
    rename_mcnemar,
    segments,
    sha256_file,
    write_private,
)
from categoriser.embeddings import DEFAULT_CACHE, EmbeddingError, Encoder
from categoriser.export import ExportError
from categoriser.features import FEATURE_VERSION
from categoriser.metrics import (
    Encoded,
    day_block_samples,
    difference,
    evaluate,
    intervals,
    mcnemar,
    per_class,
)
from categoriser.selection import FIRST_VERSION, real_encoders
from categoriser.split import SplitError, time_split
from categoriser.systems import Config, fit_system
from categoriser.taxonomy import DEFAULT_TAXONOMY, TaxonomyError

METRICS_VERSION = 3
FINAL = "final"
EARLIER_RESULT_SEEN = (
    "A test result of the first version (TF-IDF + logistic regression) had been seen before the "
    "candidates were designed. Every later choice was made on the validation slice; this is the "
    "one test score of the final configuration."
)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        selection_path = Path(args.selection).expanduser()
        selection = _read_selection(selection_path)
        names = sorted(
            {
                config["encoder"]
                for config in (selection["chosen"]["config"], selection["first_version"]["config"])
                if config["encoder"]
            }
        )
        result = run(
            export_dir=Path(args.export_dir).expanduser(),
            selection_path=selection_path,
            out_dir=Path(args.out).expanduser(),
            resamples=args.resamples,
            taxonomy_path=Path(args.taxonomy).expanduser(),
            encoders=real_encoders(names, Path(args.embedding_cache).expanduser()),
            rescore_reason=args.rescore_reason,
            echo=print,
        )
    except (ExportError, SplitError, TaxonomyError, TrainingError, EmbeddingError) as error:
        print(f"The scoring stopped: {error}", file=sys.stderr)
        return 1
    print(f"Model:   {result['model_path']}")
    print(f"Metrics: {result['metrics_path']}")
    return 0


def run(
    *,
    export_dir: Path,
    selection_path: Path,
    out_dir: Path,
    resamples: int = 1000,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
    encoders: Mapping[str, Encoder] | None = None,
    rescore_reason: str | None = None,
    echo: Callable[[str], Any] = print,
) -> dict[str, Any]:
    """Refit the chosen configuration and score the test set once; return the metrics."""
    selection = _read_selection(selection_path)
    reproducibility = selection["reproducibility"]
    parameters = reproducibility["parameters"]
    seed = reproducibility["seed"]
    check_options(seed=seed, resamples=resamples)
    refuse_repository(out_dir)
    if sha256_file(taxonomy_path) != reproducibility["taxonomy_sha256"]:
        raise TrainingError("the taxonomy is not the one the selection used")
    earlier = _earlier_scores(out_dir, selection["export"]["manifest_sha256"])
    if earlier and not (rescore_reason and rescore_reason.strip()):
        raise TrainingError(
            f"this export's test set was already scored ({', '.join(earlier)}); it is scored "
            "once. Pass --rescore-reason to score it again, and the reason is recorded"
        )

    export, rows, row_counts = load_rows(export_dir, taxonomy_path, echo)
    if export.manifest_sha256 != selection["export"]["manifest_sha256"]:
        raise TrainingError("the export is not the one the selection used")
    split = time_split(rows, parameters["test_fraction"], parameters["validation_fraction"])
    if (
        period(split.fit) != selection["split"]["fit"]
        or period(split.validation) != selection["split"]["validation"]
    ):
        raise TrainingError("the split differs from the selection's")

    chosen = Config.from_dict(selection["chosen"]["config"])
    first = Config.from_dict(selection["first_version"]["config"])
    selection_sha = sha256_file(selection_path)
    purpose = f"final score of {chosen.name} (selection {selection_sha[:12]})"
    echo(f"Scoring the test set once: {chosen.name}, refitted on the whole training period")
    train = split.train
    test = split.test.unseal(purpose)
    scored_at = datetime.now(UTC).isoformat(timespec="seconds")

    started = time.perf_counter()
    final = fit_system(chosen, train, seed=seed, encoders=encoders or {})
    fit_seconds = time.perf_counter() - started
    first_version = fit_system(first, train, seed=seed, encoders=encoders or {})
    systems: dict[str, Predictions] = {}
    for baseline in (MajorityBaseline(), PayeeMccBaseline()):
        systems[baseline.name] = baseline.fit(train).predict(test)
    systems[FIRST_VERSION] = first_version.predict(test)
    systems[FINAL] = final.predict(test)
    best_baseline = selection["best_baseline"]

    y_test = labels(test)
    encoded = Encoded(y_test, systems)
    overall = evaluate(encoded, resamples=resamples, seed=seed)
    bootstrap = overall.pop("_bootstrap")
    by_day = day_block_samples(
        encoded, [row.occurred_on for row in test], resamples=resamples, seed=seed
    )
    correct = {name: encoded.top1[name] == encoded.true for name in encoded.systems}
    train_payees = {row.payee for row in train if row.payee}
    segment_results = {}
    for name, mask in segments(test, train_payees).items():
        result = evaluate(encoded, mask, resamples=resamples, seed=seed, detail=False)
        result.pop("_bootstrap", None)
        segment_results[name] = result

    train_labels = Counter(labels(train))
    metrics: dict[str, Any] = {
        "kind": "categoriser-final-score",
        "metrics_version": METRICS_VERSION,
        "model_name": MODEL_NAME,
        "feature_version": FEATURE_VERSION,
        "created_at": scored_at,
        "final_scoring": {
            "scored_at": scored_at,
            "configuration": {"name": chosen.name, "config": chosen.as_dict()},
            "refitted_on": "the whole training period (fitting rows and validation slice)",
            "unsealed_for": purpose,
            "earlier_scores_of_this_export": earlier,
            "rescore_reason": rescore_reason if earlier else None,
            "protocol": EARLIER_RESULT_SEEN,
        },
        "selection": {
            "file": selection_path.name,
            "sha256": selection_sha,
            "created_at": selection["created_at"],
            "rule": selection["selection_rule"],
            "trace": selection["selection_trace"],
            "first_version": selection["first_version"],
            "best_baseline": best_baseline,
        },
        "export": selection["export"],
        "reproducibility": {
            "seed": seed,
            **environment(),
            "embedding_libraries": reproducibility.get("embedding_libraries", {}),
            "encoders": {name: encoder.key for name, encoder in (encoders or {}).items()},
            "parameters": {**parameters, "bootstrap_resamples": resamples},
            "taxonomy_sha256": reproducibility["taxonomy_sha256"],
        },
        "rows": row_counts,
        "split": {
            "train": period(train),
            "validation": period(split.validation),
            "test": period(test),
            "test_share": len(test) / len(rows),
        },
        "profile": {"train": profile(train, set()), "test": profile(test, train_payees)},
        "labels": {
            "train_categories": len(train_labels),
            "test_categories": len(set(y_test)),
            "test_categories_not_in_train": [
                label for label in sorted(set(y_test)) if label not in train_labels
            ],
            "test_rows_with_category_not_in_train": sum(1 for y in y_test if y not in train_labels),
        },
        "training_seconds": round(fit_seconds, 3),
        "test": overall,
        "test_ci95_resampling_days": intervals(by_day),
        "final_minus_best_baseline_ci95": difference(bootstrap, FINAL, best_baseline),
        "final_minus_best_baseline_ci95_resampling_days": difference(by_day, FINAL, best_baseline),
        "final_minus_first_version_ci95": difference(bootstrap, FINAL, FIRST_VERSION),
        "final_minus_first_version_ci95_resampling_days": difference(by_day, FINAL, FIRST_VERSION),
        "mcnemar_final_vs_best_baseline": {
            "baseline": best_baseline,
            **rename_mcnemar(mcnemar(correct[FINAL], correct[best_baseline]), FINAL, "baseline"),
        },
        "mcnemar_final_vs_first_version": rename_mcnemar(
            mcnemar(correct[FINAL], correct[FIRST_VERSION]), FINAL, FIRST_VERSION
        ),
        "mcnemar_first_version_vs_best_baseline": {
            "baseline": best_baseline,
            **rename_mcnemar(
                mcnemar(correct[FIRST_VERSION], correct[best_baseline]), FIRST_VERSION, "baseline"
            ),
        },
        "segments": segment_results,
        "per_class": per_class(encoded, train_labels),
    }

    run_id = f"{datetime.now(UTC):%Y%m%dT%H%M%SZ}-{export.manifest_sha256[:12]}"
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    model_path = out_dir / f"{MODEL_NAME}-{run_id}.final.joblib"
    metrics_path = out_dir / f"{MODEL_NAME}-{run_id}.final.json"
    artifact = {
        "pipeline": final.pipeline,
        "rule_tables": final.tables if chosen.hybrid is not None else None,
        "config": chosen.as_dict(),
        "encoder": metrics["reproducibility"]["encoders"].get(chosen.encoder or ""),
        "model_name": MODEL_NAME,
        "feature_version": FEATURE_VERSION,
        "manifest_sha256": export.manifest_sha256,
        "trained_until": str(train[-1].occurred_on),
        "seed": seed,
        "labels": final.classes,
        "libraries": metrics["reproducibility"]["libraries"],
    }
    write_private(model_path, lambda handle: joblib.dump(artifact, handle, compress=3))
    metrics["model_file"] = model_path.name
    write_private(
        metrics_path, lambda handle: handle.write((json.dumps(metrics, indent=2) + "\n").encode())
    )
    _echo_summary(echo, metrics)
    return {"metrics": metrics, "model_path": model_path, "metrics_path": metrics_path}


def _read_selection(path: Path) -> dict[str, Any]:
    try:
        selection = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise TrainingError("the selection file cannot be read") from None
    if not isinstance(selection, dict) or selection.get("kind") != "categoriser-selection":
        raise TrainingError("the selection file is not a categoriser selection")
    return selection


def _earlier_scores(out_dir: Path, manifest_sha256: str) -> list[str]:
    """Final scores of the same export already in the output folder."""
    found = []
    for path in sorted(out_dir.glob(f"{MODEL_NAME}-*.final.json")):
        try:
            metrics = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            found.append(path.name)  # unreadable: count it, rather than score again silently
            continue
        if metrics.get("export", {}).get("manifest_sha256") == manifest_sha256:
            found.append(path.name)
    return found


def _echo_summary(echo: Callable[[str], Any], metrics: dict[str, Any]) -> None:
    echo("Test set (95% intervals: rows / days):")
    days = metrics["test_ci95_resampling_days"]
    echo(f"  {'system':<14} {'macro-F1':>34} {'top-3':>34}")
    for name, values in metrics["test"]["systems"].items():
        cells = [
            f"{values[m]['value']:.3f} [{values[m]['ci95'][0]:.3f}, {values[m]['ci95'][1]:.3f}]"
            f" [{days[name][m][0]:.3f}, {days[name][m][1]:.3f}]"
            for m in ("macro_f1", "top3_accuracy")
        ]
        echo(f"  {name:<14} " + " ".join(f"{cell:>34}" for cell in cells))
    for segment, result in metrics["segments"].items():
        if not result["systems"]:
            continue
        parts = ", ".join(
            f"{name} {values['macro_f1']['value']:.3f}/{values['accuracy']['value']:.3f}"
            for name, values in result["systems"].items()
        )
        echo(f"  segment {segment} ({result['rows']} rows): macro-F1/accuracy {parts}")
    for key, other in (
        ("mcnemar_final_vs_best_baseline", "baseline"),
        ("mcnemar_final_vs_first_version", FIRST_VERSION),
    ):
        test_ = metrics[key]
        echo(
            f"McNemar, final vs {test_.get('baseline', other)}: final only right "
            f"{test_['final_only_correct']}, other only right {test_[f'{other}_only_correct']}, "
            f"exact p = {test_['exact_p_value']:.3g}"
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m categoriser.score",
        description="Score the test set once, for the configuration a selection run chose.",
    )
    parser.add_argument("export_dir", help="the export folder the selection used")
    parser.add_argument("--selection", required=True, help="the selection JSON")
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="where the model file and the metrics JSON go; outside any git repository "
        "(default: %(default)s)",
    )
    parser.add_argument("--resamples", type=int, default=1000, help="bootstrap resamples")
    parser.add_argument(
        "--embedding-cache",
        default=str(DEFAULT_CACHE),
        help="the embedding cache folder (default: %(default)s)",
    )
    parser.add_argument(
        "--taxonomy",
        default=str(DEFAULT_TAXONOMY),
        help="the taxonomy the selection used (default: %(default)s)",
    )
    parser.add_argument(
        "--rescore-reason",
        default=None,
        help="score an export whose test set was already scored here, recording why",
    )
    return parser


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
