import subprocess
import sys

import pytest
from support import shot

from receipt_ingest import cli, pipeline


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["only_one"],
        ["a", "b", "--gap", "soon"],
        ["a", "b", "--gap", "-1"],
        ["a", "b", "--gap", "nan"],
        ["a", "b", "--gap", "inf"],
        ["a", "b", "--gap", "-inf"],
        ["a", "b", "--gap", "1e999"],
        ["a", "b", "--jobs", "0"],
        ["a", "b", "--jobs", "many"],
        ["a", "b", "--unknown"],
    ],
)
def test_usage_errors_exit_with_2(argv, capsys):
    with pytest.raises(SystemExit) as raised:
        cli.main(argv)
    assert raised.value.code == 2
    assert "usage: receipt-ingest" in capsys.readouterr().err


def test_options_reach_the_run(monkeypatch, tmp_path):
    seen = {}

    def fake_run(options, out, err):
        seen["options"] = options
        return 0

    monkeypatch.setattr(cli, "run", fake_run)
    code = cli.main(
        [
            *(str(tmp_path), str(tmp_path / "o")),
            *("--gap", "12.5", "--no-crop", "--redo-qr", "--redo-crop", "--jobs", "3"),
        ]
    )
    assert code == 0
    options = seen["options"]
    assert (options.gap, options.crop, options.redo_qr, options.redo_crop, options.jobs) == (
        12.5,
        False,
        True,
        True,
        3,
    )


def test_default_jobs_leave_cores_free(monkeypatch):
    monkeypatch.setattr(pipeline.os, "cpu_count", lambda: 12)
    assert pipeline.default_jobs() == 8
    monkeypatch.setattr(pipeline.os, "cpu_count", lambda: 2)
    assert pipeline.default_jobs() == 1
    monkeypatch.setattr(pipeline.os, "cpu_count", lambda: None)
    assert pipeline.default_jobs() == 1


def test_gap_option_changes_grouping(raw, out, run_tool):
    shot(raw, "b/IMG_0001.jpg", 0)
    shot(raw, "b/IMG_0002.jpg", 10)
    result = run_tool(raw, out, "--gap", "10")
    assert "b: 1 receipts, 2 images" in result.out


def test_module_entry_point(tmp_path):
    completed = subprocess.run(
        [sys.executable, "-m", "receipt_ingest", "--version"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0
    assert completed.stdout.startswith("receipt-ingest ")
