"""Private, atomic file writing and the checks that keep output away from raw photos and git."""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
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


def _fsync_folder(folder: Path) -> None:
    # The rename is durable only once the folder entry itself reaches the disk.
    fd = os.open(folder, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


# Called with the bytes read back from disk; raises when they must not be used.
Check = Callable[[bytes], None]


@dataclass
class Staged:
    """A file ready to take its place: written to a temporary file, synced and checked."""

    path: Path
    temp: str | None  # None when the file already holds these bytes
    data: bytes  # the bytes read back from disk


def stage(path: Path, data: bytes, check: Check | None = None) -> Staged:
    """Write `data` next to `path` under a temporary name; `path` itself is not touched yet.

    The temporary file is read back after the sync and those bytes go to `check`, so that bytes
    which fail the check never replace a good file. On any failure the temporary file is removed.
    A file that already holds `data` is not written again, so that its mtime stays.
    """
    try:
        existing = path.read_bytes()
    except FileNotFoundError:
        existing = None
    if existing == data:
        if check is not None:
            check(existing)
        return Staged(path, None, existing)
    tmp_name = _write_temp(path, data)
    try:
        with open(tmp_name, "rb") as handle:
            on_disk = handle.read()
        if check is not None:
            check(on_disk)
    except BaseException:
        discard(Staged(path, tmp_name, b""))
        raise
    return Staged(path, tmp_name, on_disk)


def _write_temp(path: Path, data: bytes) -> str:
    fd, tmp_name = tempfile.mkstemp(prefix=TMP_PREFIX, dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), FILE_MODE)
    except BaseException:
        discard(Staged(path, tmp_name, b""))
        raise
    return tmp_name


def commit(staged: Staged) -> bool:
    """Rename a staged file into place; True when a file was written."""
    if staged.temp is None:
        return False
    try:
        os.replace(staged.temp, staged.path)
    except BaseException:
        discard(staged)
        raise
    _fsync_folder(staged.path.parent)
    return True


def discard(staged: Staged) -> None:
    if staged.temp is not None:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(staged.temp)


def write_atomic(path: Path, data: bytes) -> None:
    """Write `data` to `path` so that readers see either the old file or the whole new one."""
    commit(Staged(path, _write_temp(path, data), data))


def write_if_changed(path: Path, data: bytes, check: Check | None = None) -> bool:
    """Write `data` only when the file is missing or differs, so that its mtime stays otherwise.

    With `check`, the new bytes are checked as read back from the temporary file, before they
    replace anything: a failed check leaves the existing file as it was.
    """
    return commit(stage(path, data, check))


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


def _real_ancestors(path: Path) -> list[Path]:
    """`path` and every folder above it, following symlinks first so that `..` cannot mislead."""
    return [path, *path.resolve().parents]


def check_output_location(raw_dir: Path, out_dir: Path) -> None:
    """Refuse an output folder that overlaps the raw folder or sits inside a git repository.

    Folders are compared by file identity (device and inode), not by path text: on a disk that
    ignores letter case, or through a symlink, two different strings can name the same folder.
    """
    raw_stat = os.stat(raw_dir)
    existing = _nearest_existing(out_dir)
    out_exists = existing == out_dir
    if not existing.is_dir():
        if out_exists:
            raise RefusedError("the output path exists and is not a folder")
        raise RefusedError("a part of the output path is not a folder")
    for folder in _real_ancestors(existing):
        if os.path.samestat(os.stat(folder), raw_stat):
            if out_exists and folder == existing:
                raise RefusedError("the output folder is the raw folder")
            raise RefusedError("the output folder is inside the raw folder")
    # A folder that does not exist yet cannot contain the raw folder.
    if out_exists:
        out_stat = os.stat(out_dir)
        for folder in _real_ancestors(raw_dir)[1:]:
            if os.path.samestat(os.stat(folder), out_stat):
                raise RefusedError("the output folder contains the raw folder")
    if _inside_git(existing):
        raise RefusedError("the output folder is inside a git repository")


def check_output_folders(out_dir: Path, names: tuple[str, ...]) -> None:
    """Refuse output subfolders that are symlinks or files.

    Writing through a symlinked `images/` would put files, and the clean-up of orphans, into
    whatever folder the link points at.
    """
    for name in names:
        folder = out_dir / name
        if folder.is_symlink():
            raise RefusedError(f"{name}/ in the output folder is a symlink")
        if folder.exists() and not folder.is_dir():
            raise RefusedError(f"{name} in the output folder is not a folder")
