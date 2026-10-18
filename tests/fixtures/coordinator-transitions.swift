import AgentCurtainCore
import Foundation

struct FixtureFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message: message) }
}

func pump(until condition: () -> Bool, _ message: String, timeout: TimeInterval = 3) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw FixtureFailure(message: "timed out: \(message)") }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

final class Gate {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func pause() throws {
        entered.signal()
        guard release.wait(timeout: .now() + 8) == .success else {
            throw FixtureFailure(message: "fixture gate timed out")
        }
    }

    func awaitEntry(_ label: String) throws {
        try pump(until: { self.entered.wait(timeout: .now()) == .success }, label)
    }
}

final class Scenario {
    static var current: Scenario!
    let dim = Gate()
    let restore = Gate()
    var blockerFails = false
    var restoreFails = false
    var windowRestoreFails = false
    var prepared = false
    var startupDisplayFails = false
    var startupBrightnessFails = false
    var startupDisplayCalls = 0
    var startupBrightnessCalls = 0
    var startupWindowCalls = 0
    var activeCountFails = false
    // The following observations are accessed only by main-thread fake UI/input APIs.
    var presentations: [BannerController.Presentation] = []
    var starts = 0
    var marker: Int64?
    var paths: CurtainPaths!
    var stops = 0
    var reconciliations = 0
    var screenChange: (() -> Void)?
}

final class InputBlocker {
    let scenario = Scenario.current!
    var onReleaseHotkey: (() -> Void)?
    static func isAccessibilityTrusted(prompt: Bool) -> Bool { true }
    func start(configuration: CurtainConfiguration, injectionMarker: Int64?) throws {
        precondition(Thread.isMainThread)
        scenario.starts += 1
        scenario.marker = injectionMarker
        if scenario.blockerFails { throw FixtureFailure(message: "fixture blocker start failed") }
    }
    func stop() { precondition(Thread.isMainThread); scenario.stops += 1 }
    func update(configuration: CurtainConfiguration) {}
    func counters() -> (blocked: UInt64, allowed: UInt64, allowedPIDs: Int, deniedPIDs: Int) { (0, 0, 1, 1) }
}

final class BannerController {
    enum Presentation: Equatable { case enabling, protected, markerProtected, disabling, released, failed }
    let scenario = Scenario.current!
    var onScreensChanged: (() -> Void)? {
        didSet { scenario.screenChange = onScreensChanged }
    }
    func show(_ presentation: Presentation = .protected) {
        precondition(Thread.isMainThread)
        scenario.presentations.append(presentation)
    }
    func finishRelease() { show(.released) }
    func hide() {}
}

final class BrightnessController {
    let scenario: Scenario
    init(paths: CurtainPaths) { scenario = Scenario.current! }
    var lastRecoveryWarning: String?
    func recoverStaleBackup() throws {}
    func dimAllDisplays(displaySessionBackup: URL, isCancelled: () -> Bool = { false }) throws -> Int {
        precondition(!Thread.isMainThread)
        try scenario.dim.pause()
        if isCancelled() { throw CancellationError() }
        return 4
    }
    func restoreAllDisplays() throws {
        precondition(!Thread.isMainThread)
        if !scenario.prepared {
            scenario.startupBrightnessCalls += 1
            if scenario.startupBrightnessFails { throw FixtureFailure(message: "startup brightness failed") }
            return
        }
        try scenario.restore.pause()
        if scenario.restoreFails { throw FixtureFailure(message: "fixture restore failed") }
    }
    func dimNewDisplays() throws -> Int {
        scenario.reconciliations += 1
        return 4
    }
}

final class DisplaySessionController {
    let scenario: Scenario
    init(paths: CurtainPaths) { scenario = Scenario.current! }
    func recoverStaleBackup() throws {}
    func refreshBackendDiagnostics() {}
    func currentActiveDisplayCount() throws -> Int {
        if scenario.activeCountFails { throw FixtureFailure(message: "fixture active display count failed") }
        return 4
    }
    func capture() throws -> Int { 4 }
    func disconnectExternalDisplays(isCancelled: @Sendable () -> Bool = { false }) throws -> Int {
        if isCancelled() { throw CancellationError() }
        return 4
    }
    func reconcileNewDisplays() throws -> Int { 4 }
    func restoreAllDisplays() throws {
        scenario.startupDisplayCalls += 1
        if scenario.startupDisplayFails { throw FixtureFailure(message: "startup display failed") }
    }
    var pendingRestoreCount: Int { 0 }
    var displayBackendStatus: String? { "system-spi" }
    var betterDisplayProStatus: String { "off" }
    var privateDisplaySPIStatus: String { "available" }
}

final class WindowSessionController {
    let scenario: Scenario
    init(paths: CurtainPaths) { scenario = Scenario.current! }
    var recoveryWarning: String?
    var lastCapturedCount = 0
    var lastRestoredCount = 0
    func capture() throws -> Int { 3 }
    func restoreAllWindows() throws -> WindowRestorationReport? {
        if !scenario.prepared { scenario.startupWindowCalls += 1 }
        if scenario.windowRestoreFails { throw FixtureFailure(message: "window restoration refused") }
        return nil
    }
    func recoverStaleBackup() throws {}
    var pendingRestoreCount: Int { 0 }
}

func runScenario(_ name: String, blockerFails: Bool = false, restoreFails: Bool = false,
                 body: (CurtainCoordinator, Scenario) throws -> Void) throws {
    let scenario = Scenario()
    scenario.blockerFails = blockerFails
    scenario.restoreFails = restoreFails
    Scenario.current = scenario
    let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent("curtain-transition-home-\(UUID().uuidString)")
    defer {
        scenario.dim.release.signal()
        scenario.restore.release.signal()
        try? FileManager.default.removeItem(at: temporaryHome)
    }
    let paths = CurtainPaths(home: temporaryHome)
    scenario.paths = paths
    let coordinator = CurtainCoordinator(paths: paths)
    var prepared = false
    coordinator.prepare { prepared = true }
    try pump(until: { prepared }, "prepare \(name)")
    try require(coordinator.phase == .open, "preparation must finish open")
    scenario.prepared = true
    try body(coordinator, scenario)
}

func startupRecoveryContinuesAfterDisplayFailure() throws {
    let scenario = Scenario()
    scenario.startupDisplayFails = true
    Scenario.current = scenario
    let temporaryHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("curtain-startup-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let paths = CurtainPaths(home: temporaryHome)
    scenario.paths = paths
    let coordinator = CurtainCoordinator(paths: paths)
    var prepared = false
    coordinator.prepare { prepared = true }
    try pump(until: { prepared }, "startup display failure")

    try require(scenario.startupDisplayCalls == 1, "startup must attempt display recovery")
    try require(scenario.startupBrightnessCalls == 1, "display failure cannot skip brightness recovery")
    try require(scenario.startupWindowCalls == 0, "window recovery must wait for display topology")
    try require(coordinator.lastError?.contains("startup display failed") == true,
        "startup must report display recovery failure")
}

func startupRecoveryContinuesAfterBrightnessFailure() throws {
    let scenario = Scenario()
    scenario.startupBrightnessFails = true
    Scenario.current = scenario
    let temporaryHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("curtain-startup-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let paths = CurtainPaths(home: temporaryHome)
    scenario.paths = paths
    let coordinator = CurtainCoordinator(paths: paths)
    var prepared = false
    coordinator.prepare { prepared = true }
    try pump(until: { prepared }, "startup brightness failure")

    try require(scenario.startupDisplayCalls == 1, "startup must attempt display recovery")
    try require(scenario.startupBrightnessCalls == 1, "startup must attempt brightness recovery")
    try require(scenario.startupWindowCalls == 1, "brightness failure cannot skip window recovery")
    try require(coordinator.lastError?.contains("startup brightness failed") == true,
        "startup must report brightness recovery failure")
}

func normalTransitions() throws {
    try runScenario("normal transitions") { coordinator, scenario in
        var draw: ControlResponse?
        coordinator.draw { draw = $0 }
        try require(coordinator.phase == .drawing, "draw must enter drawing synchronously")
        try require(scenario.presentations == [.enabling], "enabling must be visible before hardware completes")
        try require(scenario.starts == 0 && draw == nil, "protection cannot be reported before dim completes")
        try scenario.dim.awaitEntry("normal dim")
        scenario.dim.release.signal()
        try pump(until: { draw != nil }, "normal draw completion")
        try require(draw?.ok == true && coordinator.phase == .drawn, "successful dim and blocker must finish drawn")
        try require(scenario.starts == 1 && scenario.presentations.last == .protected, "protected must follow blocker success")
        try require(coordinator.displayCount == 4 && coordinator.since != nil, "drawn state metadata")

        var opened: ControlResponse?
        coordinator.open { opened = $0 }
        try require(coordinator.phase == .opening && scenario.presentations.last == .disabling, "disabling must be immediate")
        try require(scenario.stops == 1 && opened == nil, "input must release before brightness restoration completes")
        try scenario.restore.awaitEntry("normal restore")
        scenario.restore.release.signal()
        try pump(until: { opened != nil }, "normal open completion")
        try require(opened?.ok == true && coordinator.phase == .open, "successful restoration must finish open")
        try require(scenario.presentations == [.enabling, .protected, .disabling, .released], "normal presentation order")
        try require(coordinator.displayCount == 0 && coordinator.activeDisplayCount == 4 && coordinator.since == nil && coordinator.lastError == nil, "open state metadata")
    }
}

func cancellationDuringDim() throws {
    try runScenario("cancel during dim") { coordinator, scenario in
        var draw: ControlResponse?
        var opened: ControlResponse?
        coordinator.draw { draw = $0 }
        try scenario.dim.awaitEntry("cancel dim")
        coordinator.open { opened = $0 }
        try require(scenario.presentations.last == .disabling && coordinator.phase == .opening, "cancel must immediately show disabling")
        scenario.dim.release.signal()
        try scenario.restore.awaitEntry("cancel restore")
        scenario.restore.release.signal()
        try pump(until: { draw != nil && opened != nil }, "cancel callbacks")
        try require(draw?.ok == false && draw?.error != nil, "cancelled draw must return an error")
        try require(opened?.ok == true && coordinator.phase == .open, "cancel must complete open request")
        try require(scenario.starts == 0 && !scenario.presentations.contains(.protected), "cancelled operation cannot start blocker or advertise protection")
        try require(scenario.presentations == [.enabling, .disabling, .released], "cancel presentation order")
    }
}

func rollbackConcurrentRequests(restoreFails: Bool) throws {
    try runScenario("blocker rollback", blockerFails: true, restoreFails: restoreFails) { coordinator, scenario in
        var draw: ControlResponse?
        var opened: ControlResponse?
        var quitOpened: ControlResponse?
        coordinator.draw { draw = $0 }
        try scenario.dim.awaitEntry("rollback dim")
        scenario.dim.release.signal()
        try scenario.restore.awaitEntry("blocker failure restore")
        try require(coordinator.phase == .opening && scenario.presentations.last == .disabling, "blocker failure must begin rollback")
        coordinator.open { opened = $0 }
        // AppDelegate's quit path first calls coordinator.open and waits for this callback.
        coordinator.open { quitOpened = $0 }
        try require(opened == nil && quitOpened == nil, "concurrent requests must await rollback")
        scenario.restore.release.signal()
        try pump(until: { draw != nil && opened != nil && quitOpened != nil }, "rollback must drain open and quit callbacks")
        try require(draw?.ok == false, "blocker failure must fail original draw")
        try require(opened?.ok == !restoreFails && quitOpened?.ok == !restoreFails, "waiting requests must report restoration result")
        try require(coordinator.phase == .open && coordinator.displayCount == 0 && coordinator.since == nil, "rollback terminal state")
        try require(!scenario.presentations.contains(.protected) && scenario.presentations.last == .failed, "failed protection must never show protected")
        try require(coordinator.lastError?.contains("fixture blocker start failed") == true, "menu must preserve blocker failure")
        if restoreFails {
            try require(coordinator.lastError?.contains("fixture restore failed") == true, "menu must include restoration failure")
            try require(draw?.error?.contains("fixture restore failed") == true, "draw response must include restoration failure")
            var status: ControlResponse?
            coordinator.handle(.status) { status = $0 }
            try require(status?.ok == false && status?.error != nil, "status must report incomplete recovery")
            scenario.restoreFails = false
            var retried: ControlResponse?
            coordinator.open { retried = $0 }
            try scenario.restore.awaitEntry("retry failed restore")
            scenario.restore.release.signal()
            try pump(until: { retried != nil }, "retry completion")
            try require(retried?.ok == true && coordinator.lastError == nil, "open must retry failed recovery")
        }
    }
}

func openingCancelsPendingScreenReconciliation() throws {
    try runScenario("cancel pending screen reconciliation") { coordinator, scenario in
        var draw: ControlResponse?
        coordinator.draw { draw = $0 }
        try scenario.dim.awaitEntry("reconciliation draw")
        scenario.dim.release.signal()
        try pump(until: { draw?.ok == true }, "reconciliation draw completion")

        scenario.screenChange?()
        var opened: ControlResponse?
        coordinator.open { opened = $0 }
        try scenario.restore.awaitEntry("reconciliation restore")
        scenario.restore.release.signal()
        try pump(until: { opened?.ok == true }, "reconciliation open completion")
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.6))

        try require(scenario.reconciliations == 0, "open must cancel the debounced reconciliation")
        try require(coordinator.lastError == nil, "cancelled reconciliation cannot pollute open status")
    }
}

func windowFailureDoesNotLeaveStaleDisplayCountOrBlockNextDraw() throws {
    try runScenario("window recovery isolation") { coordinator, scenario in
        var drawn: ControlResponse?
        coordinator.draw { drawn = $0 }
        try scenario.dim.awaitEntry("first draw")
        scenario.dim.release.signal()
        try pump(until: { drawn != nil }, "first draw done")
        try require(coordinator.activeDisplayCount == 1, "drawn topology")
        scenario.windowRestoreFails = true
        var opened: ControlResponse?
        coordinator.open { opened = $0 }
        try scenario.restore.awaitEntry("release with failed window recovery")
        scenario.restore.release.signal()
        try pump(until: { opened != nil }, "failed window recovery done")
        try require(opened?.ok == false, "window failure remains visible")
        try require(opened?.activeDisplays == 4, "actual display count survives window error")
        drawn = nil
        coordinator.draw { drawn = $0 }
        try scenario.dim.awaitEntry("next draw")
        scenario.dim.release.signal()
        try pump(until: { drawn != nil }, "next draw done")
        try require(drawn?.ok == true && coordinator.phase == .drawn, "window failure cannot poison protection")
    }
}


func activeDisplayCountFailureDoesNotFailCompletedRecovery() throws {
    try runScenario("active display count warning") { coordinator, scenario in
        var drawn: ControlResponse?
        coordinator.draw { drawn = $0 }
        try scenario.dim.awaitEntry("count failure draw")
        scenario.dim.release.signal()
        try pump(until: { drawn?.ok == true }, "count failure draw completion")

        scenario.activeCountFails = true
        var opened: ControlResponse?
        coordinator.open { opened = $0 }
        try scenario.restore.awaitEntry("count failure restore")
        scenario.restore.release.signal()
        try pump(until: { opened != nil }, "count failure open completion")

        try require(opened?.ok == true, "an unreadable display count cannot fail a completed recovery")
        try require(opened?.activeDisplays == 4, "the drawn display count survives the failed read")
        try require(coordinator.lastError == nil, "diagnostics must not become an operation error")
        try require(coordinator.recoveryWarning?.contains("active displays") == true,
            "the failed read is still surfaced as a warning")
    }
}

func markerTransitions() throws {
    try runScenario("marker transitions") { coordinator, scenario in
        let marker = Int64.min + 123
        var drawn: ControlResponse?
        coordinator.handle(.draw(duration: nil, injectionMarker: marker)) { drawn = $0 }
        try scenario.dim.awaitEntry("marker draw")
        scenario.dim.release.signal()
        try pump(until: { drawn != nil }, "marker drawn")
        try require(drawn?.ok == true && coordinator.phase == .drawn, "marker draw finishes drawn")
        try require(drawn?.injectionMarker == marker && scenario.marker == marker, "response and blocker use same marker")
        try require(coordinator.statusSummary.contains("屏幕关闭·仅放行注入") && scenario.presentations.last == .markerProtected, "menu and banner marker wording")
        let file = scenario.paths.injectionMarker
        let text = try String(contentsOf: file, encoding: .utf8)
        try require(Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) == marker, "marker persisted exactly")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "marker mode is 0600")
        try require(FileManager.default.fileExists(atPath: scenario.paths.expectation.path), "expectation remains recorded")
        var repeated: ControlResponse?
        coordinator.draw(injectionMarker: 77) { repeated = $0 }
        try require(repeated?.injectionMarker == marker, "repeated on preserves current session")
        var opened: ControlResponse?
        coordinator.open { opened = $0 }
        try require(coordinator.injectionMarker == nil && !FileManager.default.fileExists(atPath: file.path), "open revokes marker immediately")
        try require(!FileManager.default.fileExists(atPath: scenario.paths.expectation.path), "open clears expectation")
        try scenario.restore.awaitEntry("marker open")
        scenario.restore.release.signal()
        try pump(until: { opened != nil }, "marker open complete")
        try require(opened?.ok == true && opened?.injectionMarker == nil, "open response has no marker")
    }
    try runScenario("marker rollback", blockerFails: true) { coordinator, scenario in
        var drawn: ControlResponse?
        coordinator.draw(injectionMarker: 77) { drawn = $0 }
        try scenario.dim.awaitEntry("marker rollback draw")
        scenario.dim.release.signal()
        try scenario.restore.awaitEntry("marker rollback restore")
        try require(coordinator.injectionMarker == nil && !FileManager.default.fileExists(atPath: scenario.paths.injectionMarker.path), "failed draw revokes marker")
        scenario.restore.release.signal()
        try pump(until: { drawn != nil }, "marker rollback complete")
        try require(drawn?.ok == false, "failed blocker must fail marker draw")
    }
}

precondition(Thread.isMainThread)
let cases: [(String, () throws -> Void)] = [
    ("marker draw/open, secure file, rollback and wording", markerTransitions),
    ("window error preserves actual display count and allows next draw", windowFailureDoesNotLeaveStaleDisplayCountOrBlockNextDraw),
    ("startup display failure still restores brightness", startupRecoveryContinuesAfterDisplayFailure),
    ("startup brightness failure still restores windows", startupRecoveryContinuesAfterBrightnessFailure),
    ("normal enabling/protected/disabling/released order", normalTransitions),
    ("cancel during dim", cancellationDuringDim),
    ("blocker failure with successful rollback drains open/quit", { try rollbackConcurrentRequests(restoreFails: false) }),
    ("blocker failure with failed rollback drains open/quit", { try rollbackConcurrentRequests(restoreFails: true) }),
    ("open cancels pending screen reconciliation", openingCancelsPendingScreenReconciliation),
    ("active display count failure is a warning", activeDisplayCountFailureDoesNotFailCompletedRecovery),
]
var failures = 0
for (name, test) in cases {
    do { try test(); print("PASS: \(name)") }
    catch { failures += 1; print("FAIL: \(name): \(error.localizedDescription)") }
}
print("coordinator-transition-tests: \(cases.count - failures)/\(cases.count) passed")
exit(failures == 0 ? 0 : 1)
