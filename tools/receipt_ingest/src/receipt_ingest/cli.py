"""Command line: receipt-ingest RAW_DIR OUT_DIR [options]."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from receipt_ingest import __version__
from receipt_ingest.pipeline import EXIT_USAGE, Options, default_jobs, run


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        # argparse exits with 2 on a usage error, which is the exit code the tool documents.
        self.print_usage(sys.stderr)
        print(f"error: {message}", file=sys.stderr)
        sys.exit(EXIT_USAGE)


def _positive_number(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number of seconds") from None
    if value < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return value


def _jobs(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a whole number") from None
    if value < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog="receipt-ingest",
        description=(
            "Turn phone photos of paper receipts into a numbered receipt set: "
            "clean JPEGs, QR data, crops and a review page."
        ),
    )
    parser.add_argument("raw_dir", metavar="RAW_DIR", type=Path, help="folder of batch folders")
    parser.add_argument("out_dir", metavar="OUT_DIR", type=Path, help="output folder")
    parser.add_argument(
        "--gap",
        type=_positive_number,
        default=8.0,
        metavar="SECONDS",
        help="a longer pause between two photos starts a new receipt (default 8)",
    )
    parser.add_argument("--no-crop", action="store_true", help="make no new crops")
    parser.add_argument("--redo-qr", action="store_true", help="decode every receipt's QR again")
    parser.add_argument("--redo-crop", action="store_true", help="crop every receipt again")
    parser.add_argument(
        "--jobs",
        type=_jobs,
        default=default_jobs(),
        metavar="N",
        help="worker processes (default %(default)s; 1 runs everything in this process)",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    options = Options(
        raw_dir=args.raw_dir,
        out_dir=args.out_dir,
        gap=args.gap,
        crop=not args.no_crop,
        redo_qr=args.redo_qr,
        redo_crop=args.redo_crop,
        jobs=args.jobs,
    )
    return run(options, sys.stdout, sys.stderr)
