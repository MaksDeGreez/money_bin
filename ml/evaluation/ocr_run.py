"""Run an OCR backend over a receipt set and write the answers to a run folder.

    uv run python -m evaluation.ocr_run --ingest ~/Documents/money_bin_data/receipts \\
        --out ~/Documents/money_bin_data/runs --backend mlx \\
        --model mlx-community/Qwen2.5-VL-7B-Instruct-4bit --only-tax-qr --limit 20

The backend runs in this process, exactly as the service runs it (same prompt,
post-processing and settings). The run folder `OUT/<run id>/` gets:

- `predictions.jsonl`: one line per receipt, written as soon as it is done:
  `receipt_id`, `status` (`ok`, `parse_failed`, `error`, `skipped`),
  `seconds`, `repaired`, `images` (`full` or `crop` per part), the
  `receipt` as the API returns it (or null), `error` (a code) and
  `diagnostics` (token counts, peak memory, post-processing counts);
- `run.json`: the backend, model, weights revision, prompt version, git commit,
  settings, filters, counts and timings; for a hosted backend also the cost
  (a sum of what OpenRouter reported, per receipt and per 1,000 receipts),
  the upstream providers that served the calls and the zero-retention
  endpoints the requests were limited to.

A hosted run (`--backend openrouter`) reads `OPENROUTER_API_KEY` and
`OPENROUTER_OCR_MODEL` from the environment like the service; the key is never
written to the run folder or printed.

The output folder must be outside any git repository: answers hold receipt
content. The console shows counts only.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from collections import Counter
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TextIO

from pydantic import ValidationError

from app.backends import BACKENDS, Backend, BackendError, ImageInput, create_backend
from app.backends.openrouter import OpenRouterBackend, missing_settings
from app.config import Settings
from app.main import MAX_IMAGES
from app.ocr.images import ImageDecodeError
from app.ocr.parsing import OcrParseError
from app.ocr.prompt import PROMPT_VERSION
from evaluation.common import (
    FILE_MODE,
    UsageError,
    cost_summary,
    ensure_private_folder,
    inside_git_repository,
    read_receipt_set,
    timing_summary,
    write_private_json,
)

ML_ROOT = Path(__file__).resolve().parent.parent


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m evaluation.ocr_run",
        description="Run an OCR backend over a receipt set and write a run folder.",
    )
    parser.add_argument("--ingest", required=True, type=Path, help="the receipt set folder")
    parser.add_argument("--out", required=True, type=Path, help="the folder for run folders")
    parser.add_argument("--backend", default="mlx", choices=sorted(BACKENDS))
    parser.add_argument(
        "--model", help="the model id (default: MLX_OCR_MODEL, or OPENROUTER_OCR_MODEL)"
    )
    parser.add_argument(
        "--image-max-side",
        type=int,
        help="override MLX_OCR_IMAGE_MAX_SIDE (or OPENROUTER_OCR_IMAGE_MAX_SIDE)",
    )
    parser.add_argument(
        "--max-tokens", type=int, help="override MLX_OCR_MAX_TOKENS (or OPENROUTER_MAX_TOKENS)"
    )
    parser.add_argument(
        "--only-tax-qr",
        action="store_true",
        help="only receipts whose QR code is a tax-service link (they have ground truth)",
    )
    parser.add_argument("--ids", type=Path, help="a file with one receipt id per line")
    parser.add_argument("--limit", type=int, help="at most this many receipts")
    parser.add_argument(
        "--crops", action="store_true", help="send the cropped photos where there are crops"
    )
    args = parser.parse_args(argv)
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be 1 or more")
    return args


# The settings that `--model`, `--image-max-side` and `--max-tokens` override, per backend.
SETTING_FIELDS: dict[str, dict[str, str]] = {
    "mlx": {
        "model": "mlx_ocr_model",
        "image_max_side": "mlx_ocr_image_max_side",
        "max_tokens": "mlx_ocr_max_tokens",
    },
    "openrouter": {
        "model": "openrouter_ocr_model",
        "image_max_side": "openrouter_ocr_image_max_side",
        "max_tokens": "openrouter_max_tokens",
    },
}


def backend_settings(backend: Backend, settings: Settings) -> dict[str, Any]:
    """The settings a run used, for `run.json`. Never the API key."""
    if isinstance(backend, OpenRouterBackend):
        catalogue = backend.catalogue
        return {
            "image_max_side": settings.openrouter_ocr_image_max_side,
            "max_tokens": settings.openrouter_max_tokens,
            "timeout_seconds": settings.openrouter_timeout,
            "structured_output": bool(catalogue and catalogue.structured_endpoints),
            "zdr_endpoints": list(catalogue.endpoints) if catalogue else [],
            "structured_endpoints": list(catalogue.structured_endpoints) if catalogue else [],
        }
    return {
        "image_max_side": settings.mlx_ocr_image_max_side,
        "max_tokens": settings.mlx_ocr_max_tokens,
        "constrained_decoding": settings.mlx_ocr_constrained_decoding,
    }


def read_ids(path: Path) -> list[str]:
    """Receipt ids, one per line; blank lines and `#` comments are ignored."""
    if not path.is_file():
        raise UsageError(f"--ids file not found: {path}")
    ids = []
    for line in path.read_text(encoding="utf-8").splitlines():
        text = line.split("#", 1)[0].strip()
        if text:
            ids.append(text)
    return ids


def select_receipts(
    lines: list[dict[str, Any]],
    *,
    only_tax_qr: bool,
    ids: list[str] | None,
    limit: int | None,
) -> list[dict[str, Any]]:
    """The receipts to run, in the order of the set (or of `ids`)."""
    if ids is not None:
        by_id = {line["receipt_id"]: line for line in lines}
        unknown = [receipt_id for receipt_id in ids if receipt_id not in by_id]
        if unknown:
            raise UsageError(f"{len(unknown)} id(s) from --ids are not in the receipt set")
        selected = [by_id[receipt_id] for receipt_id in dict.fromkeys(ids)]
    else:
        selected = list(lines)
    if only_tax_qr:
        selected = [line for line in selected if line.get("qr_fields")]
    return selected[:limit] if limit is not None else selected


def image_files(line: dict[str, Any], *, crops: bool) -> list[tuple[str, str]]:
    """(relative file, "full" or "crop") per part, in part order."""
    crop_by_part = {crop["part"]: crop["file"] for crop in line.get("crop") or []}
    files = []
    for part, image in enumerate(line.get("images") or [], start=1):
        if crops and part in crop_by_part:
            files.append((crop_by_part[part], "crop"))
        else:
            files.append((image["file"], "full"))
    return files


def load_images(ingest: Path, files: list[tuple[str, str]]) -> list[ImageInput]:
    return [
        ImageInput(content=(ingest / file).read_bytes(), content_type="image/jpeg", filename=file)
        for file, _ in files
    ]


def git_commit() -> dict[str, Any]:
    """The commit of this code and whether the working tree had changes."""
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ML_ROOT, capture_output=True, text=True, check=True
        ).stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain", "--", "."],
            cwd=ML_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return {"sha": None, "dirty": None}
    return {"sha": sha, "dirty": bool(status.strip())}


def run_id_for(backend: str, model: str, now: datetime) -> str:
    slug = model.rstrip("/").rsplit("/", 1)[-1].lower().replace(" ", "-") or "model"
    return f"{now.strftime('%Y%m%dT%H%M%SZ')}-{backend}-{slug}"


def run_one(backend: Backend, ingest: Path, line: dict[str, Any], *, crops: bool) -> dict[str, Any]:
    """Read one receipt and return its predictions line."""
    files = image_files(line, crops=crops)
    record: dict[str, Any] = {
        "receipt_id": line["receipt_id"],
        "status": "ok",
        "seconds": None,
        "repaired": False,
        "images": [kind for _, kind in files],
        "receipt": None,
        "error": None,
        "diagnostics": {},
    }
    if not 1 <= len(files) <= MAX_IMAGES:
        record.update(status="skipped", error="image_count")
        return record
    started = time.perf_counter()
    try:
        extraction = backend.extract_receipt(load_images(ingest, files))
    except OcrParseError as error:
        record.update(status="parse_failed", error="ocr_parse_failed")
        record["diagnostics"] = dict(error.diagnostics)
    except ImageDecodeError:
        record.update(status="error", error="image_unreadable")
    except BackendError as error:
        # The calls made before the failure were paid for: keep their accounting.
        record.update(status="error", error=error.code)
        record["diagnostics"] = dict(error.diagnostics)
    except Exception as error:  # one broken receipt must not end the run
        record.update(status="error", error=type(error).__name__)
    else:
        record.update(
            receipt=extraction.receipt.model_dump(mode="json"),
            repaired=extraction.repaired,
            diagnostics=dict(extraction.diagnostics),
        )
    record["seconds"] = round(time.perf_counter() - started, 3)
    return record


def make_run_dir(runs: Path, run_id: str) -> Path:
    """A new private run folder; a suffix keeps two runs started in the same second apart."""
    ensure_private_folder(runs)
    for attempt in range(1, 100):
        run_dir = runs / (run_id if attempt == 1 else f"{run_id}-{attempt}")
        try:
            run_dir.mkdir(mode=0o700)
        except FileExistsError:
            continue
        return run_dir
    raise UsageError("too many run folders with the same name")


def _open_private(path: Path) -> TextIO:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, FILE_MODE)
    return os.fdopen(descriptor, "w", encoding="utf-8")


def run(args: argparse.Namespace, out: TextIO = sys.stdout) -> dict[str, Any]:
    ingest = args.ingest.expanduser().resolve()
    runs = args.out.expanduser().resolve()
    if inside_git_repository(runs):
        raise UsageError("--out is inside a git repository; run folders hold receipt content")
    lines = read_receipt_set(ingest)
    ids = read_ids(args.ids) if args.ids else None
    selected = select_receipts(lines, only_tax_qr=args.only_tax_qr, ids=ids, limit=args.limit)
    if not selected:
        raise UsageError("no receipt matches the filters")

    fields = SETTING_FIELDS.get(args.backend, SETTING_FIELDS["mlx"])
    overrides: dict[str, Any] = {"ocr_backend": args.backend}
    if args.model:
        overrides[fields["model"]] = args.model
    if args.image_max_side is not None:
        overrides[fields["image_max_side"]] = args.image_max_side
    if args.max_tokens is not None:
        overrides[fields["max_tokens"]] = args.max_tokens
    try:
        settings = Settings(**overrides)
    except ValidationError as error:
        fields = ", ".join(str(detail["loc"][0]) for detail in error.errors())
        raise UsageError(f"invalid setting: {fields}") from None
    backend = create_backend(args.backend, settings)
    if isinstance(backend, OpenRouterBackend):
        missing = missing_settings(settings)
        if missing:
            raise UsageError(f"set {' and '.join(missing)} in the environment")

    started_at = datetime.now(UTC)
    statuses: Counter[str] = Counter()
    seconds: list[float] = []
    repaired = 0
    peak_memory = 0.0
    records: list[dict[str, Any]] = []
    try:
        load_started = time.perf_counter()
        try:
            backend.start()
        except BackendError as error:
            raise UsageError(error.message) from None
        if isinstance(backend, OpenRouterBackend) and backend.catalogue is None:
            raise UsageError("the list of zero-retention endpoints could not be read")
        load_seconds = round(time.perf_counter() - load_started, 3)
        print(f"model loaded in {load_seconds:.1f} s; {len(selected)} receipt(s)", file=out)
        run_dir = make_run_dir(runs, run_id_for(backend.name, backend.model_name, started_at))
        with _open_private(run_dir / "predictions.jsonl") as predictions:
            for number, line in enumerate(selected, start=1):
                record = run_one(backend, ingest, line, crops=args.crops)
                predictions.write(json.dumps(record, ensure_ascii=False) + "\n")
                predictions.flush()
                statuses[record["status"]] += 1
                if record["status"] in ("ok", "parse_failed"):
                    seconds.append(record["seconds"])
                repaired += int(record["repaired"])
                peak_memory = max(peak_memory, record["diagnostics"].get("peak_memory_gb", 0.0))
                records.append(record)
                took = "" if record["seconds"] is None else f" {record['seconds']:.1f} s"
                print(f"{number}/{len(selected)} {record['status']}{took}", file=out)
                if record["error"] == "openrouter_provider_unverified":
                    print(
                        "stopped: an answer came from a provider outside the zero-retention "
                        "list; check the account's settings before another run",
                        file=out,
                    )
                    break
        # Read before `stop()`, which forgets the endpoint list.
        used_settings = backend_settings(backend, settings)
    finally:
        backend.stop()

    summary = {
        "run_id": run_dir.name,
        "backend": backend.name,
        "model_name": backend.model_name,
        "model_version": backend.model_version,
        "prompt_version": PROMPT_VERSION if backend.name != "stub" else None,
        "git": git_commit(),
        "settings": {**used_settings, "crops": args.crops},
        "filters": {
            "only_tax_qr": args.only_tax_qr,
            "ids_file": args.ids is not None,
            "limit": args.limit,
        },
        "ingest": str(ingest),
        "started_at": started_at.isoformat(),
        "finished_at": datetime.now(UTC).isoformat(),
        "load_seconds": load_seconds,
        "counts": {"receipts": len(selected), "repaired": repaired, **statuses},
        "seconds_per_receipt": timing_summary(seconds),
        "peak_memory_gb": peak_memory,
    }
    if isinstance(backend, OpenRouterBackend):
        summary["cost_usd"] = cost_summary(records)
        summary["upstream_providers"] = dict(
            sorted(
                Counter(
                    call.get("provider") or "unknown"
                    for record in records
                    for call in record["diagnostics"].get("calls", [])
                ).items()
            )
        )
    write_private_json(run_dir / "run.json", summary)
    print_summary(summary, out)
    return summary


def print_summary(summary: dict[str, Any], out: TextIO) -> None:
    counts = summary["counts"]
    timing = summary["seconds_per_receipt"]
    print(f"run {summary['run_id']}", file=out)
    print(
        "receipts {receipts}: ok {ok}, parse_failed {parse_failed}, error {error}, "
        "skipped {skipped}, repaired {repaired}".format(
            receipts=counts["receipts"],
            ok=counts.get("ok", 0),
            parse_failed=counts.get("parse_failed", 0),
            error=counts.get("error", 0),
            skipped=counts.get("skipped", 0),
            repaired=counts["repaired"],
        ),
        file=out,
    )
    if timing["count"]:
        print(
            f"seconds per receipt: mean {timing['mean']}, median {timing['median']}, "
            f"p90 {timing['p90']}; peak memory {summary['peak_memory_gb']} GB",
            file=out,
        )
    cost = summary.get("cost_usd")
    if cost is not None:
        print(format_cost(cost), file=out)


def format_cost(cost: dict[str, Any]) -> str:
    """One console line about the cost of a hosted run."""
    line = (
        f"cost: total ${cost['total_usd']}, per receipt ${cost['per_receipt_usd']}, "
        f"per 1,000 receipts ${cost['per_1000_receipts_usd']}"
    )
    if not cost["complete"]:
        line += f" ({cost['receipts_without_cost']} receipt(s) without a reported cost)"
    return line


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
