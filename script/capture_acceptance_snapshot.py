#!/usr/bin/env python3
"""Record a bounded, read-only installed-app snapshot for manual acceptance."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="e.g. before-unlock or after-unlock")
    parser.add_argument("--output-root", type=Path,
                        help="defaults to Application Support/agent-curtain/acceptance/YYYY-MM-DD")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.label):
        parser.error("label must contain 1-64 letters, digits, underscores or hyphens")

    state = Path.home() / ".local/state/curtain"
    app = Path("/Applications/AgentCurtain.app")
    now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    output_root = args.output_root or (Path.home() /
        "Library/Application Support/agent-curtain/acceptance" / now.date().isoformat())
    record = {"recordedAt": now.isoformat(), "label": args.label,
              "host": os.uname().nodename, "files": {}}
    errors = []
    try:
        # Use the existing public protocol. Never launch, reload, enable or release.
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(state / "control.sock"))
            client.sendall(b"status\n")
            client.shutdown(socket.SHUT_WR)
            chunks = []
            size = 0
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                size += len(chunk)
                if size > 65536:
                    raise ValueError("status response exceeds 64 KiB")
                chunks.append(chunk)
        record["status"] = json.loads(b"".join(chunks))
        if not isinstance(record["status"], dict):
            raise ValueError("status response is not a JSON object")
        if record["status"].get("state") not in {"starting", "open", "drawing", "drawn", "opening"}:
            raise ValueError("status response has no recognized state")
        if record["status"].get("ok") is not True:
            errors.append("installed app reported ok=false")
    except (OSError, ValueError) as error:
        errors.append(f"status unavailable: {error}")

    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        record["installedVersion"] = info["CFBundleShortVersionString"]
        record["installedExecutableSHA256"] = hashlib.sha256(
            (app / "Contents/MacOS/AgentCurtain").read_bytes()).hexdigest()
        signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                    str(app)], capture_output=True, text=True, timeout=15)
        record["signatureValid"] = signature.returncode == 0
        if signature.returncode:
            errors.append(f"signature verification failed: {signature.stderr.strip()}")
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        errors.append(f"installed identity unavailable: {error}")

    for name in ("brightness.json", "display-session.json", "window-session.json",
                 "last-brightness-recovery.json", "last-window-recovery.json"):
        path = state / name
        try:
            data = path.read_bytes()
            entry = {"path": str(path), "sha256": hashlib.sha256(data).hexdigest()}
            if not name.startswith("last-"):
                backup = json.loads(data)
                if not isinstance(backup, dict):
                    raise ValueError("backup is not a JSON object")
                entry.update(ownerPID=backup.get("ownerPID"), createdAt=backup.get("createdAt"),
                             displayCount=len(backup.get("displays", [])),
                             windowCount=len(backup.get("windows", [])))
            record["files"][name] = entry
        except FileNotFoundError:
            record["files"][name] = {"present": False}
        except (OSError, ValueError) as error:
            errors.append(f"{name} unreadable: {error}")
    record["errors"] = errors
    output_root.mkdir(parents=True, exist_ok=True)
    output = output_root / f"{now.strftime('%H%M%S-%f')}-{args.label}.json"
    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        json.dump(record, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(output)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
