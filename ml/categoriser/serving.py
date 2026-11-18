"""Fit the selected configuration for serving, and load and run what that fit wrote.

    uv run python -m categoriser.serving EXPORT_DIR --selection FILE [--out DIR]

The evaluation is finished before this step: `categoriser.selection` chose a configuration on
the validation slice and `categoriser.score` scored it once on the sealed test period. This command
fits that same configuration (every tuned value kept as a number, nothing tuned again) on **every
labelled row of the export**, the test period's included, and writes one artefact for the ML
service. That is the usual practice after an evaluation: the newest rows are the most like
tomorrow's, and leaving them out of the served model would throw away the most relevant history. It
follows that the served fit has no test score of its own: the evaluated numbers belong to the fit
on the training period, and the artefact's metadata says so. Nothing here computes a metric, makes
a choice from the test labels, or appends to the record of test scores; the rows are read once, to
fit.

The command refuses what it cannot vouch for, in the spirit of `categoriser.score`:

- a selection file of another format, or one whose recorded rule does not pick its chosen
  configuration;
- an export other than the one the selection used (its manifest hash), a taxonomy other than the
  selection's, or rows that no longer split into the selection's fitting and validation periods;
- a selection whose test set was never scored (no entry of it in the record of test scores): the
  served model must have an evaluated twin;
- code that may fit differently: a file of `ml/categoriser/` that existed at the selection's commit
  and differs from it now (committed or not), an unknown commit, or other library versions
  (`--code-change-reason` overrides this one check and the reason is recorded);
- an encoder other than the selection's.

The artefact is a joblib file (mode 600, outside any git repository): the fitted pipeline, the
payee and MCC tables of the hybrid, the configuration, the class labels with their group and
category names, and the metadata, which is also written next to it as JSON (category names and
numbers only). It holds the vocabulary of the training texts and the payee tables, so it is
personal data, like the model files of the evaluation.

`ServingModel` loads an artefact and scores new transactions with the training code's own feature
builders and hybrid (`categoriser.systems.System`), so the served probabilities are the ones the
training path computes for the same rows (`tests/test_categoriser_serving.py` checks it).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import joblib
import numpy as np

from categoriser.common import (
    DEFAULT_LEDGER,
    DEFAULT_OUT,
    MODEL_NAME,
    TrainingError,
    environment,
    git_state,
    load_rows,
    period,
    refuse_repository,
    sha256_file,
    write_private,
)
from categoriser.dataset import Row, label_for, normalize_payee
from categoriser.embeddings import (
    DEFAULT_CACHE,
    ENCODERS,
    EmbeddingError,
    Encoder,
)
from categoriser.export import ExportError
from categoriser.features import FEATURE_VERSION
from categoriser.hybrid import SWITCH_WEIGHT, HybridParams, RuleTables
from categoriser.score import _config, _read_selection
from categoriser.selection import choose, optional_versions, real_encoders
from categoriser.split import SplitError, time_split
from categoriser.systems import Config, System, fit_system
from categoriser.taxonomy import DEFAULT_TAXONOMY, TaxonomyError, load_taxonomy

ARTEFACT_KIND = "transaction-categoriser-serving"
ARTEFACT_FORMAT = 1
ARTEFACT_SUFFIX = ".serving.joblib"
TOP_K = 3
FITTED_ON = (
    "every labelled row of the export: the training period, the validation slice and the test "
    "period. The configuration and every tuned value are the selection's, kept as numbers."
)
EVALUATION_NOTE = (
    "This fit has no test score of its own. The evaluated numbers (categoriser.score) belong to "
    "the same configuration fitted on the training period only; this refit adds the test period's "
    "rows, so it is expected to do at least as well on new transactions, but that is not measured."
)
SELF_TRAINING_NOTE = (
    "The ledger this model learns from will hold categories that came from its own suggestions. "
    "transaction_lines.category_origin records which lines took a suggestion (one by one or in "
    "bulk) and at what probability; a refit should leave those out, or count them apart."
)
# The source files whose behaviour the fit depends on: a change in any of them may change the fit.
SOURCE_FOLDER = "ml/categoriser"
LIBRARIES = ("scikit-learn", "numpy", "scipy", "joblib")
ENCODER_LIBRARIES = ("torch", "transformers")


class ServingError(Exception):
    """An artefact cannot be served (missing, unreadable, of another format or library version)."""


# --- Fitting the artefact ------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        selection_path = Path(args.selection).expanduser()
        chosen = _config(_read_selection(selection_path), "chosen")
        result = run(
            export_dir=Path(args.export_dir).expanduser(),
            selection_path=selection_path,
            out_dir=Path(args.out).expanduser(),
            taxonomy_path=Path(args.taxonomy).expanduser(),
            encoders=real_encoders(
                [chosen.encoder] if chosen.encoder else [],
                Path(args.embedding_cache).expanduser(),
            ),
            code_change_reason=args.code_change_reason,
            echo=print,
        )
    except (ExportError, SplitError, TaxonomyError, TrainingError, EmbeddingError) as error:
        print(f"The fit for serving stopped: {error}", file=sys.stderr)
        return 1
    print(f"Artefact: {result['artefact_path']}")
    print(f"Metadata: {result['metadata_path']}")
    print(f"Version:  {result['metadata']['model_version']}")
    return 0


def run(
    *,
    export_dir: Path,
    selection_path: Path,
    out_dir: Path,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
    encoders: Mapping[str, Encoder] | None = None,
    code_change_reason: str | None = None,
    ledger_path: Path | None = None,
    echo: Callable[[str], Any] = print,
) -> dict[str, Any]:
    """Fit the selection's chosen configuration on every labelled row; write the artefact.

    `ledger_path` is for the tests only; the command always reads `DEFAULT_LEDGER`."""
    ledger_path = DEFAULT_LEDGER if ledger_path is None else ledger_path
    encoders = dict(encoders or {})
    selection = _read_selection(selection_path)
    selection_sha = sha256_file(selection_path)
    reproducibility = selection["reproducibility"]
    parameters = reproducibility["parameters"]
    seed = reproducibility["seed"]
    refuse_repository(out_dir)

    chosen = _config(selection, "chosen")
    rechosen, _trace = choose(selection["candidates"])
    if rechosen["name"] != selection["chosen"]["name"] or (
        rechosen["config"] != selection["chosen"]["config"]
    ):
        raise TrainingError("the chosen configuration is not the one the selection rule picks")
    if sha256_file(taxonomy_path) != reproducibility["taxonomy_sha256"]:
        raise TrainingError("the taxonomy is not the one the selection used")
    scoring = _scoring_of(ledger_path, selection_sha)
    if scoring is None:
        raise TrainingError(
            "the record of test scores holds no score of this selection: score it once with "
            "categoriser.score before fitting it for serving"
        )
    code = _check_code(reproducibility, chosen, code_change_reason)
    encoder_key = None
    if chosen.encoder is not None:
        encoder = encoders.get(chosen.encoder)
        encoder_key = encoder.key if encoder else None
        if encoder_key is None or encoder_key != reproducibility["encoders"].get(chosen.encoder):
            raise TrainingError(f"the encoder {chosen.encoder!r} is not the one the selection used")

    export, rows, row_counts = load_rows(export_dir, taxonomy_path, echo)
    if export.manifest_sha256 != selection["export"]["manifest_sha256"]:
        raise TrainingError("the export is not the one the selection used")
    # The rows must still cut into the selection's periods; the test rows stay behind their seal
    # here (only their number and first day are compared), and are fitted on below as plain rows.
    split = time_split(rows, parameters["test_fraction"], parameters["validation_fraction"])
    if (
        period(split.fit) != selection["split"]["fit"]
        or period(split.validation) != selection["split"]["validation"]
        or split.test.size != selection["split"]["test"]["rows"]
        or str(split.test.cut) != selection["split"]["test"]["first_date"]
    ):
        raise TrainingError("the rows do not split as the selection's did")

    ordered = sorted(rows, key=lambda row: (row.occurred_on, row.legacy_id))
    echo(f"Fitting {chosen.name} for serving on all {len(ordered)} labelled rows")
    described = {
        "rows": {
            "fitted": len(ordered),
            "first_date": str(ordered[0].occurred_on),
            "last_date": str(ordered[-1].occurred_on),
            "export_counts": row_counts,
        },
        "export": selection["export"],
        "selection": {
            "file": selection_path.name,
            "sha256": selection_sha,
            "created_at": selection["created_at"],
            "split": selection["split"],
        },
        "evaluation": {
            "scored_at": scoring.get("unsealed_at"),
            "scored_configuration": scoring.get("configuration"),
            "note": EVALUATION_NOTE,
        },
        "taxonomy_sha256": reproducibility["taxonomy_sha256"],
        "code": code,
    }
    result = fit_artefact(
        chosen,
        ordered,
        seed=seed,
        encoders=encoders,
        taxonomy_path=taxonomy_path,
        out_dir=out_dir,
        stem_suffix=export.manifest_sha256[:12],
        described=described,
    )
    echo(
        f"{len(result['metadata']['classes'])} categories; fitted in "
        f"{result['metadata']['fit_seconds']:.1f} s"
    )
    return result


def fit_artefact(
    config: Config,
    rows: Sequence[Row],
    *,
    seed: int,
    encoders: Mapping[str, Encoder],
    taxonomy_path: Path,
    out_dir: Path,
    stem_suffix: str,
    described: Mapping[str, Any],
) -> dict[str, Any]:
    """Fit `config` on `rows` with the training code (`fit_system`) and write the artefact and its
    metadata (`described` adds what `run` checked: the export, the selection, the code)."""
    refuse_repository(out_dir)
    started = datetime.now(UTC)
    system = fit_system(config, rows, seed=seed, encoders=encoders)
    fitted_at = datetime.now(UTC)
    taxonomy = load_taxonomy(taxonomy_path)
    names = {label_for(group, category): [group, category] for group, category in taxonomy}
    if any(label not in names for label in system.classes):
        raise TrainingError("a fitted class is not in the taxonomy")
    encoder = encoders.get(config.encoder) if config.encoder else None
    metadata: dict[str, Any] = {
        "kind": ARTEFACT_KIND,
        "format_version": ARTEFACT_FORMAT,
        "model_name": MODEL_NAME,
        "feature_version": FEATURE_VERSION,
        "configuration": {"name": config.name, "config": config.as_dict()},
        "encoder": None if encoder is None else {"name": config.encoder, "key": encoder.key},
        "fitted_at": fitted_at.isoformat(timespec="seconds"),
        "fit_seconds": round((fitted_at - started).total_seconds(), 3),
        "fitted_on": FITTED_ON,
        "self_training": SELF_TRAINING_NOTE,
        "seed": seed,
        **described,
        "classes": [{"label": label, "names": names[label]} for label in system.classes],
    }
    metadata.setdefault(
        "code",
        {"at_fit": git_state(), "libraries": dict(environment()["libraries"])},
    )
    artefact = {
        "kind": ARTEFACT_KIND,
        "format_version": ARTEFACT_FORMAT,
        "config": config.as_dict(),
        "pipeline": system.pipeline,
        "rule_tables": system.tables if config.hybrid is not None else None,
        "metadata": metadata,
    }
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = f"{MODEL_NAME}-{fitted_at:%Y%m%dT%H%M%SZ}-{stem_suffix}"
    artefact_path = out_dir / f"{stem}{ARTEFACT_SUFFIX}"
    write_private(artefact_path, lambda handle: joblib.dump(artefact, handle, compress=3))
    version = model_version(artefact_path, metadata)
    metadata_path = out_dir / f"{stem}.serving.json"
    public = {**metadata, "artefact_file": artefact_path.name, "model_version": version}
    write_private(
        metadata_path,
        lambda handle: handle.write((json.dumps(public, indent=2) + "\n").encode()),
    )
    return {"artefact_path": artefact_path, "metadata_path": metadata_path, "metadata": public}


def model_version(path: Path, metadata: Mapping[str, Any]) -> str:
    """What names one artefact: its fit date and the first 12 hex digits of the file's SHA-256."""
    return f"{str(metadata['fitted_at'])[:10]}-{sha256_file(path)[:12]}"


def _scoring_of(ledger_path: Path, selection_sha: str) -> dict[str, Any] | None:
    """The record of test scores' entry for this selection, or None."""
    if not ledger_path.exists():
        return None
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("selection_sha256") == selection_sha:
            return entry
    return None


def categoriser_changes(sha: str) -> list[str] | None:
    """The files of `ml/categoriser/` that existed at `sha` and differ now (committed or not), or
    None when the commit is unknown. Files added since cannot change what the old ones fit."""
    here = Path(__file__).resolve().parent
    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=here,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        commit = f"{sha}^{{commit}}"
        subprocess.run(["git", "cat-file", "-e", commit], cwd=root, capture_output=True, check=True)
        changed = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=MDRT", sha, "--", SOURCE_FOLDER],
            cwd=root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [line for line in changed.splitlines() if line.strip()]


def _check_code(
    reproducibility: Mapping[str, Any], chosen: Config, reason: str | None
) -> dict[str, Any]:
    selected = reproducibility["git"]
    names = LIBRARIES + (ENCODER_LIBRARIES if chosen.encoder else ())
    now = {**environment()["libraries"], **optional_versions(ENCODER_LIBRARIES)}
    then = {**reproducibility["libraries"], **(reproducibility.get("embedding_libraries") or {})}
    changes = categoriser_changes(selected["sha"]) if selected.get("sha") else None
    problems = []
    if selected.get("dirty") is not False:
        problems.append("the selection ran on a modified tree")
    if changes is None:
        problems.append("the selection's commit is unknown here")
    elif changes:
        problems.append(f"{len(changes)} file(s) of {SOURCE_FOLDER} differ from the selection's")
    if any(now.get(name) != then.get(name) for name in names):
        problems.append("library versions differ from the selection's")
    if problems and not (reason and reason.strip()):
        raise TrainingError(
            "the code may fit differently from the selection's ("
            + "; ".join(problems)
            + "); pass --code-change-reason to fit anyway, and the reason is recorded"
        )
    return {
        "at_fit": git_state(),
        "at_selection": selected,
        "libraries": {name: now.get(name) for name in names},
        "code_change_reason": reason if problems else None,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m categoriser.serving",
        description="Fit the selected configuration on every labelled row for the ML service.",
    )
    parser.add_argument("export_dir", help="the export folder the selection used")
    parser.add_argument("--selection", required=True, help="the selection JSON")
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="where the artefact goes; outside any git repository (default: %(default)s)",
    )
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
        "--code-change-reason",
        default=None,
        help="fit although the code differs from the selection's, recording why",
    )
    return parser


# --- Serving it ----------------------------------------------------------------------------------


@dataclass(frozen=True)
class TransactionInput:
    """One transaction to score, as the app sends it. Holds personal data: never log it.

    `amount` is the signed amount in the account's currency (an expense is negative), or None.
    """

    payee: str | None = None
    comment: str | None = None
    bank_description: str | None = None
    merchant: str | None = None
    mcc: str | None = None
    amount: Decimal | None = None
    currency: str | None = None
    account_kind: str | None = None


@dataclass(frozen=True)
class Scored:
    """The best categories of one transaction, best first, and where the answer came from.

    `labels` are the model's class labels ("Group / Category"), `probabilities` their share of the
    combined distribution. `source` is `model` (no payee or MCC history weighed in), `history` (the
    payee's history decided: the `switch` hybrid) or `mix` (both); `history` names whose history
    (`payee` or `mcc`) and `history_weight` its weight in the mix (0 for the model alone).
    """

    labels: list[str]
    probabilities: list[float]
    source: str
    history: str | None
    history_weight: float


# A missing amount is scored as a small expense in no currency: the sign field says "out" (a
# suggestion is nearly always asked for spending) and the size bucket gets a value never seen in
# training, so it adds nothing.
_NO_AMOUNT = Decimal("-0.01")


def row_of(transaction: TransactionInput) -> Row:
    """The categoriser's row for one transaction, built as `categoriser.dataset.build_rows` builds
    it from an export (the payee normalised, every text squished)."""
    missing_amount = transaction.amount is None
    return Row(
        occurred_on=date.min,  # not a feature; the recency weights are fitted already
        legacy_id="",
        label="",
        payee=normalize_payee(transaction.payee),
        comment=_squish(transaction.comment),
        bank_description=_squish(transaction.bank_description),
        merchant=_squish(transaction.merchant),
        mcc=_squish(transaction.mcc),
        amount=_NO_AMOUNT if missing_amount else Decimal(transaction.amount),
        currency="" if missing_amount else _squish(transaction.currency),
        account_kind=_squish(transaction.account_kind),
    )


def _squish(value: str | None) -> str:
    return " ".join(value.split()) if isinstance(value, str) else ""


def history_weights(
    rows: Sequence[Row], tables: RuleTables, params: HybridParams
) -> list[tuple[str | None, float]]:
    """Per row: whose history the hybrid weighs in (`payee`, `mcc` or None) and its weight `w`.

    The same rule as `categoriser.hybrid.combine`, which returns only the combined distribution;
    `tests/test_categoriser_serving.py` checks that the two agree."""
    result: list[tuple[str | None, float]] = []
    for row in rows:
        if row.payee and row.payee in tables.payees:
            counter = tables.payees[row.payee]
            n = sum(counter.values())
            purity = max(counter.values()) / n
            if params.mode == "mix":
                result.append(("payee", n / (n + params.k) * purity**params.beta))
            elif n >= params.min_count and purity >= params.min_purity:
                result.append(("payee", SWITCH_WEIGHT))
            else:
                result.append((None, 0.0))
        elif params.mode == "mix" and params.alpha_mcc > 0 and row.mcc in tables.mccs:
            counter = tables.mccs[row.mcc]
            n = sum(counter.values())
            purity = max(counter.values()) / n
            weight = params.alpha_mcc * n / (n + params.k) * purity**params.beta
            result.append(("mcc", weight))
        else:
            result.append((None, 0.0))
    return result


class ServingModel:
    """A loaded artefact. `encoder_factory` builds the sentence encoder the first time one is needed
    (the real one loads its weights from the local Hugging Face cache only)."""

    def __init__(
        self,
        artefact: Mapping[str, Any],
        version: str,
        encoder_factory: Callable[[str], Encoder] | None = None,
    ) -> None:
        self.metadata: dict[str, Any] = dict(artefact["metadata"])
        self.version = version
        self.config = Config.from_dict(artefact["config"])
        self._pipeline = artefact["pipeline"]
        self._tables = artefact["rule_tables"] or RuleTables().fit([])
        self._encoder_factory = encoder_factory
        self._system: System | None = None
        self.labels: list[str] = [str(label) for label in self._pipeline.classes_]
        self.names: dict[str, tuple[str, str]] = {
            entry["label"]: (entry["names"][0], entry["names"][1])
            for entry in self.metadata["classes"]
        }
        if sorted(self.names) != sorted(self.labels):
            raise ServingError("the artefact's class list does not match its model")

    @property
    def model_name(self) -> str:
        return str(self.metadata["model_name"])

    @property
    def fitted_at(self) -> str:
        return str(self.metadata["fitted_at"])

    @property
    def encoder_name(self) -> str | None:
        return self.config.encoder

    def prepare(self) -> None:
        """Build the encoder (and load its weights) now rather than on the first request."""
        self._get_system()
        encoder = self._system.encoder if self._system else None
        prepare = getattr(encoder, "prepare", None)
        if prepare is not None:
            prepare()

    def _get_system(self) -> System:
        if self._system is None:
            encoder = None
            if self.config.encoder is not None:
                if self._encoder_factory is None:
                    raise ServingError("the artefact needs a sentence encoder and none is set up")
                encoder = self._encoder_factory(self.config.encoder)
                expected = (self.metadata.get("encoder") or {}).get("key")
                if encoder.key != expected:
                    raise ServingError("the sentence encoder differs from the artefact's")
            self._system = System(self.config, self._pipeline, self._tables, encoder)
        return self._system

    def probabilities(self, rows: Sequence[Row]) -> np.ndarray:
        """The served distribution over `labels`: the training code's `System.probabilities`."""
        return self._get_system().probabilities(rows)

    def score(self, transactions: Sequence[TransactionInput]) -> list[Scored]:
        rows = [row_of(transaction) for transaction in transactions]
        if not rows:
            return []
        p = self.probabilities(rows)
        hybrid = self.config.hybrid
        weights = (
            history_weights(rows, self._tables, hybrid)
            if hybrid is not None
            else [(None, 0.0)] * len(rows)
        )
        order = np.argsort(-p, axis=1, kind="stable")[:, :TOP_K]
        scored = []
        for i, (history, weight) in enumerate(weights):
            if weight <= 0:
                source, history = "model", None
            elif weight >= SWITCH_WEIGHT:
                source = "history"
            else:
                source = "mix"
            scored.append(
                Scored(
                    labels=[self.labels[j] for j in order[i]],
                    probabilities=[float(p[i, j]) for j in order[i]],
                    source=source,
                    history=history,
                    history_weight=float(weight),
                )
            )
        return scored


def load(path: Path, encoder_factory: Callable[[str], Encoder] | None = None) -> ServingModel:
    """Read an artefact written by `run` and check that this code can serve it.

    joblib unpickles the file, which runs code from it: load only artefacts this command wrote,
    from the private data folder."""
    if not path.is_file():
        raise ServingError(f"the artefact {path.name} does not exist")
    try:
        artefact = joblib.load(path)
    except Exception:
        raise ServingError(f"the artefact {path.name} cannot be read") from None
    if not isinstance(artefact, dict) or artefact.get("kind") != ARTEFACT_KIND:
        raise ServingError(f"{path.name} is not a serving artefact of the transaction categoriser")
    if artefact.get("format_version") != ARTEFACT_FORMAT:
        raise ServingError(f"{path.name} has another artefact format; fit it again")
    metadata = artefact.get("metadata") or {}
    if metadata.get("feature_version") != FEATURE_VERSION:
        raise ServingError(f"{path.name} was fitted with other features; fit it again")
    fitted_with = (metadata.get("code") or {}).get("libraries") or {}
    now = environment()["libraries"]
    if fitted_with.get("scikit-learn") != now["scikit-learn"]:
        raise ServingError(
            f"{path.name} was fitted with scikit-learn {fitted_with.get('scikit-learn')}, this "
            f"service runs {now['scikit-learn']}; fit it again"
        )
    return ServingModel(artefact, model_version(path, metadata), encoder_factory)


def real_encoder(name: str) -> Encoder:  # pragma: no cover - needs torch and local weights
    """The named local encoder, uncached. Its weights come from the local Hugging Face cache only
    (`local_files_only`, `HF_HUB_OFFLINE`): nothing is downloaded, no text leaves the machine."""
    from categoriser.embeddings import TransformerEncoder

    if name not in ENCODERS:
        raise ServingError(f"the encoder {name!r} is unknown")
    return TransformerEncoder(ENCODERS[name])


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
