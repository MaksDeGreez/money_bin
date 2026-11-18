"""Choose the categoriser's configuration on the validation slice. The test set stays sealed.

    uv run python -m categoriser.selection EXPORT_DIR [--out DIR] [--encoders e5-base e5-large]

Steps: read the export and build the rows; cut them by date into the fitting rows, the validation
slice (the end of the training period) and the test set, which is sealed (`categoriser.split`):
this command never reads a test row. Every candidate is fitted on the fitting rows and scored on the
validation slice; every hyper-parameter is tuned there; the selection rule (`SELECTION_RULE`, fixed
before any candidate was scored) picks one configuration. The selection JSON records the rule, the
table of every candidate with intervals, the tuning grids and the chosen configuration. The test set
is scored afterwards, once, by `categoriser.score`.

The candidates (`docs/decisions/0006-transaction-categoriser.md`):

- features: TF-IDF + fields (the first version), a sentence embedding + fields, or both, for each
  local encoder; `C` tuned for each;
- on each of those, with `C` kept: recency sample weights (half-life tuned), and class weights of
  another strength (power tuned; 1 is the first version's "balanced"); then both together with the
  tuned half-life and power, `C` tuned again;
- on each of the resulting models: no hybrid, the `mix` hybrid or the `switch` hybrid
  (`categoriser.hybrid`), each tuned.

Within a candidate, each setting is chosen by validation macro-F1; on a tie, the simpler setting
(the smaller `C`, the longer half-life, the power nearer 1, the earlier grid point).

The console shows counts and metrics only; the JSON holds category names and numbers only.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import importlib.util
import itertools
import json
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np

from categoriser.baselines import MajorityBaseline, PayeeMccBaseline, Predictions
from categoriser.common import (
    DEFAULT_OUT,
    DEFAULT_SEED,
    MODEL_NAME,
    TrainingError,
    check_options,
    environment,
    labels,
    load_rows,
    macro_f1,
    period,
    profile,
    refuse_repository,
    segments,
    sha256_file,
    write_private,
)
from categoriser.dataset import Row
from categoriser.embeddings import (
    DEFAULT_CACHE,
    ENCODERS,
    CachedEncoder,
    EmbeddingCache,
    EmbeddingError,
    Encoder,
    TransformerEncoder,
)
from categoriser.export import ExportError
from categoriser.hybrid import HybridParams
from categoriser.metrics import (
    HEADLINE,
    Encoded,
    day_block_samples,
    difference,
    evaluate,
    headline,
    intervals,
)
from categoriser.split import SplitError, time_split
from categoriser.systems import Config, System, fit_system
from categoriser.taxonomy import DEFAULT_TAXONOMY, TaxonomyError

SELECTION_VERSION = 1
FIRST_VERSION = "first_version"
DEFAULT_C_GRID = (0.1, 0.3, 1.0, 3.0, 10.0)
DEFAULT_HALF_LIVES = (60.0, 180.0, 365.0, 730.0)
DEFAULT_CLASS_WEIGHT_POWERS = (0.0, 0.25, 0.5, 0.75)
DEFAULT_ENCODERS = ("e5-base", "e5-large")
MIX_GRID = tuple(
    HybridParams(mode="mix", k=k, beta=beta, alpha_mcc=alpha_mcc)
    for k, beta, alpha_mcc in itertools.product((0.5, 2.0, 8.0), (0.0, 1.0, 3.0), (0.0, 0.3, 0.6))
)
SWITCH_GRID = tuple(
    HybridParams(mode="switch", min_count=count, min_purity=purity)
    for count, purity in itertools.product((1, 2, 3, 5), (0.5, 0.7, 0.9))
)
TIE_MARGIN = 0.005
SELECTION_RULE = {
    "statement": (
        "Fixed before any candidate was scored. (1) Eligible: every candidate whose validation "
        "top-3 accuracy is at least the lower end of the day-resampled 95% interval of the "
        "highest validation top-3 accuracy among all candidates. (2) Among the eligible, the "
        "best validation macro-F1. (3) Ties go to the simpler model: of the eligible candidates "
        "whose validation macro-F1 is within tie_margin of that best, the one with the lowest "
        "complexity (first: needs no neural encoder; then: fewest parts beyond the first "
        "version), then the higher macro-F1, then the name."
    ),
    "primary_metric": "macro_f1",
    "eligibility": "top3_accuracy >= lower end of the day-resampled ci95 of the best top3_accuracy",
    "tie_margin": TIE_MARGIN,
    "complexity": "(needs a neural encoder, parts beyond the first version)",
}


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
            taxonomy_path=Path(args.taxonomy).expanduser(),
            encoders=real_encoders(args.encoders, Path(args.embedding_cache).expanduser()),
            echo=print,
        )
    except (ExportError, SplitError, TaxonomyError, TrainingError, EmbeddingError) as error:
        print(f"The selection stopped: {error}", file=sys.stderr)
        return 1
    print(f"Selection: {result['selection_path']}")
    return 0


def run(
    *,
    export_dir: Path,
    out_dir: Path,
    seed: int = DEFAULT_SEED,
    test_fraction: float = 0.2,
    validation_fraction: float = 0.15,
    c_grid: Sequence[float] = DEFAULT_C_GRID,
    half_lives: Sequence[float] = DEFAULT_HALF_LIVES,
    class_weight_powers: Sequence[float] = DEFAULT_CLASS_WEIGHT_POWERS,
    mix_grid: Sequence[HybridParams] = MIX_GRID,
    switch_grid: Sequence[HybridParams] = SWITCH_GRID,
    resamples: int = 1000,
    min_df: int = 2,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
    encoders: Mapping[str, Encoder] | None = None,
    echo: Callable[[str], Any] = print,
) -> dict[str, Any]:
    """Score every candidate on the validation slice and choose one; return the selection."""
    if not c_grid or any(c <= 0 for c in c_grid):
        raise TrainingError("every C must be above 0")
    check_options(seed=seed, resamples=resamples, min_df=min_df)
    refuse_repository(out_dir)
    encoders = dict(encoders or {})

    export, rows, row_counts = load_rows(export_dir, taxonomy_path, echo)
    split = time_split(rows, test_fraction, validation_fraction)
    fit_rows, validation = split.fit, split.validation
    echo(
        f"Split: fitting {len(fit_rows)} rows, validation {len(validation)} rows from "
        f"{split.validation_cut}; test {split.test.size} rows from {split.test.cut} (sealed)"
    )

    started = time.perf_counter()
    baselines: dict[str, Predictions] = {}
    for baseline in (MajorityBaseline(), PayeeMccBaseline()):
        baselines[baseline.name] = baseline.fit(fit_rows).predict(validation)
    baseline_f1 = {name: macro_f1(validation, p) for name, p in baselines.items()}
    best_baseline = max(sorted(baseline_f1), key=lambda name: baseline_f1[name])

    tuning: dict[str, Any] = {}
    candidates: dict[str, Config] = {}
    predictions: dict[str, Predictions] = {}
    bases = [Config(min_df=min_df)]
    for name in encoders:
        bases += [
            Config(feature_set="embedding", encoder=name, min_df=min_df),
            Config(feature_set="tfidf+embedding", encoder=name, min_df=min_df),
        ]
    first_version: Config | None = None
    for base in bases:
        # C for the features, then the training-weight variants with that C kept.
        grid = [base.but(c=c) for c in c_grid]
        tuned_c, fitted, entry = _tune(grid, fit_rows, validation, seed, encoders, "c")
        tuning[tuned_c.name] = {"c": entry}
        if first_version is None:
            first_version = tuned_c
        variants = [(tuned_c, fitted)]
        chosen_values: dict[str, float] = {}
        for field, values in (
            ("half_life_days", half_lives),
            ("class_weight_power", class_weight_powers),
        ):
            if not values:
                continue
            grid = [tuned_c.but(**{field: value}) for value in values]
            config, system, entry = _tune(grid, fit_rows, validation, seed, encoders, field)
            tuning[config.name] = {"c": tuning[tuned_c.name]["c"], field: entry}
            variants.append((config, system))
            chosen_values[field] = getattr(config, field)
        if len(chosen_values) == 2:
            # Both weightings together, with C tuned again: class weights move the best C.
            grid = [tuned_c.but(c=c, **chosen_values) for c in c_grid]
            config, system, entry = _tune(grid, fit_rows, validation, seed, encoders, "c")
            tuning[config.name] = {**chosen_values, "c": entry}
            variants.append((config, system))
        for config, system in variants:
            model_p = system.model_probabilities(validation)
            _add(candidates, config)
            predictions[config.name] = system.predict(validation, model_p)
            for grid in (mix_grid, switch_grid):
                if not grid:
                    continue
                scores = []
                for params in grid:
                    score = macro_f1(
                        validation, system.with_hybrid(params).predict(validation, model_p)
                    )
                    scores.append({"params": params.as_dict(), "validation_macro_f1": score})
                best = max(range(len(grid)), key=lambda i: (scores[i]["validation_macro_f1"], -i))
                hybrid = system.with_hybrid(grid[best])
                _add(candidates, hybrid.config)
                predictions[hybrid.config.name] = hybrid.predict(validation, model_p)
                tuning[hybrid.config.name] = {**tuning[config.name], "hybrid": scores}
        echo(f"Tuned: {tuned_c.name} and its variants ({time.perf_counter() - started:.0f} s)")
    assert first_version is not None

    # Every candidate and baseline on the validation slice, with paired resamples.
    systems = {**baselines, **predictions}
    encoded = Encoded(labels(validation), systems)
    overall = evaluate(encoded, resamples=resamples, seed=seed)
    bootstrap = overall.pop("_bootstrap")
    by_day = day_block_samples(
        encoded, [row.occurred_on for row in validation], resamples=resamples, seed=seed
    )
    day_intervals = intervals(by_day)
    masks = segments(validation, {row.payee for row in fit_rows if row.payee})
    table = []
    for name, config in candidates.items():
        values = overall["systems"][name]
        table.append(
            {
                "name": name,
                "config": config.as_dict(),
                "complexity": list(config.complexity),
                "first_version": name == first_version.name,
                **{metric: values[metric]["value"] for metric in HEADLINE},
                "ci95_rows": {metric: values[metric]["ci95"] for metric in HEADLINE},
                "ci95_days": day_intervals[name],
                "minus_first_version_ci95_days": difference(by_day, name, first_version.name),
                "coverage": values["coverage"],
                "segments": _segment_scores(encoded, name, masks),
            }
        )
    chosen, trace = choose(table)
    echo_table(echo, table, chosen, trace)

    selection: dict[str, Any] = {
        "kind": "categoriser-selection",
        "selection_version": SELECTION_VERSION,
        "model_name": MODEL_NAME,
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "export": {
            "manifest_sha256": export.manifest_sha256,
            "date_from": export.date_from,
            "date_to": export.date_to,
        },
        "reproducibility": {
            "seed": seed,
            **environment(),
            "embedding_libraries": _optional_versions(("torch", "transformers"))
            if encoders
            else {},
            "parameters": {
                "test_fraction": test_fraction,
                "validation_fraction": validation_fraction,
                "c_grid": list(c_grid),
                "half_lives_days": list(half_lives),
                "class_weight_powers": list(class_weight_powers),
                "mix_grid": [p.as_dict() for p in mix_grid],
                "switch_grid": [p.as_dict() for p in switch_grid],
                "min_df": min_df,
                "bootstrap_resamples": resamples,
            },
            "encoders": {name: encoders[name].key for name in encoders},
            "taxonomy_sha256": sha256_file(taxonomy_path),
        },
        "rows": row_counts,
        "split": {
            "fit": period(fit_rows),
            "validation": period(validation),
            "test": {"rows": split.test.size, "first_date": str(split.test.cut), "sealed": True},
        },
        "profile": {
            "fit": profile(fit_rows, set()),
            "validation": profile(validation, {row.payee for row in fit_rows if row.payee}),
        },
        "baselines": {
            name: {
                **{metric: overall["systems"][name][metric]["value"] for metric in HEADLINE},
                "ci95_days": day_intervals[name],
            }
            for name in baselines
        },
        "best_baseline": best_baseline,
        "selection_rule": SELECTION_RULE,
        "selection_trace": trace,
        "candidates": table,
        "tuning": tuning,
        "first_version": {"name": first_version.name, "config": first_version.as_dict()},
        "chosen": {"name": chosen["name"], "config": chosen["config"]},
        "seconds": round(time.perf_counter() - started, 1),
    }
    # Model minus best baseline on validation, for the chosen candidate (days).
    selection["chosen"]["minus_best_baseline_ci95_days"] = difference(
        by_day, chosen["name"], best_baseline
    )
    selection["chosen"]["minus_best_baseline_ci95_rows"] = difference(
        bootstrap, chosen["name"], best_baseline
    )

    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    run_id = f"{datetime.now(UTC):%Y%m%dT%H%M%SZ}-{export.manifest_sha256[:12]}"
    path = out_dir / f"{MODEL_NAME}-{run_id}.selection.json"
    write_private(
        path, lambda handle: handle.write((json.dumps(selection, indent=2) + "\n").encode())
    )
    return {"selection": selection, "selection_path": path, "split": split}


def choose(table: Sequence[Mapping[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Apply `SELECTION_RULE` to the candidate table; return the chosen row and the trace."""
    best_top3 = max(table, key=lambda row: (row["top3_accuracy"], row["name"]))
    floor = best_top3["ci95_days"]["top3_accuracy"][0]
    eligible = [row for row in table if row["top3_accuracy"] >= floor]
    best_f1 = max(row["macro_f1"] for row in eligible)
    near = [row for row in eligible if row["macro_f1"] >= best_f1 - TIE_MARGIN]
    chosen = min(near, key=lambda row: (tuple(row["complexity"]), -row["macro_f1"], row["name"]))
    trace = {
        "best_top3": {"name": best_top3["name"], "top3_accuracy": best_top3["top3_accuracy"]},
        "top3_floor": floor,
        "eligible": [row["name"] for row in eligible],
        "best_eligible_macro_f1": best_f1,
        "within_tie_margin": [row["name"] for row in near],
        "chosen": chosen["name"],
    }
    return dict(chosen), trace


def _tune(
    grid: Sequence[Config],
    fit_rows: Sequence[Row],
    validation: Sequence[Row],
    seed: int,
    encoders: Mapping[str, Encoder],
    field: str,
) -> tuple[Config, System, list[dict[str, Any]]]:
    """Fit each configuration on the fitting rows; keep the best by validation macro-F1.

    Ties go to the simpler setting: the smaller C, the longer half-life, the power nearer 1."""
    results = []
    for config in grid:
        system = fit_system(config, fit_rows, seed=seed, encoders=encoders)
        score = macro_f1(validation, system.predict(validation))
        results.append((config, system, score))
    simpler = {
        "c": lambda config: -config.c,
        "half_life_days": lambda config: config.half_life_days,
        "class_weight_power": lambda config: -abs(config.class_weight_power - 1.0),
    }[field]
    config, system, _ = max(results, key=lambda item: (item[2], simpler(item[0])))
    entry = [{field: getattr(c, field), "validation_macro_f1": s} for c, _, s in results]
    return config, system, entry


def _segment_scores(encoded: Encoded, name: str, masks: Mapping[str, np.ndarray]) -> dict[str, Any]:
    out = {}
    for segment, mask in masks.items():
        if not mask.any():
            out[segment] = {"rows": 0}
            continue
        scores = headline(
            encoded.true[mask],
            encoded.top1[name][mask],
            encoded.in_top3[name][mask],
            len(encoded.labels),
        )
        out[segment] = {"rows": int(mask.sum()), **scores}
    return out


def echo_table(
    echo: Callable[[str], Any],
    table: Sequence[Mapping[str, Any]],
    chosen: Mapping[str, Any],
    trace: Mapping[str, Any],
) -> None:
    echo("Validation slice (95% intervals resampling days):")
    echo(f"  {'candidate':<34} {'macro-F1':>22} {'top-3':>22} {'accuracy':>7}")
    for row in sorted(table, key=lambda row: -row["macro_f1"]):
        cells = [
            f"{row[m]:.3f} [{row['ci95_days'][m][0]:.3f}, {row['ci95_days'][m][1]:.3f}]"
            for m in ("macro_f1", "top3_accuracy")
        ]
        mark = "*" if row["name"] == chosen["name"] else " "
        echo(f"{mark} {row['name']:<34} {cells[0]:>22} {cells[1]:>22} {row['accuracy']:>8.3f}")
    echo(
        f"Rule: top-3 floor {trace['top3_floor']:.3f} (from {trace['best_top3']['name']}), "
        f"{len(trace['eligible'])} eligible, {len(trace['within_tie_margin'])} within the tie "
        f"margin; chosen: {chosen['name']}"
    )


def _optional_versions(names: Sequence[str]) -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in names:
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
    return versions


def _add(candidates: dict[str, Config], config: Config) -> None:
    """A candidate name stands for one configuration: a grid that repeats the first version's
    values (a power of 1, say) would otherwise overwrite another candidate silently."""
    if config.name in candidates:
        raise TrainingError(
            f"two candidates are named {config.name}; leave the first version's values out of "
            "the grids"
        )
    candidates[config.name] = config


def real_encoders(names: Sequence[str], cache_dir: Path) -> dict[str, Encoder]:
    """The named local encoders behind the on-disk cache (outside any git repository)."""
    if not names:
        return {}
    unknown = [name for name in names if name not in ENCODERS]
    if unknown:
        raise TrainingError(f"unknown encoder(s): {', '.join(unknown)}")
    refuse_repository(cache_dir, "the embedding cache")
    missing = [name for name in ("torch", "transformers") if importlib.util.find_spec(name) is None]
    if missing:
        raise EmbeddingError(
            f"{' and '.join(missing)} not installed: the embeddings dependency group installs only "
            "on macOS on Apple silicon (uv sync in ml/); `--encoders` alone means TF-IDF only"
        )
    cache = EmbeddingCache(cache_dir)
    return {name: CachedEncoder(TransformerEncoder(ENCODERS[name]), cache) for name in names}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m categoriser.selection",
        description="Choose the categoriser's configuration on the validation slice "
        "(the test set stays sealed).",
    )
    parser.add_argument("export_dir", help="the export folder (MANIFEST.json and four JSONL files)")
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="where the selection JSON goes; outside any git repository (default: %(default)s)",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="random seed")
    parser.add_argument("--test-fraction", type=float, default=0.2)
    parser.add_argument("--validation-fraction", type=float, default=0.15)
    parser.add_argument("--c-grid", type=float, nargs="+", default=list(DEFAULT_C_GRID))
    parser.add_argument("--resamples", type=int, default=1000, help="bootstrap resamples")
    parser.add_argument("--min-df", type=int, default=2, help="minimum rows per n-gram")
    parser.add_argument(
        "--encoders",
        nargs="*",
        default=list(DEFAULT_ENCODERS),
        choices=sorted(ENCODERS),
        help="local sentence encoders to try (none: TF-IDF only) (default: %(default)s)",
    )
    parser.add_argument(
        "--embedding-cache",
        default=str(DEFAULT_CACHE),
        help="the embedding cache folder, outside any git repository (default: %(default)s)",
    )
    parser.add_argument(
        "--taxonomy",
        default=str(DEFAULT_TAXONOMY),
        help="the app's taxonomy; categories outside it are dropped (default: %(default)s)",
    )
    return parser


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
