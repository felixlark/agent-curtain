import AgentCurtainCore
import Foundation

func require(_ condition: Bool) { precondition(condition) }

let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: home) }
let paths = CurtainPaths(home: home)
try paths.prepareDirectories()
let cli = home.appendingPathComponent("cli")
try #"""
#!/bin/sh
printf '%s\n' "$*" >> "${0%/*}/commands"
case "$*" in
  'get --identifiers') cat "${0%/*}/identities" ;;
  'get -proAvailable') echo on ;;
  *-main) echo true ;;
  *-connected) echo on ;;
  *-placement) echo 0x0 ;;
  *-resolution) echo 1512x982 ;;
  *-rotation) echo 0 ;;
  *-brightness*) echo 0.73 ;;
esac
"""#.write(to: cli, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
let identities = home.appendingPathComponent("identities")
try #"[{"displayID":1,"UUID":"internal"}]"#.write(to: identities, atomically: true, encoding: .utf8)
var activeIDs = [1]
let clientFactory = {
    try BetterDisplayClient(executable: cli, application: nil,
        activeDisplayProvider: { activeIDs }, builtinDisplayProvider: { $0 == 1 })
}
let internalDisplay = DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true,
    wasMain: true, placement: "0x0", resolution: "1512x982", rotation: "0")
let external = DisplayTopology(uuid: "external", displayID: 16, isBuiltin: false,
    wasMain: false, placement: "0x0", resolution: "1512x982", rotation: "0")
let absent = DisplayTopology(uuid: "absent", displayID: 17, isBuiltin: false,
    wasMain: false, placement: "0x0", resolution: "1512x982", rotation: "0")
let saved = DisplaySessionBackup(ownerPID: 42, createdAt: Date(timeIntervalSince1970: 100),
    connectionBackend: .betterDisplay, displays: [internalDisplay, external, absent])
let display = DisplaySessionController(paths: paths, clientFactory: clientFactory, restoreOperation: {
    try DisplaySessionOperations.restoreAvailable($0, client: $1, backend: BetterDisplayConnectionBackend(client: $1))
})
try DisplaySessionBackupStore.write(saved, to: paths.displaySessionBackup)
try display.restoreAllDisplays()
precondition(display.pendingRestoreCount == 0)
var deferred = try DeferredRecovery.candidates(for: paths.displaySessionBackup)
precondition(deferred.count == 1)
let offline = try DisplaySessionBackupStore.read(from: deferred[0])
precondition(offline.displays.map(\.uuid) == ["external", "absent"])
precondition(offline.createdAt == saved.createdAt)
print("PASS: all offline external targets preserved without live restore-pending")

try #"[{"displayID":1,"UUID":"internal"},{"displayID":22,"UUID":"external"}]"#
    .write(to: identities, atomically: true, encoding: .utf8)
activeIDs = [1, 22]
try display.restoreAllDisplays()
deferred = try DeferredRecovery.candidates(for: paths.displaySessionBackup)
require(try DisplaySessionBackupStore.read(from: deferred[0]).displays.map(\.uuid) == ["absent"])
precondition(display.lastRetiredDisplays.isEmpty)
print("PASS: reconnected UUID remapped and restored while another target stays deferred")

let misplaced = DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true,
    wasMain: true, placement: "123x456", resolution: "1512x982", rotation: "0")
let failed = DisplaySessionBackup(ownerPID: 42, connectionBackend: .systemSPI, displays: [misplaced])
try DisplaySessionBackupStore.write(failed, to: paths.displaySessionBackup)
let failing = DisplaySessionController(paths: paths, clientFactory: clientFactory, restoreOperation: { backup, _ in
    DisplayRestoreReport(warnings: ["complete returned 1001"], deferred: backup.displays.map(\.uuid))
})
try failing.restoreAllDisplays()
precondition(failing.pendingRestoreCount == 0)
_ = try failing.capture()
let captured = try DisplaySessionBackupStore.read(from: paths.displaySessionBackup)
precondition(captured.displays.first { $0.uuid == "internal" }?.placement == "123x456")
precondition(captured.displays.filter { $0.uuid == "internal" }.count == 1)
try FileManager.default.removeItem(at: paths.displaySessionBackup)
print("PASS: a new draw retains the original topology after exhausted layout recovery")

let brightness = BrightnessController(paths: paths, clientFactory: clientFactory)
let brightnessSaved = BrightnessBackup(ownerPID: 42, createdAt: saved.createdAt, displays: [
    DisplayBrightness(displayID: 16, brightness: 0.73, uuid: "external"),
    DisplayBrightness(displayID: 17, brightness: 0.73, uuid: "absent")
])
activeIDs = [1]
try BrightnessBackupStore.write(brightnessSaved, to: paths.brightnessBackup)
try brightness.restoreAllDisplays()
let deferredBrightness = try DeferredRecovery.candidates(for: paths.brightnessBackup)
precondition(deferredBrightness.count == 1)
require(try BrightnessBackupStore.read(from: deferredBrightness[0]).displays.count == 2)
activeIDs = [1, 22]
try brightness.restoreAllDisplays()
require(try BrightnessBackupStore.read(from: deferredBrightness[0]).displays.map(\.uuid) == ["absent"])
print("PASS: inventory-only brightness stays deferred and restores by UUID on reconnection")

let frame = WindowSessionRect(x: 0, y: 0, width: 100, height: 100)
let window = SavedWindow(ownerPID: 42, bundleIdentifier: "example", applicationName: "Example",
    windowID: 1, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow",
    ordinal: 0, displayUUID: "external", frame: frame, relativeFrame: frame)
let windowBackup = WindowSessionBackup(ownerPID: 42, createdAt: saved.createdAt, displays: [], windows: [window])
try WindowSessionBackupStore.write(windowBackup, to: paths.windowSessionBackup)
let windowController = WindowSessionController(paths: paths, captureOperation: { windowBackup },
    restoreOperation: { backup, _ in
        WindowRestorationReport(saved: 1, restored: 0, disappeared: 0,
            retiredWindows: WindowSessionPlanner.retireStrandedWindows(backup.windows, retiredDisplays: ["external"]).retired)
    }, activeDisplayUUIDs: { [] })
_ = try windowController.restoreAllWindows()
precondition(windowController.pendingRestoreCount == 0)
var restored = false
let reconnected = WindowSessionController(paths: paths, captureOperation: { windowBackup },
    restoreOperation: { backup, _ in
        precondition(backup.createdAt == saved.createdAt && backup.windows == [window])
        restored = true
        return WindowRestorationReport(saved: 1, restored: 1, disappeared: 0)
    }, activeDisplayUUIDs: { ["external"] }, processStartTime: { _ in Date(timeIntervalSince1970: 0) })
_ = try reconnected.restoreAllWindows()
precondition(restored)
require(try DeferredRecovery.candidates(for: paths.windowSessionBackup).isEmpty)
print("PASS: deferred windows retain PID-lifetime timestamp and restore on reconnection")

let oldTarget = DisplaySessionBackup(ownerPID: 42, createdAt: saved.createdAt,
    connectionBackend: .betterDisplay, displays: [misplaced])
try DisplaySessionBackupStore.write(oldTarget, to: DeferredRecovery.destination(for: paths.displaySessionBackup))
try DisplaySessionBackupStore.write(DisplaySessionBackup(ownerPID: 42,
    connectionBackend: .betterDisplay, displays: [internalDisplay]), to: paths.displaySessionBackup)
var layouts: [String] = []
let overlap = DisplaySessionController(paths: paths, clientFactory: clientFactory, restoreOperation: { backup, _ in
    layouts.append(contentsOf: backup.displays.map(\.placement))
    return DisplayRestoreReport(restored: backup.displays.map(\.uuid))
})
try overlap.restoreAllDisplays()
precondition(layouts == ["123x456"], "only the oldest unresolved topology may replay, even with multiple deferred files")

try BrightnessBackupStore.write(BrightnessBackup(ownerPID: 42, createdAt: saved.createdAt, displays: [
    DisplayBrightness(displayID: 22, brightness: 0.73, uuid: "external")
]), to: DeferredRecovery.destination(for: paths.brightnessBackup))
try BrightnessBackupStore.write(BrightnessBackup(ownerPID: 42, createdAt: Date(timeIntervalSince1970: 150), displays: [
    DisplayBrightness(displayID: 22, brightness: 0.735, uuid: "external")
]), to: DeferredRecovery.destination(for: paths.brightnessBackup))
try BrightnessBackupStore.write(BrightnessBackup(ownerPID: 42, displays: [
    DisplayBrightness(displayID: 22, brightness: 0.74, uuid: "external")
]), to: paths.brightnessBackup)
try brightness.restoreAllDisplays()
let writes = try String(contentsOf: home.appendingPathComponent("commands"), encoding: .utf8)
    .split(separator: "\n").filter { $0.hasPrefix("set get -displayID=22 -brightness=") }
precondition(writes.last?.hasSuffix("=0.73") == true, "hot-plug capture must not overwrite deferred brightness")

try WindowSessionBackupStore.write(windowBackup, to: DeferredRecovery.destination(for: paths.windowSessionBackup))
try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: 42, displays: [], windows: [window]),
    to: paths.windowSessionBackup)
var windowDates: [Date] = []
let overlapWindows = WindowSessionController(paths: paths, captureOperation: { windowBackup },
    restoreOperation: { backup, _ in
        if !backup.windows.isEmpty { windowDates.append(backup.createdAt) }
        return WindowRestorationReport(saved: backup.windows.count, restored: backup.windows.count, disappeared: 0)
    }, activeDisplayUUIDs: { ["external"] }, processStartTime: { _ in Date(timeIntervalSince1970: 0) })
_ = try overlapWindows.restoreAllWindows()
precondition(windowDates == [saved.createdAt], "the same window must replay only its original target and timestamp")
print("PASS: overlapping live snapshots cannot overwrite deferred topology, brightness or windows")

try WindowSessionBackupStore.write(windowBackup, to: paths.windowSessionBackup)
var corrected = false
let waitingForLayout = WindowSessionController(paths: paths, captureOperation: { windowBackup },
    restoreOperation: { backup, _ in
        if !backup.windows.isEmpty {
            precondition(backup.createdAt == saved.createdAt && backup.windows == [window])
            corrected = true
        }
        return WindowRestorationReport(saved: backup.windows.count, restored: backup.windows.count, disappeared: 0)
    }, activeDisplayUUIDs: { ["external"] }, processStartTime: { _ in Date(timeIntervalSince1970: 0) })
_ = try waitingForLayout.restoreAllWindows(retiredDisplays: [], deferredDisplays: ["external"])
precondition(!corrected && waitingForLayout.pendingRestoreCount == 0)
let heldWindows = try DeferredRecovery.candidates(for: paths.windowSessionBackup)
precondition(heldWindows.count == 1)
require(try WindowSessionBackupStore.read(from: heldWindows[0]).createdAt == saved.createdAt)
_ = try waitingForLayout.restoreAllWindows(retiredDisplays: [], deferredDisplays: [])
precondition(corrected)
require(try DeferredRecovery.candidates(for: paths.windowSessionBackup).isEmpty)
print("PASS: active displays with deferred layout retain original window metadata until layout succeeds")

try WindowSessionBackupStore.write(windowBackup, to: DeferredRecovery.destination(for: paths.windowSessionBackup))
let newProcessCapture = Date(timeIntervalSince1970: 200)
try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: 42, createdAt: newProcessCapture,
    displays: [], windows: [window]), to: paths.windowSessionBackup)
var currentProcessRestored = false
let reusedPID = WindowSessionController(paths: paths, captureOperation: { windowBackup },
    restoreOperation: { backup, _ in
        let valid = backup.createdAt >= Date(timeIntervalSince1970: 150)
        if valid && !backup.windows.isEmpty { currentProcessRestored = true }
        return WindowRestorationReport(saved: backup.windows.count,
            restored: valid ? backup.windows.count : 0, disappeared: valid ? 0 : backup.windows.count)
    }, activeDisplayUUIDs: { ["external"] }, processStartTime: { _ in Date(timeIntervalSince1970: 150) })
_ = try reusedPID.restoreAllWindows()
precondition(currentProcessRestored, "an old reused PID must not supersede the current process target")
print("PASS: stale PID targets cannot supersede a newer process's window metadata")

for identifier in [nil, "", "reused-ax-identifier"] as [String?] {
    let oldWeak = SavedWindow(ownerPID: 42, bundleIdentifier: "example", applicationName: "Example",
        windowID: nil, identifier: identifier, title: "Old document", role: "AXWindow", subrole: "AXStandardWindow",
        ordinal: 0, displayUUID: "absent", frame: frame, relativeFrame: frame)
    let newWeak = SavedWindow(ownerPID: 42, bundleIdentifier: "example", applicationName: "Example",
        windowID: nil, identifier: identifier, title: "New document", role: "AXWindow", subrole: "AXStandardWindow",
        ordinal: 0, displayUUID: "external", frame: frame, relativeFrame: frame)
    let oldFile = DeferredRecovery.destination(for: paths.windowSessionBackup)
    try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: 42, createdAt: saved.createdAt,
        displays: [], windows: [oldWeak]), to: oldFile)
    try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: 42, createdAt: newProcessCapture,
        displays: [], windows: [newWeak]), to: paths.windowSessionBackup)
    var newDocumentRestored = false
    let weak = WindowSessionController(paths: paths, captureOperation: { windowBackup },
        restoreOperation: { backup, _ in
            if !backup.windows.isEmpty {
                precondition(backup.windows == [newWeak])
                newDocumentRestored = true
            }
            return WindowRestorationReport(saved: backup.windows.count, restored: backup.windows.count, disappeared: 0)
        }, activeDisplayUUIDs: { ["external"] }, processStartTime: { _ in Date(timeIntervalSince1970: 0) })
    _ = try weak.restoreAllWindows()
    precondition(newDocumentRestored, "a weak ordinal/AX identifier must not merge different windows")
    require(try WindowSessionBackupStore.read(from: oldFile).windows == [oldWeak])
    try FileManager.default.removeItem(at: oldFile)
}
print("PASS: missing, empty or reused AX identifiers never cause deletion-based cross-session window arbitration")
