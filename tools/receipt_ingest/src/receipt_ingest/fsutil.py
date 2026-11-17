"""Private, atomic file writing and the checks that keep output away from raw photos and git."""

from __future__ import annotations

import contextlib
import os
import tempfile
from pathlib import Path

DIR_MODE = 0o700
FILE_MODE = 0o600
# Temporary files start with a dot so that a half-written file never looks like output, and with a
# fixed prefix so that a later run can find and remove what a killed run left behind.
TMP_PREFIX = ".receipt-ingest-tmp-"


class RefusedError(Exception):
    """The output folder is not a safe place to write to."""


def ensure_dir(path: Path) -> None:
    """Create `path` and any missing parents with mode 700; set 700 on `path` itself."""
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for folder in reversed(missing):
        folder.mkdir()
        # mkdir's mode is filtered by the umask, so the mode is set explicitly.
        os.chmod(folder, DIR_MODE)
    os.chmod(path, DIR_MODE)


def write_atomic(path: Path, data: bytes) -> None:
    """Write `data` to `path` so that readers see either the old file or the whole new one."""
    fd, tmp_name = tempfile.mkstemp(prefix=TMP_PREFIX, dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), FILE_MODE)
        os.replace(tmp_name, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_name)
        raise


def write_if_changed(path: Path, data: bytes) -> bool:
    """Write `data` only when the file is missing or differs, so that its mtime stays otherwise."""
    try:
        if path.read_bytes() == data:
            return False
    except FileNotFoundError:
        pass
    write_atomic(path, data)
    return True


def remove_leftover_temps(folders: list[Path]) -> int:
    removed = 0
    for folder in folders:
        if not folder.is_dir():
            continue
        for entry in folder.iterdir():
            if entry.name.startswith(TMP_PREFIX) and entry.is_file() and not entry.is_symlink():
                entry.unlink()
                removed += 1
    return removed


def _nearest_existing(path: Path) -> Path:
    current = path
    while not current.exists():
        current = current.parent
    return current


def _inside_git(path: Path) -> bool:
    # `.git` is a folder in a normal checkout and a file in a linked worktree or a submodule.
    return any((folder / ".git").exists() for folder in (path, *path.parents))


def check_output_location(raw_dir: Path, out_dir: Path) -> None:
    """Refuse an output folder that overlaps the raw folder or sits inside a git repository.

    Both paths must already be resolved (absolute, symlinks followed).
    """
    if out_dir == raw_dir:
        raise RefusedError("the output folder is the raw folder")
    if raw_dir in out_dir.parents:
        raise RefusedError("the output folder is inside the raw folder")
    if out_dir in raw_dir.parents:
        raise RefusedError("the output folder contains the raw folder")
    if _inside_git(_nearest_existing(out_dir)):
        raise RefusedError("the output folder is inside a git repository")
