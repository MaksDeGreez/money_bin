"""What the selection and the final scoring commands share: inputs, checks, files, summaries."""

from __future__ import annotations

import hashlib
import os
import platform
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

import joblib
import numpy as np
import scipy
import sklearn

from categoriser.baselines import Predictions
from categoriser.dataset import Row, build_rows
from categoriser.export import Export, load_export
from categoriser.metrics import Encoded, headline
from categoriser.taxonomy import load_taxonomy

MODEL_NAME = "transaction-categoriser"
DEFAULT_OUT = Path.home() / "Documents" / "money_bin_data" / "models"
DEFAULT_SEED = 42
MIN_ROWS = 20


class TrainingError(Exception):
    """The run cannot go on (bad arguments, output folder in a repository, too little data)."""


def check_options(*, seed: int, resamples: int, min_df: int = 1) -> None:
    if resamples < 1:
        raise TrainingError("resamples must be at least 1")
    if not 0 <= seed < 2**32:
        raise TrainingError("the seed must be between 0 and 2**32 - 1")
    if min_df < 1:
        raise TrainingError("min_df must be at least 1")


def load_rows(
    export_dir: Path, taxonomy_path: Path, echo: Callable[[str], Any]
) -> tuple[Export, list[Row], dict[str, int]]:
    taxonomy = load_taxonomy(taxonomy_path)
    export = load_export(export_dir)
    rows, row_counts = build_rows(export, taxonomy)
    echo(
        f"Export: {row_counts['transactions']} transactions, "
        f"{row_counts['transfer_legs_excluded']} transfer legs excluded, "
        f"{row_counts['labelled_rows']} labelled rows"
    )
    if len(rows) < MIN_ROWS:
        raise TrainingError(f"only {len(rows)} labelled rows; at least {MIN_ROWS} are needed")
    return export, rows, row_counts


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def labels(rows: Sequence[Row]) -> list[str]:
    return [row.label for row in rows]


def macro_f1(rows: Sequence[Row], predictions: Predictions) -> float:
    encoded = Encoded(labels(rows), {"system": predictions})
    scores = headline(
        encoded.true, encoded.top1["system"], encoded.in_top3["system"], len(encoded.labels)
    )
    return scores["macro_f1"]


def segments(rows: Sequence[Row], known_payees: set[str]) -> dict[str, np.ndarray]:
    """Masks of the evaluated rows: with or without bank fields, payee known to the fit or not."""
    bank = np.array([row.has_bank_fields for row in rows], dtype=bool)
    seen = np.array([bool(row.payee) and row.payee in known_payees for row in rows], dtype=bool)
    return {
        "with_bank_fields": bank,
        "without_bank_fields": ~bank,
        "payee_seen_in_train": seen,
        "payee_unseen_or_missing": ~seen,
    }


def period(rows: Sequence[Row]) -> dict[str, Any]:
    return {
        "rows": len(rows),
        "first_date": str(rows[0].occurred_on),
        "last_date": str(rows[-1].occurred_on),
        "days": len({row.occurred_on for row in rows}),
    }


def profile(rows: Sequence[Row], known_payees: set[str]) -> dict[str, float]:
    n = len(rows)
    result = {
        "with_bank_fields": sum(row.has_bank_fields for row in rows) / n,
        "with_mcc": sum(bool(row.mcc) for row in rows) / n,
        "with_bank_description": sum(bool(row.bank_description) for row in rows) / n,
        "with_payee": sum(bool(row.payee) for row in rows) / n,
        "with_comment": sum(bool(row.comment) for row in rows) / n,
        "expenses": sum(row.amount < 0 for row in rows) / n,
    }
    if known_payees:
        result["payee_seen_in_train"] = sum(row.payee in known_payees for row in rows) / n
    return result


def rename_mcnemar(result: dict[str, Any], a: str, b: str) -> dict[str, Any]:
    renamed = dict(result)
    renamed[f"{a}_only_correct"] = renamed.pop("a_only_correct")
    renamed[f"{b}_only_correct"] = renamed.pop("b_only_correct")
    return renamed


def refuse_repository(folder: Path, what: str = "the output folder") -> None:
    """Model files, metrics and embedding caches derive from personal data: never in git."""
    resolved = folder.expanduser().resolve()
    for parent in (resolved, *resolved.parents):
        if (parent / ".git").exists():
            raise TrainingError(f"{what} is inside a git repository; choose one outside")


def write_private(path: Path, write: Callable[[Any], Any]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        write(handle)


def git_state() -> dict[str, Any]:
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


def environment() -> dict[str, Any]:
    return {
        "git": git_state(),
        "python": platform.python_version(),
        "libraries": {
            "scikit-learn": sklearn.__version__,
            "numpy": np.__version__,
            "scipy": scipy.__version__,
            "joblib": joblib.__version__,
        },
    }
