#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentCurtain"
BUNDLE_ID="com.longbiaochen.AgentCurtain"
APP_VERSION="1.1.4"
SIGNING_IDENTITY="${CURTAIN_SIGNING_IDENTITY:-Developer ID Application: LONGBIAO CHEN (HJG65XBC25)}"
MIN_SYSTEM_VERSION="26.0"
BUILD_CONFIGURATION="${CURTAIN_BUILD_CONFIGURATION:-release}"
SWIFTPM_SCRATCH_PATH="${CURTAIN_SWIFTPM_SCRATCH_PATH:-${TMPDIR:-/tmp}/agent-curtain-swiftpm-$(id -u)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${CURTAIN_DIST_DIR:-${TMPDIR:-/tmp}/agent-curtain-dist-$(id -u)}"
DIST_APP="$DIST_DIR/$APP_NAME.app"
STAGE_DIR="${TMPDIR:-/tmp}/agent-curtain-build-$(id -u)"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALLED_APP="/Applications/$APP_NAME.app"
SOCKET_PATH="$HOME/.local/state/curtain/control.sock"

case "$MODE" in
  --build-only|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--install|install) ;;
  *)
    echo "usage: $0 [--build-only|run|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac

stop_running_app() {
  if [[ -S "$SOCKET_PATH" ]]; then
    python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1]); s.sendall(b"quit\n"); s.shutdown(socket.SHUT_WR); s.recv(4096); s.close()' "$SOCKET_PATH" 2>/dev/null || true
  fi
  for _ in {1..50}; do
    [[ -S "$SOCKET_PATH" ]] || return 0
    sleep 0.1
  done
  echo "$APP_NAME did not remove its control socket" >&2
  return 1
}

stage_bundle() {
  swift build -c "$BUILD_CONFIGURATION" --scratch-path "$SWIFTPM_SCRATCH_PATH"
  local bin_dir
  bin_dir="$(swift build -c "$BUILD_CONFIGURATION" --scratch-path "$SWIFTPM_SCRATCH_PATH" --show-bin-path)"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  install -m 755 "$bin_dir/AgentCurtain" "$APP_MACOS/AgentCurtain"
  install -m 755 "$bin_dir/AgentCurtainRestoreWatchdog" "$APP_MACOS/AgentCurtainRestoreWatchdog"

  plutil -create xml1 "$INFO_PLIST"
  plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
  plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
  plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
  plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
  plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
  plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$INFO_PLIST"
  plutil -insert CFBundleVersion -string "$(git -C "$ROOT_DIR" rev-list --count HEAD)" "$INFO_PLIST"
  plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
  plutil -insert LSUIElement -bool true "$INFO_PLIST"
  plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
  /usr/bin/xattr -cr "$APP_BUNDLE"
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
}

publish_dist_copy() {
  rm -rf "$DIST_APP"
  mkdir -p "$DIST_DIR"
  /usr/bin/ditto --norsrc "$APP_BUNDLE" "$DIST_APP"
  /usr/bin/xattr -cr "$DIST_APP" 2>/dev/null || true
  codesign --verify --deep --strict --verbose=2 "$DIST_APP"
  echo "signed candidate: $DIST_APP"
}

sign_bundle() {
  security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\"" || {
    echo "required signing identity is unavailable: $SIGNING_IDENTITY" >&2
    exit 1
  }
  clean_bundle_metadata
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_MACOS/AgentCurtain"
  clean_bundle_metadata
  # Keep the crash watchdog under the app's stable code requirement. It restores
  # display hardware, then relaunches the TCC-authorized main executable for windows.
  codesign --force --identifier "$BUNDLE_ID" --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_MACOS/AgentCurtainRestoreWatchdog"
  clean_bundle_metadata
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  clean_bundle_metadata
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

  local requirement
  requirement="$(codesign -d -r- "$APP_BUNDLE" 2>&1)"
  grep -q 'anchor apple generic' <<<"$requirement" || {
    echo "designated requirement is not anchored to Apple Developer ID" >&2
    echo "$requirement" >&2
    exit 1
  }
  if grep -q 'cdhash' <<<"$requirement"; then
    echo "designated requirement unexpectedly contains cdhash" >&2
    echo "$requirement" >&2
    exit 1
  fi
  publish_dist_copy
}

clean_bundle_metadata() {
  /usr/bin/xattr -cr "$APP_BUNDLE"
  while IFS= read -r path; do
    /usr/bin/xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.ResourceFork "$path" 2>/dev/null || true
    /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$path" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.provenance "$path" 2>/dev/null || true
  done < <(find "$APP_BUNDLE" -print)
}

launch_and_wait() {
  local app_path=$1
  /usr/bin/open -n "$app_path"
  for _ in {1..100}; do
    if [[ -S "$SOCKET_PATH" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME did not create $SOCKET_PATH" >&2
  return 1
}

install_artifacts() {
  if [[ -f "$HOME/.local/state/curtain/brightness.bak" ]] \
     && [[ -x "$HOME/.local/bin/curtain" ]] \
     && grep -q 'BLOCKER=' "$HOME/.local/bin/curtain"; then
    "$HOME/.local/bin/curtain" off
    [[ ! -f "$HOME/.local/state/curtain/brightness.bak" ]] || {
      echo "legacy curtain brightness restore did not finish; refusing migration" >&2
      exit 1
    }
  fi
  stop_running_app
  rm -rf "$INSTALLED_APP"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"

  mkdir -p "$HOME/.local/bin" "$HOME/.config/curtain" "$HOME/.local/state/curtain"
  chmod 700 "$HOME/.config/curtain" "$HOME/.local/state/curtain"
  install -m 755 "$ROOT_DIR/bin/curtain" "$HOME/.local/bin/curtain"
  [[ -f "$HOME/.config/curtain/allowlist" ]] || install -m 600 "$ROOT_DIR/examples/allowlist" "$HOME/.config/curtain/allowlist"
  [[ -f "$HOME/.config/curtain/denylist" ]] || install -m 600 "$ROOT_DIR/examples/denylist" "$HOME/.config/curtain/denylist"

  if [[ -w /usr/local/bin ]]; then
    install -m 755 "$ROOT_DIR/bin/curtain" /usr/local/bin/curtain
  elif [[ -w /usr/local/bin/curtain ]]; then
    /bin/cp "$ROOT_DIR/bin/curtain" /usr/local/bin/curtain
    chmod 755 /usr/local/bin/curtain
  elif sudo -n true >/dev/null 2>&1; then
    sudo -n install -m 755 "$ROOT_DIR/bin/curtain" /usr/local/bin/curtain
  else
    echo "warning: /usr/local/bin/curtain could not be updated without interactive sudo; ~/.local/bin/curtain is current" >&2
  fi
  launch_and_wait "$INSTALLED_APP"

  rm -f \
    "$HOME/.local/libexec/hid-blocker" \
    "$HOME/.local/libexec/curtain-banner" \
    "$HOME/.local/libexec/curtain-watchdog" \
    "$HOME/.local/libexec/hid-blocker.swift" \
    "$HOME/.local/libexec/sg-banner.swift"
  echo "retired legacy hid-blocker, curtain-banner, and watchdog installation"

  # 看护跟着一起装。它是 app 之外的一双眼睛 —— 正是这个安装动作本身
  # 在 2026-09-02 把幕帘拆掉、没装回去、也没有任何人被告知。
  mkdir -p "$HOME/.local/libexec" "$HOME/Library/LaunchAgents" "$HOME/.local/state/curtain"
  install -m 755 "$ROOT_DIR/bin/curtain-sentry" "$HOME/.local/libexec/curtain-sentry"
  sentry_plist="$HOME/Library/LaunchAgents/me.longbiaochen.curtain-sentry.plist"
  sed "s|__HOME__|$HOME|g" "$ROOT_DIR/examples/me.longbiaochen.curtain-sentry.plist" > "$sentry_plist"
  launchctl bootout "gui/$(id -u)/me.longbiaochen.curtain-sentry" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$sentry_plist"
  echo "installed curtain-sentry (launchd, every 5 min)"

  echo "preserved existing login-item registrations"
}

if [[ "$MODE" != "--build-only" ]]; then stop_running_app; fi
stage_bundle
sign_bundle

case "$MODE" in
  --build-only) ;;
  run)
    launch_and_wait "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_MACOS/AgentCurtain"
    ;;
  --logs|logs)
    launch_and_wait "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "AgentCurtain"'
    ;;
  --telemetry|telemetry)
    launch_and_wait "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.longbiaochen.AgentCurtain" OR process == "AgentCurtain"'
    ;;
  --verify|verify)
    swift test --scratch-path "$SWIFTPM_SCRATCH_PATH"
    "$ROOT_DIR/tests/banner-lifetime.zsh"
    zsh "$ROOT_DIR/tests/banner-layout.zsh"
    zsh "$ROOT_DIR/tests/coordinator-transitions.zsh"
    zsh "$ROOT_DIR/tests/window-session-recovery.zsh"
    CURTAIN_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH_PATH" "$ROOT_DIR/tests/watchdog-integration.zsh"
    swiftc -typecheck -parse-as-library "$ROOT_DIR/script/verify_banner_framebuffer.swift" \
      -framework CoreGraphics \
      -framework ScreenCaptureKit
    launch_and_wait "$APP_BUNDLE"
    python3 -c 'import json,os,socket,stat,sys,time
path=sys.argv[1]
mode=stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
deadline=time.time()+60
while True:
 s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(path); s.sendall(b"status\n"); s.shutdown(socket.SHUT_WR)
 response=json.loads(s.recv(4096)); s.close()
 if response.get("state") == "open": break
 if time.time() >= deadline: raise AssertionError(response)
 time.sleep(.25)
assert response["ok"] is True, response
print("verify: signed app launched; control.sock is 0600; status protocol returned open")' "$SOCKET_PATH"
    ;;
  --install|install)
    install_artifacts
    python3 -c 'import json,socket,sys,time
deadline=time.time()+60
while True:
 s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.sendall(b"status\n"); s.shutdown(socket.SHUT_WR)
 r=json.loads(s.recv(4096)); s.close()
 if r.get("state") == "open": break
 if time.time() >= deadline: raise AssertionError(r)
 time.sleep(.25)
assert r["ok"] is True, r
print("installed status:", json.dumps(r, ensure_ascii=False, sort_keys=True))' "$SOCKET_PATH"
    ;;
esac
