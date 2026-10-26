#!/usr/bin/env python3
"""Repair a curtain state directory stuck in `restore-pending`.

Symptom: `display-session.json` / `brightness.json` still list displays that are
physically gone. Every unlock submits those UUIDs, WindowServer answers
`complete returned 1001`, the snapshot is kept, and `curtain on` refuses to start
a new session.

What this does, in order:

1. copies every file it may touch to `<name>.bak-<timestamp>` and into
   `backup-<timestamp>/`; originals are never deleted or moved;
2. reads `status` from the control socket and refuses to run unless the app is
   idle (`state == open`), so a live protection session is never edited;
3. asks BetterDisplay for the displays it still knows about (their stable UUIDs)
   and CoreGraphics for the display IDs that are active right now;
4. retires only saved entries whose UUID is in neither place, writing an audit
   copy `*.retired-<reason>-<timestamp>.json` beside the file;
5. never writes to a display, never calls `curtain on`/`off`, never uses sudo,
   AppleScript, or TCC, and installs nothing.

Usage:
    python3 repair-restore-pending.py [--home DIR] [--dry-run]
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import fcntl
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import uuid
from pathlib import Path

STATE_FILES = [
    "display-session.json",
    "brightness.json",
    "window-session.json",
    "last-brightness-recovery.json",
    "last-window-recovery.json",
]


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> "NoReturn":
    print(f"refusing: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def utc_stamp(moment: dt.datetime | None = None) -> str:
    moment = moment or dt.datetime.now(dt.timezone.utc)
    return moment.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def status_via_socket(socket_path: Path) -> dict | None:
    if not socket_path.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(60)
            connection.connect(str(socket_path))
            connection.sendall(b"status\n")
            connection.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                data = connection.recv(4096)
                if not data:
                    break
                chunks.append(data)
        return json.loads(b"".join(chunks).decode().strip())
    except (OSError, ValueError) as error:
        log(f"status unavailable: {error}")
        return None


def betterdisplay_uuids() -> set[str]:
    cli = shutil.which("betterdisplaycli")
    if cli is None:
        for candidate in ("/opt/homebrew/bin/betterdisplaycli",
                          "/usr/local/bin/betterdisplaycli"):
            if os.path.exists(candidate):
                cli = candidate
                break
    if cli is None:
        fail("betterdisplaycli was not found; cannot tell which displays still exist")
    try:
        result = subprocess.run([cli, "get", "--identifiers"], capture_output=True,
                                text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        fail(f"betterdisplaycli could not be read: {error}")
    text = result.stdout.strip()
    if result.returncode != 0:
        fail(f"betterdisplaycli failed with exit {result.returncode}")
    if not text:
        fail("betterdisplaycli returned no displays; is BetterDisplay.app running?")
    if not text.startswith("["):
        text = "[" + text + "]"
    try:
        entries = json.loads(text)
    except ValueError as error:
        fail(f"betterdisplaycli returned unparsable output: {error}")
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        fail("betterdisplaycli returned an invalid display list")
    identities = {entry["UUID"] for entry in entries
                  if isinstance(entry.get("UUID"), str) and entry["UUID"] not in ("", "UNKNOWN")}
    if not identities:
        fail("betterdisplaycli returned no stable display identities")
    return identities


def active_display_ids() -> set[int]:
    try:
        framework = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    except OSError as error:
        fail(f"CoreGraphics is unavailable: {error}")
    framework.CGGetActiveDisplayList.restype = ctypes.c_int32
    framework.CGGetActiveDisplayList.argtypes = [
        ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
    count = ctypes.c_uint32(0)
    if framework.CGGetActiveDisplayList(0, None, ctypes.byref(count)) != 0:
        fail("CGGetActiveDisplayList could not count displays")
    ids = (ctypes.c_uint32 * count.value)()
    if framework.CGGetActiveDisplayList(count.value, ids, ctypes.byref(count)) != 0:
        fail("CGGetActiveDisplayList could not read displays")
    return {int(value) for value in ids[: count.value]}


def backup(paths: list[Path], stamp: str, directory: Path | None) -> int:
    saved = 0
    for path in paths:
        if not path.exists():
            continue
        destinations = [path.with_name(f"{path.name}.bak-{stamp}")]
        if directory is not None:
            destinations.append(directory / path.name)
        for destination in destinations:
            shutil.copy2(path, destination)
            os.chmod(destination, stat.S_IRUSR | stat.S_IWUSR)
            saved += 1
    return saved


def archive(path: Path, reason: str) -> Path:
    stamp = utc_stamp()
    candidate = path.with_name(f"{path.stem}.retired-{reason}-{stamp}{path.suffix}")
    suffix = 1
    while candidate.exists():
        candidate = path.with_name(
            f"{path.stem}.retired-{reason}-{stamp}-{suffix}{path.suffix}")
        suffix += 1
    shutil.copy2(path, candidate)
    os.chmod(candidate, stat.S_IRUSR | stat.S_IWUSR)
    return candidate


def write_private(path: Path, payload: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    os.chmod(temporary, stat.S_IRUSR | stat.S_IWUSR)
    os.replace(temporary, path)


def load(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text())


class Identity:
    """Decides whether a saved entry still refers to real hardware."""

    def __init__(self, inventory_uuids: set[str], active_ids: set[int]) -> None:
        self.inventory_uuids = inventory_uuids
        self.active_ids = active_ids

    def exists(self, entry: dict, uuid_field: str = "uuid") -> bool:
        uuid = entry.get(uuid_field)
        if uuid:
            # BetterDisplay still knows this display, even if the curtain has it
            # disconnected right now; retiring it would lose a real restore target.
            return uuid in self.inventory_uuids
        if uuid_field != "uuid":
            # A window record always names its display; no UUID means it cannot be
            # placed, but that is a data problem rather than proof of removal.
            return False
        display_id = entry.get("displayID")
        return isinstance(display_id, int) and display_id in self.active_ids


def retire_entries(state: Path, name: str, key: str, identity: Identity,
                   reason: str, dry_run: bool, uuid_field: str = "uuid") -> int:
    path = state / name
    payload = load(path)
    if payload is None:
        return 0
    entries = payload.get(key) or []
    kept = [entry for entry in entries if identity.exists(entry, uuid_field)]
    removed = [entry for entry in entries if not identity.exists(entry, uuid_field)]
    log(f"{name}: {len(entries)} saved, {len(removed)} to retire")
    if removed and not dry_run:
        log(f"  audit copy: {archive(path, reason).name}")
        deferred = dict(payload)
        deferred[key] = removed
        destination = path.with_name(f"{path.stem}.deferred.{uuid.uuid4()}{path.suffix}")
        write_private(destination, deferred)
        payload[key] = kept
        write_private(path, payload)
    return len(removed)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", default=os.path.expanduser("~"))
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()

    home = Path(arguments.home)
    state = home / ".local/state/curtain"
    if not state.is_dir():
        fail(f"{state} does not exist")
    if stat.S_IMODE(state.stat().st_mode) & 0o077:
        fail(f"{state} is not mode 0700")

    if arguments.dry_run:
        return repair(state, arguments)
    descriptor = os.open(state / "recovery.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("recovery is already in progress")
        return repair(state, arguments)


def repair(state: Path, arguments: argparse.Namespace) -> int:

    before = status_via_socket(state / "control.sock")
    if before is None:
        fail("the control socket did not answer status; start AgentCurtain first")
    log(f"status before: {json.dumps(before, sort_keys=True)}")
    if before.get("state") != "open":
        fail("the app is not idle (state != open); open the curtain before repairing")

    identity = Identity(betterdisplay_uuids(), active_display_ids())
    log(f"known display UUIDs: {len(identity.inventory_uuids)}; "
        f"active display IDs: {sorted(identity.active_ids)}")

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    directory = None if arguments.dry_run else state / f"backup-{stamp}"
    if directory is not None:
        directory.mkdir(mode=0o700)
    saved = 0 if arguments.dry_run else backup([state / name for name in STATE_FILES], stamp, directory)
    log(f"backups written: {saved}{' (dry run, not written)' if arguments.dry_run else ''}")

    retired = {}
    retired["display-session.json"] = retire_entries(
        state, "display-session.json", "displays", identity,
        "unavailable-displays", arguments.dry_run)
    retired["brightness.json"] = retire_entries(
        state, "brightness.json", "displays", identity,
        "unavailable-displays", arguments.dry_run)
    retired["window-session.json"] = retire_entries(
        state, "window-session.json", "windows", identity,
        "retired-display-windows", arguments.dry_run, uuid_field="displayUUID")

    after = status_via_socket(state / "control.sock")
    if after is not None:
        log(f"status after: {json.dumps(after, sort_keys=True)}")
    if directory is not None:
        log(f"backup directory: {directory}")
    if arguments.dry_run:
        log("dry run: nothing was written")
    log(f"retired counts: {json.dumps(retired, sort_keys=True)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
