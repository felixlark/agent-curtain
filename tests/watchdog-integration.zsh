#!/bin/zsh
set -eu

root=${0:a:h:h}
fixture=$(mktemp -d /tmp/agent-curtain-watchdog-test.XXXXXX)
owner_pid=''
watchdog_pid=''
cleanup() {
  [[ -z "$owner_pid" ]] || kill -KILL "$owner_pid" 2>/dev/null || true
  [[ -z "$watchdog_pid" ]] || kill -KILL "$watchdog_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT

scratch=${CURTAIN_SWIFTPM_SCRATCH_PATH:-$(mktemp -d /tmp/agent-curtain-watchdog-swiftpm.XXXXXX)}
swift build --package-path "$root" --scratch-path "$scratch" >/dev/null
bin_dir=$(swift build --package-path "$root" --scratch-path "$scratch" --show-bin-path)
fake_cli="$root/tests/fixtures/fake-betterdisplaycli"
chmod +x "$fake_cli"
log="$fixture/betterdisplay.log"
backup="$fixture/brightness.json"
session="$fixture/display-session.json"
window_session="$fixture/window-session.json"
launcher="$fixture/fake-open"
launch_log="$fixture/open.log"
mkdir -p "$fixture/AgentCurtain.app"
cat > "$launcher" <<'PY'
#!/usr/bin/env python3
import fcntl
import json
import os
import pathlib
import sys

lock = pathlib.Path(os.environ["CURTAIN_TEST_RECOVERY_LOCK"])
window_session = pathlib.Path(os.environ["CURTAIN_TEST_WINDOW_SESSION"])
launch_log = pathlib.Path(os.environ["CURTAIN_TEST_LAUNCH_LOG"])
with lock.open("a+") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    launch_log.write_text(" ".join(sys.argv[1:]))
    claimed = window_session.with_name(window_session.name + f".restoring.{os.getpid()}")
    window_session.rename(claimed)
    backup = json.loads(claimed.read_text())
    assert backup["windows"], backup
    claimed.unlink()
PY
chmod +x "$launcher"

sleep 30 &
owner_pid=$!
python3 -c 'import json,sys
json.dump({"ownerPID":int(sys.argv[2]),"createdAt":0,"displays":[{"displayID":7,"brightness":0.75}]},open(sys.argv[1],"w"))' "$backup" "$owner_pid"
chmod 600 "$backup"

python3 -c 'import json,sys
json.dump({"version":1,"ownerPID":int(sys.argv[2]),"createdAt":0,"displays":[{"uuid":"fixture-seven","displayID":7,"isBuiltin":True,"wasMain":True,"placement":"0x0","resolution":"1512x982","rotation":"0"}]},open(sys.argv[1],"w"))' "$session" "$owner_pid"
chmod 600 "$session"

python3 -c 'import json,sys
json.dump({"version":1,"ownerPID":int(sys.argv[2]),"createdAt":0,"displays":[],"windows":[{"ownerPID":321,"bundleIdentifier":"example.app","applicationName":"Example","windowID":99,"identifier":None,"title":"Document","role":"AXWindow","subrole":"AXStandardWindow","ordinal":0,"displayUUID":"fixture-seven","frame":{"x":10,"y":20,"width":800,"height":600},"relativeFrame":{"x":0.1,"y":0.1,"width":0.5,"height":0.5}}]},open(sys.argv[1],"w"))' "$window_session" "$owner_pid"
chmod 600 "$window_session"

CURTAIN_FAKE_BETTERDISPLAY_LOG="$log" \
CURTAIN_FAKE_BETTERDISPLAY_STATE="$fixture/state" \
CURTAIN_WATCHDOG_OPEN_EXECUTABLE="$launcher" \
CURTAIN_WATCHDOG_ACTIVE_DISPLAYS=7 \
CURTAIN_TEST_RECOVERY_LOCK="$fixture/recovery.lock" \
CURTAIN_TEST_WINDOW_SESSION="$window_session" \
CURTAIN_TEST_LAUNCH_LOG="$launch_log" \
  "$bin_dir/AgentCurtainRestoreWatchdog" "$owner_pid" "$backup" "$session" "$window_session" "$fake_cli" "$fixture/AgentCurtain.app" &
watchdog_pid=$!
sleep 0.3
kill -KILL "$owner_pid"
wait "$watchdog_pid"
watchdog_pid=''
owner_pid=''

[[ ! -e "$backup" ]]
[[ ! -e "$session" ]]
[[ ! -e "$window_session" ]]
grep -Fxq 'set -connectAllDisplays' "$log"
grep -Fxq 'set get -displayID=7 -brightness=0.75' "$log"
grep -Fxq -- "-gj $fixture/AgentCurtain.app" "$launch_log"

failure_case="$fixture/launch-failure"
mkdir -p "$failure_case/AgentCurtain.app"
failure_window="$failure_case/window-session.json"
failure_log="$failure_case/watchdog.log"
sleep 30 &
owner_pid=$!
python3 -c 'import json,sys
json.dump({"version":1,"ownerPID":int(sys.argv[2]),"createdAt":0,"displays":[],"windows":[{"ownerPID":321,"bundleIdentifier":"example.app","applicationName":"Example","windowID":99,"identifier":None,"title":"Document","role":"AXWindow","subrole":"AXStandardWindow","ordinal":0,"displayUUID":"fixture-seven","frame":{"x":10,"y":20,"width":800,"height":600},"relativeFrame":{"x":0.1,"y":0.1,"width":0.5,"height":0.5}}]},open(sys.argv[1],"w"))' "$failure_window" "$owner_pid"
chmod 600 "$failure_window"
CURTAIN_WATCHDOG_OPEN_EXECUTABLE=/usr/bin/false \
  "$bin_dir/AgentCurtainRestoreWatchdog" "$owner_pid" \
  "$failure_case/brightness.json" "$failure_case/display-session.json" \
  "$failure_window" "$fake_cli" "$failure_case/AgentCurtain.app" 2> "$failure_log" &
watchdog_pid=$!
sleep 0.3
kill -KILL "$owner_pid"
if wait "$watchdog_pid"; then
  print -u2 'watchdog unexpectedly succeeded when app relaunch failed'
  exit 1
fi
watchdog_pid=''
owner_pid=''
[[ -e "$failure_window" ]]
[[ -z "$(find "$failure_case" -maxdepth 1 -name 'window-session.json.restoring.*' -print -quit)" ]]
grep -Fq 'app relaunch failed:' "$failure_log"

print 'watchdog-integration: kill -9 recovery hands windows to the app after unlocking and preserves them when relaunch fails'
