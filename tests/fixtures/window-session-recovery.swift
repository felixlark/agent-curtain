import AgentCurtainCore
import Foundation

enum Failure: Error { case refused }
func require(_ value: @autoclosure () -> Bool) { precondition(value()) }
let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: home) }
let paths = CurtainPaths(home: home)
try paths.prepareDirectories()
let old = WindowSessionBackup(ownerPID: 1, displays: [], windows: [])
let fresh = WindowSessionBackup(ownerPID: 2, displays: [], windows: [])
try WindowSessionBackupStore.write(old, to: paths.windowSessionBackup)
let controller = WindowSessionController(paths: paths, captureOperation: { fresh }, restoreOperation: { _ in throw Failure.refused })
do { _ = try controller.restoreAllWindows(); fatalError("must report restoration failure") } catch Failure.refused {}
let retained = try WindowSessionBackupStore.read(from: paths.windowSessionBackup)
require(retained == old)
_ = try controller.capture()
let published = try WindowSessionBackupStore.read(from: paths.windowSessionBackup)
require(published == fresh)
require(controller.recoveryWarning != nil)
print("PASS: failed restoration -> fresh capture with archived evidence and warning")
let failingCapture = WindowSessionController(paths: paths, captureOperation: { throw Failure.refused })
do { _ = try failingCapture.capture(); fatalError("must fail capture") } catch Failure.refused {}
let stillFresh = try WindowSessionBackupStore.read(from: paths.windowSessionBackup)
require(stillFresh == fresh)
print("PASS: capture failure leaves existing recovery snapshot intact")
var restoredOwners: [Int32] = []
let recovered = WindowSessionController(paths: paths, restoreOperation: { backup in
    restoredOwners.append(backup.ownerPID)
    return WindowRestorationReport(saved: 0, restored: 0, disappeared: 0)
})
_ = try recovered.restoreAllWindows()
require(restoredOwners == [2])
require(!FileManager.default.fileExists(atPath: paths.windowSessionBackup.path))
print("PASS: release restores fresh snapshot only; archived geometry never replays")

let target = SavedWindow(ownerPID: 1, bundleIdentifier: "example", applicationName: "Example",
    windowID: 1, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow",
    ordinal: 0, displayUUID: "screen", frame: WindowSessionRect(x: 0, y: 0, width: 100, height: 100),
    relativeFrame: WindowSessionRect(x: 0, y: 0, width: 1, height: 1))
let other = SavedWindow(ownerPID: 1, bundleIdentifier: "example", applicationName: "Example",
    windowID: 2, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow",
    ordinal: 1, displayUUID: "screen", frame: target.frame, relativeFrame: target.relativeFrame)
let partial = WindowSessionBackup(ownerPID: 1, displays: [], windows: [target, other])
try WindowSessionBackupStore.write(partial, to: paths.windowSessionBackup)
let partialController = WindowSessionController(paths: paths, captureOperation: { partial }, restoreOperation: { backup in
    require(backup.windows.count == 2)
    return WindowRestorationReport(saved: 2, restored: 1, disappeared: 0,
        remaining: [other], failures: ["Example window 2"])
})
do { _ = try partialController.restoreAllWindows(); fatalError("partial result must fail") }
catch is WindowSessionError {}
let pending = try WindowSessionBackupStore.read(from: paths.windowSessionBackup)
require(pending.windows == [other])
require(pending.createdAt == partial.createdAt)
require(partialController.lastRestoredCount == 1)
let audit = try Data(contentsOf: paths.stateDirectory.appendingPathComponent("last-window-recovery.json"))
let fields = try JSONSerialization.jsonObject(with: audit) as! [String: Any]
require(fields["error"] != nil)
require((fields["restored"] as? Int) == 1)
print("PASS: partial restoration retains only failed windows and records failure readback")

// An orphaned recovery claim (active record gone) must still be reported as pending.
try FileManager.default.removeItem(at: paths.windowSessionBackup)
try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: 1, displays: [], windows: [target, other]),
    to: paths.stateDirectory.appendingPathComponent("window-session.json.restoring.999999"))
require(partialController.pendingRestoreCount == 2)
print("PASS: pending restore count includes an orphaned recovery claim")

// A window clamped by its application is a recorded deviation, not a failure: the
// snapshot must be retired and the shortfall must still be surfaced.
for claim in RecoveryClaimFiles.recoverable(in: paths.stateDirectory, prefix: "window-session.json.restoring.") {
    try FileManager.default.removeItem(at: claim)
}
try WindowSessionBackupStore.write(partial, to: paths.windowSessionBackup)
let clampedController = WindowSessionController(paths: paths, restoreOperation: { _ in
    WindowRestorationReport(saved: 2, restored: 2, disappeared: 0,
        deviations: ["Example window 1 clamped to (0, 30, 100, 100) instead of (0, 0, 100, 100)"])
})
_ = try clampedController.restoreAllWindows()
require(clampedController.recoveryWarning?.contains("clamped") == true)
require(!FileManager.default.fileExists(atPath: paths.windowSessionBackup.path))
print("PASS: clamped deviation is recorded without failing the restoration")
