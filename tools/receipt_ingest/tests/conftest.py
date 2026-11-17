from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pytest

from receipt_ingest import cli


@dataclass
class Result:
    code: int
    out: str
    err: str


@pytest.fixture
def raw(tmp_path: Path) -> Path:
    folder = tmp_path / "raw"
    folder.mkdir()
    return folder


@pytest.fixture
def out(tmp_path: Path) -> Path:
    return tmp_path / "out"


@pytest.fixture
def run_tool(capsys):
    def run(raw: Path, out: Path, *extra: str, jobs: str = "1") -> Result:
        code = cli.main([str(raw), str(out), "--jobs", jobs, *extra])
        captured = capsys.readouterr()
        return Result(code, captured.out, captured.err)

    return run
