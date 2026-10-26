# AgentCurtain

**Draw the curtain; keep the GUI session working.**

AgentCurtain is a macOS 26+ menu bar app for unattended GUI-agent sessions. It
dims every physical display, blocks physical keyboard and mouse events at the
HID event tap, and leaves the unlocked WindowServer session rendering normally.
Allowlisted remote-desktop processes and session-layer agent input continue to
work.

[中文说明](README.zh-CN.md) · [Measured findings](docs/FINDINGS.md) ·
[Implementation PRD](docs/PRD-menubar-app.md) ·
[Acceptance matrix](docs/ACCEPTANCE-menubar-app.md)

**Current release: [v1.1.0](docs/RELEASE-v1.1.0.md)** · Apple Silicon · macOS 26+

> AgentCurtain is weaker than the real lock screen. It deters opportunistic
> access; it does not protect against a prepared attacker, a reboot, new input
> hardware, or physical access to storage. The UI deliberately says “curtain”
> and never claims that the Mac is locked or secure.

## What is delivered

`/Applications/AgentCurtain.app` is the single installed runtime and the only
component that needs Accessibility permission. It contains:

- an `NSStatusItem` menu showing open/drawn state and live counters;
- a `kCGHIDEventTap` blocker with deny-before-allow decisions;
- one framebuffer-visible banner window per display;
- system display SPI for disconnecting and reconnecting external displays, with UUID topology restoration;
- a mode-0600 window snapshot that returns visible windows on all displays to their original display and frame;
- BetterDisplay for brightness and layout, with Pro connection management used only if the system SPI is unavailable;
- a mode-0600 Unix socket at `~/.local/state/curtain/control.sock`;
- an embedded recovery watchdog that reconnects displays and restores brightness if the app is killed, then relaunches AgentCurtain to restore window frames under the app's Accessibility permission.

The `curtain` command is a thin, unprivileged socket client. It never creates an
event tap and therefore needs no TCC permission.

## One-screen remote mode

Multi-display Macs are awkward to control from an iPad: the remote client has to
switch between several desktops while windows remain scattered across them.
AgentCurtain v1.1 disconnects every external display from the active topology
while protection is enabled. macOS moves those windows onto the built-in display,
so remote-desktop software sees one working screen.

Opening the curtain reconnects the displays and restores surviving windows to
their original display and frame. Display UUIDs are used as stable identities,
including after a display receives a new runtime ID. The embedded watchdog runs
the same recovery after an unexpected app exit.

## Install

Requirements:

- Apple Silicon and macOS 26 or newer;
- Xcode Command Line Tools;
- BetterDisplay with `betterdisplaycli` installed; Pro is an optional fallback;
- the Developer ID identity named in the PRD when building from source.

```bash
git clone https://github.com/longbiaochen/agent-curtain.git
cd agent-curtain
./install.sh
```

The build signs the main executable, embedded watchdog, and outer app with:

```text
Developer ID Application: LONGBIAO CHEN (HJG65XBC25)
```

Hardened Runtime and a secure timestamp are required. Installation fails rather
than falling back to an ad-hoc signature. The installed app is verified again
under `/Applications`.

On first use, enable **AgentCurtain** in System Settings → Privacy & Security →
Accessibility. Because the designated requirement is based on bundle identifier,
Apple anchor, and Team ID—not `cdhash`—a later signed rebuild keeps the same
authorization.

## Use

Use the menu bar icon, the global shortcuts, or the compatible CLI:

```bash
curtain on
curtain status
curtain off
curtain allow
curtain deny
curtain doctor
```

The existing timed form remains supported:

```bash
curtain on 3600
curtain on 30 --allow-marker
```

`--allow-marker` generates a fresh nonzero signed 64-bit session marker. Read it
as an `Int64` from `~/.local/state/curtain/injection-marker` (mode 0600) and set
`.eventSourceUserData` on **every** injected event before posting to
`.cghidEventTap`. A matching marker permits short-lived injectors without PID
refresh; deny rules still win. Opening the curtain revokes and removes the marker.
The response also includes `injectionMarker`; avoid JavaScript Number rounding
and do not log or share the live value. Repeating `on` while already drawn retains
the current session; use `off` first to change modes. The old
`--allow-any-injected` option is disabled and rejected.

Marker mode displays “屏幕关闭·仅放行注入” in the menu and banner. The global
shortcuts are:

- `Ctrl+Opt+Cmd+L`: draw the curtain;
- `Ctrl+Opt+Cmd+U`: open it again.

The release shortcut is checked inside the HID callback before the keystroke is
swallowed. `curtain off` only talks to the app socket and never requires
Accessibility permission, including from SSH.

## Configuration

- `~/.config/curtain/allowlist`: allowed executable paths, one per line;
- `~/.config/curtain/denylist`: always denied, with highest priority.

Blank lines and lines beginning with `#` are ignored. `.app` entries resolve to
their exact bundle executable. Non-path rules match an exact executable basename.
PID discovery uses `proc_listallpids` and `proc_pidpath`; it never uses substring
matching such as `pgrep -f`. Matching PIDs refresh every three seconds.

The default denylist contains the three Karabiner components required by the PRD.

## Runtime safety

The draw transition is ordered and rollback-safe:

1. confirm that AgentCurtain has Accessibility permission;
2. snapshot display topology and visible windows on all displays by display UUID;
3. read each active display’s brightness by `displayID` and atomically write mode-0600 recovery files;
4. start the embedded recovery watchdog;
5. set each brightness to zero and read it back;
6. arm the HID event tap, create one banner per screen, and disconnect external displays.

Any failure rolls brightness back. Normal `off`, menu-bar quit, `SIGTERM`, a
timed release, and the release shortcut all restore brightness. `kill -9` cannot
run app cleanup, so the independent embedded watchdog observes process death and
restores display topology and brightness from the same recovery files, then relaunches
AgentCurtain so the main app restores windows under its Accessibility permission.
Window restoration waits for stable display bounds, matches surviving windows by CG
window ID, AX identifier, title, and stable application order, then uses a verified
size-position-size update without activating or raising applications. Full-screen,
minimized, hidden-Space, and newly created windows are left alone. On a later launch,
the app retries any orphaned restore record.

Display-change notifications rebuild banners and reconcile newly attached
display IDs into the brightness backup before dimming them.

Display recovery checks saved UUIDs against BetterDisplay's inventory and the
active set before writing. Missing targets leave the live recovery snapshot so
they cannot block a new curtain session. Their original topology, brightness and
window records remain in mode-0600 `*.deferred.*.json` files alongside immutable
audit copies. Screen changes while open retry only reconnected targets by UUID;
successful recovery consumes those deferred entries, while offline targets remain
available for a later hot-plug. Window records retain their original timestamps
to protect against PID reuse.

A transaction returning `complete returned 1001` is retried at most three times.
After exhaustion the original target is deferred with a warning. Other errors,
including mode failures after a layout rejection, remain failures and retain the
recovery snapshot. New sessions preserve unresolved topology rather than replacing
it with the failed layout. Brightness and component readback share a 0.02 tolerance
(0.741 vs 0.73 is quantization, not a failed restore).

If an existing state directory is already stuck, repair it without losing
evidence:

```bash
python3 script/repair-restore-pending.py --dry-run   # show what would be retired
python3 script/repair-restore-pending.py             # back up, then retire
```

The tool refuses to run while the curtain is drawn, copies every file it touches
to `<name>.bak-<timestamp>` and `backup-<timestamp>/`, and never writes to a
display, installs anything, or asks for elevated permissions.

AgentCurtain never calls `pmset displaysleepnow`: display sleep stops framebuffer
composition and blinds GUI agents.

## Developer loop and verification

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

The Codex Run action points to the same script. `--verify` runs Swift tests,
strict signature validation, launches the signed bundle, verifies socket mode
0600, and checks the JSON status response.

While the curtain is drawn, verify real banner rendering on every framebuffer:

```bash
./script/verify_banner_framebuffer.sh
```

This scans the rendered feature color per `CGDirectDisplayID`; a running banner
process or a retained `NSWindow` is not accepted as proof.

Hardware acceptance remains separate. In particular, a real person must press
physical keys and use the mouse to prove the `blocked` counter rises without UI
response. Programmatically injected events cannot prove that HID-layer behavior.
The full requirement-by-requirement checklist is in
[docs/PRD-menubar-app.md](docs/PRD-menubar-app.md#9-验收标准).

Brightness restoration: releasing the curtain (including crash recovery) restores each display’s saved pre-curtain brightness by UUID.
