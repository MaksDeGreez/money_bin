"""The evaluation harness: every number of the results chapter from one command, offline.

    make eval                                    # from the repository root, with the defaults
    uv run python -m evaluation.harness --receipts ~/Documents/money_bin_data/receipts \\
        --runs ~/Documents/money_bin_data/runs \\
        --ground-truth ~/Documents/money_bin_data/ground_truth --out ../eval/results

It reads the receipt set (`receipts.jsonl`), the ground-truth export (`ground_truth.jsonl`,
optional) and every run folder under `--runs` (`run.json` + `predictions.jsonl`, at any depth),
scores each run, compares the runs it is told to compare and those that differ in one setting, and
writes:

- `OUT/index.json`, `OUT/runs/<run id>.json`, `OUT/comparisons/<a>__vs__<b>.json`: aggregates only,
  through `evaluation.results` (a whitelisted structure: numbers, category slugs, model names, run
  parameters);
- `OUT/tables/*.md` and `*.csv`, generated from those JSON files.

Files in those subfolders that this run did not write are removed, so the folder always matches the
inputs. The same inputs give byte-identical files. `--check` validates the inputs and prints what
would be scored, writing nothing. `--diagnostics DIR` also writes per-receipt detail, to a folder
outside any git repository, readable by the owner only. The console shows aggregates only.
"""

import argparse
import hashlib
import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any, TextIO

from evaluation import category_scoring, ocr_scoring, tables
from evaluation.common import (
    UsageError,
    ensure_private_folder,
    inside_git_repository,
    write_private_json,
)
from evaluation.comparisons import automatic_pairs, compare_categories, compare_ocr
from evaluation.inputs import (
    GROUND_TRUTH_FILE,
    Run,
    discover_runs,
    file_sha256,
    read_ground_truth,
    read_receipt_set,
)
from evaluation.matching import AMOUNT_WEIGHT, MATCH_THRESHOLD, NAME_THRESHOLD, NAME_WEIGHT
from evaluation.models import is_path
from evaluation.results import (
    CATEGORY_COMPARISON,
    CATEGORY_RUN_RESULT,
    INDEX,
    OCR_COMPARISON,
    OCR_RUN_RESULT,
    RESULTS_VERSION,
    ResultsShapeError,
    ResultsWriter,
)
from evaluation.truth import GroundTruth

REPOSITORY = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPOSITORY / "eval" / "results"
DATA = Path("~/Documents/money_bin_data")


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.harness",
        description="Score every run against the receipt set and the ground truth.",
    )
    parser.add_argument("--receipts", type=Path, default=DATA / "receipts")
    parser.add_argument("--runs", type=Path, default=DATA / "runs")
    parser.add_argument("--ground-truth", type=Path, default=DATA / "ground_truth")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the results folder")
    parser.add_argument(
        "--compare",
        nargs=2,
        action="append",
        default=[],
        metavar=("RUN_A", "RUN_B"),
        help="compare two runs (repeatable); the difference is A - B",
    )
    parser.add_argument(
        "--comparisons",
        type=Path,
        help="a file of 'RUN_A RUN_B' lines (default: comparisons.txt in the runs folder)",
    )
    parser.add_argument(
        "--no-auto-compare", action="store_true", help="only the declared comparisons"
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--resamples", type=int, default=1000)
    parser.add_argument("--check", action="store_true", help="validate and report; write nothing")
    parser.add_argument(
        "--diagnostics", type=Path, help="a private folder outside git for per-receipt detail"
    )
    args = parser.parse_args(argv)
    if args.resamples < 1:
        parser.error("--resamples must be 1 or more")
    if args.seed < 0:
        parser.error("--seed must be 0 or more")
    return args


def read_comparison_file(path: Path) -> list[tuple[str, str]]:
    pairs = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        text = line.split("#", 1)[0].strip()
        if not text:
            continue
        parts = text.split()
        if len(parts) != 2:
            raise UsageError(f"{path.name}: line {number} needs two run ids")
        pairs.append((parts[0], parts[1]))
    return pairs


def plan_comparisons(
    runs: list[Run], declared: list[tuple[str, str]], *, automatic: bool
) -> list[tuple[Run, Run, str, bool]]:
    """(A, B, dimension, declared) in a stable order, without repeating a pair."""
    by_id = {run.run_id: run for run in runs}
    auto = automatic_pairs(runs) if automatic else []
    auto_dimension = {frozenset((a.run_id, b.run_id)): dimension for a, b, dimension in auto}
    planned: dict[frozenset[str], tuple[Run, Run, str, bool]] = {}
    for a_id, b_id in declared:
        for run_id in (a_id, b_id):
            if run_id not in by_id:
                raise UsageError(f"a declared comparison names an unknown run: {run_id}")
        a, b = by_id[a_id], by_id[b_id]
        if a.run_id == b.run_id:
            raise UsageError("a declared comparison names the same run twice")
        if a.task != b.task:
            raise UsageError(f"{a_id} and {b_id} are runs of different tasks")
        key = frozenset((a_id, b_id))
        planned[key] = (a, b, auto_dimension.get(key, "declared"), True)
    for a, b, dimension in auto:
        planned.setdefault(frozenset((a.run_id, b.run_id)), (a, b, dimension, False))
    return sorted(planned.values(), key=lambda p: (p[2], p[0].run_id, p[1].run_id))


def run_section(run: Run) -> dict[str, Any]:
    meta = run.meta
    settings = meta.get("settings") or {}
    git = meta.get("git") or {}
    filters = meta.get("filters") or {}
    counts = meta.get("counts") or {}
    return {
        "run_id": run.run_id,
        "task": run.task,
        "backend": run.backend,
        "model_name": public_name(run.model_name),
        "model_version": public_name(run.model_version),
        "prompt_version": meta.get("prompt_version"),
        "git_sha": git.get("sha"),
        "git_dirty": git.get("dirty"),
        "crops": run.crops,
        "image_max_side": settings.get("image_max_side"),
        "max_tokens": settings.get("max_tokens"),
        "constrained_decoding": settings.get("constrained_decoding"),
        "structured_output": settings.get("structured_output"),
        "started_at": meta.get("started_at"),
        "finished_at": meta.get("finished_at"),
        "load_seconds": meta.get("load_seconds"),
        "peak_memory_gb": meta.get("peak_memory_gb"),
        "stopped": meta.get("stopped"),
        "counts": {
            key: value
            for key, value in sorted(counts.items())
            if isinstance(value, int) and not isinstance(value, bool)
        },
        "filters": {
            "only_tax_qr": filters.get("only_tax_qr"),
            "ids_file": filters.get("ids_file"),
            "limit": filters.get("limit"),
        },
        "combined_from": (
            [
                {key: _text_or_none(entry.get(key)) for key in ("run_id", "backend", "model_name")}
                for entry in run.combined_from
            ]
            if run.task == "item_categories" and "combined_from" in meta
            else None
        ),
    }


def _text_or_none(value: Any) -> Any:
    return public_name(value) if isinstance(value, str) and value else None


def run_values(runs: list[Run]) -> set[str]:
    values: set[str] = set()
    for run in runs:
        for value in (
            run.run_id,
            run.backend,
            run.model_name,
            run.model_version,
            run.meta.get("prompt_version"),
            *(
                entry.get(key)
                for entry in run.combined_from
                for key in ("run_id", "backend", "model_name")
            ),
        ):
            if isinstance(value, str) and value:
                values.add(public_name(value))
    return values


def file_stem(run_id: str) -> str:
    """A run id as a file name: anything but letters, digits, `.`, `_` and `-` becomes `_`."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", run_id)


def comparison_stem(a: str, b: str) -> str:
    """`<a>__vs__<b>`, shortened (with a digest of both ids) when it would be a long file name."""
    stem = f"{file_stem(a)}__vs__{file_stem(b)}"
    if len(stem) <= 180:
        return stem
    digest = hashlib.sha256(f"{a}\n{b}".encode()).hexdigest()[:12]
    return f"{file_stem(a)[:80]}__vs__{file_stem(b)[:80]}-{digest}"


def public_name(name: Any) -> Any:
    """A model name for the results: a local folder's path becomes `local-folder` (a path on the
    owner's machine never enters the results)."""
    if isinstance(name, str) and is_path(name):
        return "local-folder"
    return name


def check_report(
    runs: list[Run], receipts: dict[str, Any], truth: GroundTruth, out: TextIO
) -> None:
    for run in runs:
        if run.task == "ocr":
            ids = [r["receipt_id"] for r in run.records if r["status"] != "skipped"]
            known = [i for i in ids if i in receipts]
            with_qr = sum(1 for i in known if receipts[i].qr_fields)
            items = [truth.items(i, run) for i in known]
            print(
                f"{run.run_id}: ocr, {len(run.records)} lines, {len(known)} scored, "
                f"{with_qr} with QR, {sum(c.record is not None for c in items)} with item truth, "
                f"{sum(c.excluded_prefilled for c in items)} left out (pre-fill), "
                f"{len(ids) - len(known)} not in the receipt set",
                file=out,
            )
        else:
            _, _, counts = category_scoring.build_rows(run, receipts, truth)
            print(
                f"{run.run_id}: item_categories, {len(run.records)} lines, "
                f"{counts['receipts']} receipts with category truth, "
                f"{counts['receipts_excluded_prefilled']} left out (pre-fill)",
                file=out,
            )


def _share(metric: dict[str, Any]) -> str:
    return "n/a" if metric["value"] is None else f"{metric['value'] * 100:.1f}%"


def print_run(result: dict[str, Any], out: TextIO) -> None:
    run = result["run"]
    counts = result["counts"]
    if run["task"] == "ocr":
        seg = result["segments"]["all"]
        print(
            f"{run['run_id']}: {seg['receipts']} receipts; total {_share(seg['fields']['total'])}"
            f" (n={int(seg['fields']['total']['denominator'])}), date "
            f"{_share(seg['fields']['date'])}, item F1 "
            f"{_share(seg['items']['main']['f1_micro'])} (n={seg['items']['receipts']}); "
            f"left out by the pre-fill rule: {counts['excluded_prefilled_items']} "
            f"({counts['excluded_prefilled_items_unknown']} for an unknown model)",
            file=out,
        )
    else:
        head = result["headline"]
        print(
            f"{run['run_id']}: {head['items']} items; macro-F1 {_share(head['macro_f1'])}, "
            f"accuracy {_share(head['accuracy'])}; left out by the pre-fill rule: "
            f"{counts['receipts_excluded_prefilled']} receipt(s) "
            f"({counts['receipts_excluded_prefilled_unknown']} for an unknown categoriser)",
            file=out,
        )


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any] | None:
    receipts_dir = args.receipts.expanduser().resolve()
    runs_dir = args.runs.expanduser().resolve()
    truth_dir = args.ground_truth.expanduser().resolve()
    receipts = read_receipt_set(receipts_dir)
    records, truth_counts = read_ground_truth(truth_dir)
    truth = GroundTruth(records, receipts)
    runs = discover_runs(runs_dir)
    declared = [tuple(pair) for pair in args.compare]
    comparison_file = args.comparisons or runs_dir / "comparisons.txt"
    if args.comparisons is not None and not comparison_file.is_file():
        raise UsageError(f"the comparisons file {comparison_file.name} does not exist")
    if comparison_file.is_file():
        declared.extend(read_comparison_file(comparison_file))
    planned = plan_comparisons(runs, declared, automatic=not args.no_auto_compare)
    diagnostics_dir = args.diagnostics.expanduser().resolve() if args.diagnostics else None
    if diagnostics_dir is not None and inside_git_repository(diagnostics_dir):
        raise UsageError("--diagnostics is inside a git repository; it holds receipt detail")

    print(
        f"receipt set: {len(receipts)} receipts; ground truth: {len(records)} records"
        + ("" if (truth_dir / GROUND_TRUTH_FILE).is_file() else " (no ground_truth.jsonl)")
        + f"; runs: {len(runs)}; comparisons: {len(planned)}",
        file=out,
    )
    if args.check:
        check_report(runs, receipts, truth, out)

    # Score everything and check every file before anything is written.
    out_dir = args.out.expanduser().resolve()
    writer = ResultsWriter(out_dir, run_values(runs))
    writer.check_folder()
    scored: dict[str, Any] = {}
    run_results: list[dict[str, Any]] = []
    index_runs = []
    details: dict[str, Any] = {}
    for run_item in runs:
        if run_item.task == "ocr":
            scores = ocr_scoring.score_run(
                run_item, receipts, truth, seed=args.seed, resamples=args.resamples
            )
            result = {
                "results_version": RESULTS_VERSION,
                "run": run_section(run_item),
                "counts": scores.counts,
                "segments": scores.segments,
                "cost_usd": scores.cost_usd,
            }
            spec = OCR_RUN_RESULT
            details[run_item.run_id] = ocr_scoring.diagnostics(scores)
        else:
            scores = category_scoring.score_run(
                run_item, receipts, truth, seed=args.seed, resamples=args.resamples
            )
            result = {
                "results_version": RESULTS_VERSION,
                "run": run_section(run_item),
                **scores.result,
            }
            spec = CATEGORY_RUN_RESULT
            details[run_item.run_id] = category_scoring.diagnostics(scores)
        scored[run_item.run_id] = scores
        relative = f"runs/{file_stem(run_item.run_id)}.json"
        run_results.append(json.loads(writer.write_json(relative, result, spec)))
        section = result["run"]
        index_runs.append(
            {
                "run_id": run_item.run_id,
                "task": run_item.task,
                "backend": section["backend"],
                "model_name": section["model_name"],
                "model_version": section["model_version"],
                "prompt_version": section["prompt_version"],
                "crops": run_item.crops,
                "file": relative,
            }
        )
        print_run(run_results[-1], out)

    comparison_results: list[dict[str, Any]] = []
    index_comparisons = []
    for a, b, dimension, is_declared in planned:
        if a.task == "ocr":
            body = compare_ocr(
                scored[a.run_id], scored[b.run_id], seed=args.seed, resamples=args.resamples
            )
            spec = OCR_COMPARISON
        else:
            body = compare_categories(
                scored[a.run_id], scored[b.run_id], seed=args.seed, resamples=args.resamples
            )
            spec = CATEGORY_COMPARISON
        if body is None:
            print(f"compare ({dimension}): {a.run_id} - {b.run_id}: nothing in common", file=out)
            continue
        comparison = {
            "results_version": RESULTS_VERSION,
            "a": a.run_id,
            "b": b.run_id,
            "task": a.task,
            "dimension": dimension,
            "declared": is_declared,
            **body,
        }
        relative = f"comparisons/{comparison_stem(a.run_id, b.run_id)}.json"
        comparison_results.append(json.loads(writer.write_json(relative, comparison, spec)))
        index_comparisons.append(
            {
                "a": a.run_id,
                "b": b.run_id,
                "task": a.task,
                "dimension": dimension,
                "declared": is_declared,
                "file": relative,
            }
        )
        print(
            f"compare ({dimension}): {a.run_id} - {b.run_id}: "
            f"{body.get('receipts', 0)} receipts in common",
            file=out,
        )

    index = {
        "results_version": RESULTS_VERSION,
        "inputs": {
            "receipt_set_receipts": len(receipts),
            "receipt_set_with_qr": sum(1 for info in receipts.values() if info.qr_fields),
            "receipt_set_sha256": file_sha256(receipts_dir / "receipts.jsonl"),
            "ground_truth_sha256": file_sha256(truth_dir / GROUND_TRUTH_FILE),
            "ground_truth": {**truth_counts, **truth.summary()},
            "seed": args.seed,
            "resamples": args.resamples,
            "matching": {
                "name_weight": NAME_WEIGHT,
                "amount_weight": AMOUNT_WEIGHT,
                "name_threshold": NAME_THRESHOLD,
                "match_threshold": MATCH_THRESHOLD,
            },
        },
        "runs": index_runs,
        "comparisons": index_comparisons,
    }
    writer.write_json("index.json", index, INDEX)
    table_names = tables.write_tables(writer, run_results, comparison_results)
    if args.check:
        print(
            f"check passed: {len(writer.staged)} file(s) would be written; nothing written",
            file=out,
        )
        return None

    removed = writer.commit()
    if diagnostics_dir is not None:
        ensure_private_folder(diagnostics_dir)
        for run_id, detail in details.items():
            write_private_json(diagnostics_dir / f"{file_stem(run_id)}.json", detail)
    print(
        f"wrote {len(index_runs)} run file(s), {len(index_comparisons)} comparison file(s), "
        f"{len(table_names)} table(s); removed {removed} stale file(s)",
        file=out,
    )
    return index


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        run(args)
    except UsageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except ResultsShapeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
