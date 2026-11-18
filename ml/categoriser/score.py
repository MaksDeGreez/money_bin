"""Score the test set once, for the one configuration a selection run chose.

    uv run python -m categoriser.score EXPORT_DIR --selection FILE [--out DIR]

This is the only step that unseals the test set. It reads the selection JSON written by
`categoriser.selection`, checks that the export, the taxonomy and the split are the ones the
selection used, refits the chosen configuration on the whole training period (the fitting rows and
the validation slice) with every tuned value kept as it was chosen, refits the first version and the
rule baselines the same way, and scores them all on the test set: the metrics of the first version,
plus the paired comparison of the final model with the first version on the same rows.

A test set is scored once. Every unsealing is appended to a record of test scores kept next to the
data folder (`DEFAULT_LEDGER`, whatever `--out` is) before the first test row is read, so a crash
after it still counts. The command refuses when that record, or the output folder, already holds a
score of the same export; `--rescore-reason` overrides that and the reason is recorded. It also
refuses when the code (git commit, or a modified tree), an encoder, the selection format or the test
set differ from the selection's; `--code-change-reason` overrides a code difference only, recorded.
The metrics JSON records which configuration was scored, from which selection file, and when.

The console shows counts and metrics only; the JSON holds category names and numbers only.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
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
    DEFAULT_LEDGER,
    DEFAULT_OUT,
    MODEL_NAME,
    TrainingError,
    check_options,
    environment,
    git_state,
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
from categoriser.selection import (
    FIRST_VERSION,
    SELECTION_VERSION,
    choose,
    optional_versions,
    real_encoders,
)
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
                config.encoder
                for config in (_config(selection, "chosen"), _config(selection, "first_version"))
                if config.encoder
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
            code_change_reason=args.code_change_reason,
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
    code_change_reason: str | None = None,
    ledger_path: Path | None = None,
    echo: Callable[[str], Any] = print,
) -> dict[str, Any]:
    """Refit the chosen configuration and score the test set once; return the metrics.

    `ledger_path` is for the tests only; the command always uses `DEFAULT_LEDGER`."""
    ledger_path = DEFAULT_LEDGER if ledger_path is None else ledger_path
    selection = _read_selection(selection_path)
    reproducibility = selection["reproducibility"]
    parameters = reproducibility["parameters"]
    seed = reproducibility["seed"]
    check_options(seed=seed, resamples=resamples)
    refuse_repository(out_dir)
    refuse_repository(ledger_path.parent, "the record of test scores")
    if sha256_file(taxonomy_path) != reproducibility["taxonomy_sha256"]:
        raise TrainingError("the taxonomy is not the one the selection used")
    manifest = selection["export"]["manifest_sha256"]
    in_ledger = _ledger_scores(ledger_path, manifest)
    earlier = _earlier_scores(out_dir, manifest) + in_ledger
    if earlier and not _given(rescore_reason):
        raise TrainingError(
            f"this export's test set was already scored ({', '.join(earlier)}); it is scored "
            "once. Pass --rescore-reason to score it again, and the reason is recorded"
        )
    code = git_state()
    selected_code = reproducibility["git"]
    libraries = {**environment()["libraries"], **optional_versions(("torch", "transformers"))}
    selected_libraries = {
        **reproducibility["libraries"],
        **(reproducibility.get("embedding_libraries") or {}),
    }
    code_differs = (
        code["sha"] is None
        or code["sha"] != selected_code["sha"]
        or code["dirty"] is not False
        or selected_code["dirty"] is not False
        or any(libraries.get(name) != version for name, version in selected_libraries.items())
    )
    if code_differs and not _given(code_change_reason):
        raise TrainingError(
            "the code is not the committed code the selection ran on (another or an unknown "
            "commit, a modified tree, or other library versions); run the selection again, or "
            "pass --code-change-reason"
        )

    chosen = _config(selection, "chosen")
    first = _config(selection, "first_version")
    rechosen, _trace = choose(selection["candidates"])
    if (
        rechosen["name"] != selection["chosen"]["name"]
        or rechosen["config"] != (selection["chosen"]["config"])
    ):
        raise TrainingError("the chosen configuration is not the one the selection rule picks")
    selected_encoders = reproducibility["encoders"]
    for name in {config.encoder for config in (chosen, first) if config.encoder}:
        if name not in (encoders or {}) or (encoders or {})[name].key != selected_encoders.get(
            name
        ):
            raise TrainingError(f"the encoder {name!r} is not the one the selection used")

    export, rows, row_counts = load_rows(export_dir, taxonomy_path, echo)
    if export.manifest_sha256 != selection["export"]["manifest_sha256"]:
        raise TrainingError("the export is not the one the selection used")
    split = time_split(rows, parameters["test_fraction"], parameters["validation_fraction"])
    if (
        period(split.fit) != selection["split"]["fit"]
        or period(split.validation) != selection["split"]["validation"]
    ):
        raise TrainingError("the split differs from the selection's")
    if (
        split.test.size != selection["split"]["test"]["rows"]
        or str(split.test.cut) != (selection["split"]["test"]["first_date"])
    ):
        raise TrainingError("the test set differs from the selection's")

    selection_sha = sha256_file(selection_path)
    purpose = f"final score of {chosen.name} (selection {selection_sha[:12]})"
    echo(f"Refitting {chosen.name} and the first version on the whole training period")
    train = split.train
    started = time.perf_counter()
    final = fit_system(chosen, train, seed=seed, encoders=encoders or {})
    fit_seconds = time.perf_counter() - started
    first_version = fit_system(first, train, seed=seed, encoders=encoders or {})
    for encoder in (encoders or {}).values():
        # Every training text is cached, so the encoder model first loads for the test texts:
        # load it now, so a missing model fails before the seal opens.
        prepare = getattr(encoder, "prepare", None)
        if prepare is not None:
            prepare()

    # The seal opens only now, and the record of it is written before any test row is read.
    scored_at = datetime.now(UTC).isoformat(timespec="seconds")
    _record(
        ledger_path,
        {
            "unsealed_at": scored_at,
            "manifest_sha256": manifest,
            "selection_sha256": selection_sha,
            "configuration": chosen.name,
            "test_rows": split.test.size,
            "test_first_date": str(split.test.cut),
            "git_sha": code["sha"],
            "rescore_reason": rescore_reason if earlier else None,
            "code_change_reason": code_change_reason if code_differs else None,
        },
        known=len(in_ledger),
        rescore=_given(rescore_reason),
    )
    echo(f"Scoring the test set once: {chosen.name}")
    test = split.test.unseal(purpose)
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
            "code": {
                "at_scoring": code,
                "at_selection": selected_code,
                "libraries_at_scoring": libraries,
            },
            "code_change_reason": code_change_reason if code_differs else None,
            "record_of_test_scores": ledger_path.name,
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
    if selection.get("selection_version") != SELECTION_VERSION:
        raise TrainingError("the selection file was written by another version of the selection")
    return selection


def _given(reason: str | None) -> bool:
    return bool(reason and reason.strip())


def _config(selection: dict[str, Any], key: str) -> Config:
    try:
        return Config.from_dict(selection[key]["config"])
    except (KeyError, TypeError):
        raise TrainingError(f"the selection file has no usable {key} configuration") from None


def _record(path: Path, entry: dict[str, Any], *, known: int, rescore: bool) -> None:
    """Append one unsealing to the record of test scores, mode 600, under an exclusive lock.

    Under the lock the record is read again: if another run recorded a score of the same export
    since this run checked (`known` entries then), this run stops unless it is a rescore."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            if len(_ledger_scores(path, entry["manifest_sha256"])) > known and not rescore:
                raise TrainingError(
                    "another run scored this export's test set meanwhile; it is scored once"
                )
            handle.write(json.dumps(entry) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def _ledger_scores(path: Path, manifest_sha256: str) -> list[str]:
    """Unsealings of the same export in the record of test scores."""
    if not path.exists():
        return []
    found = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        try:
            entry = json.loads(line)
        except ValueError:
            found.append(f"{path.name} line {number}")  # unreadable: count it
            continue
        if not isinstance(entry, dict) or entry.get("manifest_sha256") == manifest_sha256:
            found.append(f"{path.name} line {number}")
    return found


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
        help="score an export whose test set was already scored, recording why",
    )
    parser.add_argument(
        "--code-change-reason",
        default=None,
        help="score although the code differs from the selection's, recording why",
    )

    return parser


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
