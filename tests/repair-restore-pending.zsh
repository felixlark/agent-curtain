#!/usr/bin/env zsh
# Regression test for script/repair-restore-pending.py.
#
# The 2026-10-22 incident left display-session.json with UUIDs for displays that
# no longer existed. The repair tool must back up every file it touches, remove
# only the entries whose hardware is gone, and keep the rest. It talks to a fake
# control socket and a fake betterdisplaycli, so it never touches real hardware.
set -euo pipefail

root=${0:A:h:h}
fixture=$(mktemp -d /tmp/curtain-repair-test.XXXXXX)
socket_pid=""
cleanup() {
  [[ -n "$socket_pid" ]] && kill "$socket_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT

state=$fixture/.local/state/curtain
mkdir -p "$state" "$fixture/bin"
chmod 700 "$state"

# A fake CLI that reports the four real UUIDs and knows nothing about the gone ones.
cat > "$fixture/bin/betterdisplaycli" <<'SH'
#!/bin/sh
cat <<'JSON'
{"UUID":"internal","displayID":"1"},{"UUID":"external","displayID":"2"},{"UUID":"portrait","displayID":"3"},{"UUID":"dell","displayID":"5"}
JSON
SH
chmod +x "$fixture/bin/betterdisplaycli"

cat > "$state/display-session.json" <<'JSON'
{"connectionBackend":"system-spi","createdAt":1792402257358,"displays":[{"displayID":1,"isBuiltin":true,"placement":"0x0","resolution":"1512x982","uuid":"internal","wasMain":true},{"displayID":2,"isBuiltin":false,"placement":"1733x-2048","resolution":"1080x1920","uuid":"external","wasMain":false},{"displayID":3,"isBuiltin":false,"placement":"-827x-1440","resolution":"2560x1440","uuid":"portrait","wasMain":false},{"displayID":5,"isBuiltin":false,"placement":"-2747x-872","resolution":"1920x1080","uuid":"dell","wasMain":false},{"displayID":16,"isBuiltin":false,"placement":"0x0","resolution":"1512x982","uuid":"gone-a","wasMain":true},{"displayID":17,"isBuiltin":false,"placement":"3432x0","resolution":"1512x982","uuid":"gone-b","wasMain":false}],"ownerPID":1079,"version":2}
JSON
cat > "$state/brightness.json" <<'JSON'
{"createdAt":1792402273161,"displays":[{"brightness":0.795,"displayID":1,"hardwareBrightness":0.73,"softwareBrightness":1,"uuid":"internal"},{"brightness":1,"displayID":2,"uuid":"external"},{"brightness":1,"displayID":3,"uuid":"portrait"},{"brightness":1,"displayID":5,"uuid":"dell"},{"brightness":1,"displayID":16,"uuid":"gone-a"},{"brightness":1,"displayID":17,"uuid":"gone-b"}],"ownerPID":1079}
JSON
cat > "$state/window-session.json" <<'JSON'
{"createdAt":1792402265623,"displays":[],"ownerPID":1079,"version":1,"windows":[{"applicationName":"A","displayUUID":"internal","frame":{"height":10,"width":10,"x":0,"y":0},"ordinal":0,"ownerPID":1,"relativeFrame":{"height":1,"width":1,"x":0,"y":0},"role":"AXWindow","subrole":"AXStandardWindow","windowID":1},{"applicationName":"B","displayUUID":"gone-a","frame":{"height":10,"width":10,"x":0,"y":0},"ordinal":0,"ownerPID":2,"relativeFrame":{"height":1,"width":1,"x":0,"y":0},"role":"AXWindow","subrole":"AXStandardWindow","windowID":2}]}
JSON
chmod 600 "$state"/*.json

python3 "$root/tests/fixtures/fake-control-socket.py" "$state/control.sock" open &
socket_pid=$!
for _ in {1..50}; do [[ -S "$state/control.sock" ]] && break; sleep 0.1; done

PATH="$fixture/bin:$PATH" python3 "$root/script/repair-restore-pending.py" --home "$fixture" --dry-run \
  > "$fixture/dry-run.log" 2>&1
python3 - "$state" <<'PY'
import pathlib, sys
state = pathlib.Path(sys.argv[1])
assert {path.name for path in state.iterdir()} == {
    'control.sock', 'display-session.json', 'brightness.json', 'window-session.json'}
PY

python3 - "$state" "$fixture" <<'PY' &
import fcntl, pathlib, sys, time
state, root = map(pathlib.Path, sys.argv[1:])
with (state / 'recovery.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    (root / 'locked').touch()
    while not (root / 'unlock').exists():
        time.sleep(0.02)
PY
lock_pid=$!
for _ in {1..50}; do [[ -e "$fixture/locked" ]] && break; sleep 0.1; done
if PATH="$fixture/bin:$PATH" python3 "$root/script/repair-restore-pending.py" --home "$fixture" \
  > "$fixture/locked.log" 2>&1; then
  touch "$fixture/unlock"
  wait "$lock_pid"
  exit 1
fi
grep -q 'recovery is already in progress' "$fixture/locked.log"
touch "$fixture/unlock"
wait "$lock_pid"

PATH="$fixture/bin:$PATH" python3 "$root/script/repair-restore-pending.py" --home "$fixture" \
  > "$fixture/repair.log" 2>&1 || { cat "$fixture/repair.log"; exit 1; }

fail() { print -u2 "repair-restore-pending: $1"; print -u2 "$(<"$fixture/repair.log")"; exit 1; }

# 1. Every touched file has an external backup in a timestamped directory.
backup_dir=($state/backup-*(N/))
(( ${#backup_dir} == 1 )) || fail "expected exactly one timestamped backup directory"
for name in display-session.json brightness.json window-session.json; do
  ls "$state/$name".bak-* >/dev/null 2>&1 || fail "missing $name external backup"
  [[ -f "$backup_dir[1]/$name" ]] || fail "missing $name backup copy"
done
# 2. Backups still contain the vanished entries; the originals do not.
python3 - "$state" <<'PY' || fail "backup or original content is wrong"
import glob, json, sys
state = sys.argv[1]
backup = glob.glob(state + "/display-session.json.bak-*")[0]
assert any(d["uuid"] == "gone-a" for d in json.load(open(backup))["displays"])
live = json.load(open(state + "/display-session.json"))
uuids = [d["uuid"] for d in live["displays"]]
assert "gone-a" not in uuids and "gone-b" not in uuids, uuids
assert uuids == ["internal", "external", "portrait", "dell"], uuids
brightness = json.load(open(state + "/brightness.json"))
assert [d["uuid"] for d in brightness["displays"]] == uuids
windows = json.load(open(state + "/window-session.json"))
assert [w["applicationName"] for w in windows["windows"]] == ["A"]
deferred = glob.glob(state + "/display-session.deferred.*.json")
assert len(deferred) == 1
assert [d['uuid'] for d in json.load(open(deferred[0]))['displays']] == ['gone-a', 'gone-b']
PY
# 3. An audit copy of each original is kept.
ls "$state"/display-session.retired-unavailable-displays-*.json >/dev/null || fail "missing display audit"
ls "$state"/brightness.retired-unavailable-displays-*.json >/dev/null || fail "missing brightness audit"
ls "$state"/window-session.retired-retired-display-windows-*.json >/dev/null || fail "missing window audit"
# 4. Permissions stay private.
[[ "$(stat -f '%Lp' "$state/display-session.json")" == 600 ]] || fail "display-session.json mode changed"
[[ "$(stat -f '%Lp' "$backup_dir[1]")" == 700 ]] || fail "backup directory must be 0700"

# 5. An idle app is required: a drawn curtain must be refused.
kill "$socket_pid" 2>/dev/null || true
socket_pid=""
rm -f "$state/control.sock"
python3 "$root/tests/fixtures/fake-control-socket.py" "$state/control.sock" drawn &
socket_pid=$!
for _ in {1..50}; do [[ -S "$state/control.sock" ]] && break; sleep 0.1; done
if PATH="$fixture/bin:$PATH" python3 "$root/script/repair-restore-pending.py" --home "$fixture" \
  > "$fixture/refused.log" 2>&1; then
  fail "a drawn curtain must not be edited"
fi
grep -q 'not idle' "$fixture/refused.log" || fail "refusal reason is not explained"

print "repair-restore-pending: backups, retirement scope, audit copies and idle guard passed"
