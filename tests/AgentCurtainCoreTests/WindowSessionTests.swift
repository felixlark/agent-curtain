import XCTest
@testable import AgentCurtainCore

final class WindowSessionTests: XCTestCase {
    func testTransientMetadataUnavailabilityRetriesAndRecovers() throws {
        var samples = 0
        var waits = 0
        let resolved = try WindowApplicationMetadata.resolve(pid: getpid(), capturedAt: Date(),
            expectedBundleIdentifier: "example.app", application: { () -> String? in
                samples += 1
                return samples < 3 ? nil : "example.app"
            }, bundleIdentifier: { $0 }, wait: { waits += 1 })
        XCTAssertEqual(resolved, "example.app")
        XCTAssertEqual(samples, 3)
        XCTAssertEqual(waits, 2)
    }

    func testPersistentUnknownMetadataFailsWithoutReportingDisappearance() {
        var samples = 0
        XCTAssertThrowsError(try WindowApplicationMetadata.resolve(pid: getpid(), capturedAt: Date(),
            expectedBundleIdentifier: "example.app", application: { () -> String? in
                samples += 1
                return nil
            }, bundleIdentifier: { $0 }, attempts: 3, wait: {})) { error in
                XCTAssertTrue(error.localizedDescription.contains("metadata unavailable"))
            }
        XCTAssertEqual(samples, 3)
    }

    func testMetadataRetryRechecksPIDLifetimeAndRejectsIdentityMismatch() throws {
        let captured = Date()
        var samples = 0
        let reused = try WindowApplicationMetadata.resolve(pid: getpid(), capturedAt: captured,
            expectedBundleIdentifier: "example.app", startTime: {
                captured.addingTimeInterval(samples == 0 ? -1 : 1)
            }, application: { () -> String? in samples += 1; return nil },
            bundleIdentifier: { $0 }, wait: {})
        XCTAssertNil(reused)
        XCTAssertEqual(samples, 1)
        XCTAssertThrowsError(try WindowApplicationMetadata.resolve(pid: getpid(), capturedAt: captured,
            expectedBundleIdentifier: "example.app", application: { "other.app" },
            bundleIdentifier: { $0 }, wait: { XCTFail("must not retry a known different identity") }))
        XCTAssertThrowsError(try WindowApplicationMetadata.resolve(pid: getpid(), capturedAt: captured,
            expectedBundleIdentifier: "example.app", startTime: { nil }, application: { "example.app" },
            bundleIdentifier: { $0 }, wait: {}))
    }

    func testUnknownApplicationDoesNotBlockOtherApplicationTargets() {
        let first = window()
        var second = window()
        // A different identity represents another application's independently recoverable window.
        second = SavedWindow(ownerPID: 200, bundleIdentifier: "other.app", applicationName: "Other",
            windowID: 2, identifier: nil, title: "Other", role: first.role, subrole: first.subrole,
            ordinal: 0, displayUUID: first.displayUUID, frame: first.frame, relativeFrame: first.relativeFrame)
        let result = WindowApplicationSelection.resolve([first, second]) { saved in
            if saved.ownerPID == first.ownerPID {
                throw WindowSessionError.restoreFailures(["metadata unavailable"])
            }
            return true
        }
        XCTAssertEqual(result.surviving, [second])
        XCTAssertEqual(result.remaining, [first])
        XCTAssertEqual(result.disappeared, 0)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testSystemMenuBarsAndUnbackedDialogsAreNotDesktopRecoveryTargets() {
        XCTAssertFalse(WindowSessionPlanner.shouldManageWindow(bundleIdentifier: "com.apple.MenuBarAgent",
            subrole: "AXDialog", hasScreenWindow: true))
        XCTAssertFalse(WindowSessionPlanner.shouldManageWindow(bundleIdentifier: "com.openai.codex",
            subrole: "AXDialog", hasScreenWindow: false))
        XCTAssertTrue(WindowSessionPlanner.shouldManageWindow(bundleIdentifier: "com.example.app",
            subrole: "AXDialog", hasScreenWindow: true))
        XCTAssertTrue(WindowSessionPlanner.shouldManageWindow(bundleIdentifier: "com.google.Chrome",
            subrole: "AXStandardWindow", hasScreenWindow: false))
    }

    func testBackupStoreRoundTripsAtomicallyWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("window-session.json")
        let backup = WindowSessionBackup(
            ownerPID: 42,
            createdAt: Date(timeIntervalSince1970: 123.456),
            displays: [display(uuid: "external", x: -2560, y: -400, width: 2560, height: 1440)],
            windows: [window(windowID: 91, title: "Document", ordinal: 0)]
        )

        try WindowSessionBackupStore.write(backup, to: url)

        XCTAssertEqual(try WindowSessionBackupStore.read(from: url), backup)
        let mode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(mode & 0o777, 0o600)
        let claimed = try XCTUnwrap(WindowSessionBackupStore.claim(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try WindowSessionBackupStore.relinquish(claimed, to: url)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: url), backup)
    }

    func testRelinquishNeverOverwritesANewerOriginalBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-relinquish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("window-session.json")
        let claimed = directory.appendingPathComponent("window-session.json.restoring.999999")
        let older = WindowSessionBackup(ownerPID: 1, displays: [], windows: [])
        let newer = WindowSessionBackup(ownerPID: 2, displays: [], windows: [])
        try WindowSessionBackupStore.write(older, to: claimed)
        try WindowSessionBackupStore.write(newer, to: original)

        XCTAssertThrowsError(try WindowSessionBackupStore.relinquish(claimed, to: original))
        XCTAssertEqual(try WindowSessionBackupStore.read(from: original).ownerPID, 2)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: claimed).ownerPID, 1)
    }

    func testRecoverableClaimsExcludeLiveForeignRestorers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-claims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("window-session.json.restoring.\(getpid())")
        let dead = directory.appendingPathComponent("window-session.json.restoring.999999")
        let live = directory.appendingPathComponent("window-session.json.restoring.1")
        for file in [current, dead, live] { _ = FileManager.default.createFile(atPath: file.path, contents: Data()) }

        let names = Set(RecoveryClaimFiles.recoverable(
            in: directory,
            prefix: "window-session.json.restoring."
        ).map(\.lastPathComponent))

        XCTAssertTrue(names.contains(current.lastPathComponent))
        XCTAssertTrue(names.contains(dead.lastPathComponent))
        XCTAssertFalse(names.contains(live.lastPathComponent))
    }

    func testTargetFramePreservesExactNegativeCoordinatesWhenDisplayIsUnchanged() {
        let saved = window(
            frame: WindowSessionRect(x: -2390, y: -120, width: 1200, height: 900),
            display: WindowSessionRect(x: -2560, y: -400, width: 2560, height: 1440)
        )
        let target = display(uuid: "external", x: -2560, y: -400, width: 2560, height: 1440)

        XCTAssertEqual(WindowSessionPlanner.targetFrame(for: saved, on: target), saved.frame)
    }

    func testTargetFrameScalesRelativePlacementWhenDisplayResolutionChanges() {
        let saved = window(
            frame: WindowSessionRect(x: -1920, y: 100, width: 960, height: 540),
            display: WindowSessionRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let target = display(uuid: "external", x: 1512, y: -200, width: 2560, height: 1440)

        XCTAssertEqual(
            WindowSessionPlanner.targetFrame(for: saved, on: target),
            WindowSessionRect(x: 1512, y: -67, width: 1280, height: 720)
        )
    }

    func testWindowFrameFitsCurrentVisibleAreaWhenDockTakesSpace() {
        let target = WindowSessionRect(x: 0, y: 30, width: 2048, height: 1122)
        let visible = WindowSessionRect(x: 0, y: 30, width: 2048, height: 1048)
        XCTAssertEqual(
            WindowSessionPlanner.frameFittingVisibleArea(target, in: visible),
            WindowSessionRect(x: 0, y: 30, width: 2048, height: 1048)
        )
    }

    func testWindowIDWinsWhenTitlesAndOrderChange() {
        let saved = [
            window(windowID: 10, title: "old A", ordinal: 0),
            window(windowID: 20, title: "old B", ordinal: 1),
        ]
        let candidates = [
            WindowMatchCandidate(windowID: 20, identifier: nil, title: "new B", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "new A", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: candidates), [0: 1, 1: 0])
    }

    func testIdentifierAndTitleMatchMultipleWindowsWithoutDependingOnApplicationNameAlone() {
        let saved = [
            window(windowID: nil, identifier: "editor-1", title: "same", ordinal: 0),
            window(windowID: nil, identifier: "editor-2", title: "same", ordinal: 1),
        ]
        let candidates = [
            WindowMatchCandidate(windowID: nil, identifier: "editor-2", title: "same", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
            WindowMatchCandidate(windowID: nil, identifier: "editor-1", title: "same", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: candidates), [0: 1, 1: 0])
    }

    func testOrdinalFallbackRequiresSameWindowCount() {
        let saved = [window(windowID: nil, title: nil, ordinal: 0)]
        let sameCount = [
            WindowMatchCandidate(windowID: nil, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
        ]
        let extraWindow = sameCount + [
            WindowMatchCandidate(windowID: nil, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: sameCount), [0: 0])
        XCTAssertTrue(WindowSessionPlanner.matches(saved: saved, candidates: extraWindow).isEmpty)
    }

    func testWindowIDIsIgnoredAfterApplicationProcessChanges() {
        let saved = [window(windowID: 10, title: "old title", ordinal: 0)]
        let reused = [
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "different title",
                role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertTrue(WindowSessionPlanner.matches(
            saved: saved,
            candidates: reused,
            trustWindowIDs: false
        ).isEmpty)
    }

    func testWindowIDDoesNotOverrideIncompatibleWindowRole() {
        let saved = [window(windowID: 10, title: "Document", ordinal: 0)]
        let candidate = [
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "Document",
                role: "AXSheet", subrole: "AXUnknown", ordinal: 0),
        ]

        XCTAssertTrue(WindowSessionPlanner.matches(saved: saved, candidates: candidate).isEmpty)
    }

    func testRestartCannotMatchByOrdinalEvenWhenWindowCountMatches() {
        let saved = [window(windowID: 10, title: "old", ordinal: 0)]
        let candidate = WindowMatchCandidate(windowID: 10, identifier: nil, title: "new",
            role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0)
        XCTAssertTrue(WindowSessionPlanner.matches(saved: saved, candidates: [candidate], trustWindowIDs: false).isEmpty)
    }

    func testCaptureIncludesInternalAndSpanningWindows() {
        let internalDisplay = WindowDisplayGeometry(uuid: "internal", bounds: .init(x: 0, y: 1440, width: 1512, height: 982), isBuiltin: true)
        let external = WindowDisplayGeometry(uuid: "external", bounds: .init(x: -2048, y: 568, width: 2048, height: 1152), isBuiltin: false)
        XCTAssertEqual(WindowSessionPlanner.captureDisplay(for: .init(x: 0, y: 1473, width: 1512, height: 875), displays: [internalDisplay, external])?.uuid, "internal")
        XCTAssertEqual(WindowSessionPlanner.captureDisplay(for: .init(x: -100, y: 1720, width: 300, height: 300), displays: [internalDisplay, external])?.uuid, "internal")
        XCTAssertNil(WindowSessionPlanner.captureDisplay(for: .init(x: 9999, y: 9999, width: 30, height: 30), displays: [internalDisplay, external]))
    }

    func testKernelProcessStartTimeForLiveProcessAndInvalidPID() throws {
        let captured = Date()
        let start = try XCTUnwrap(ProcessStartTime.read(pid: getpid()))
        XCTAssertTrue(WindowSessionPlanner.isOriginalProcess(launchDate: start, capturedAt: captured))
        XCTAssertFalse(WindowSessionPlanner.isOriginalProcess(launchDate: start, capturedAt: start.addingTimeInterval(-1)))
        XCTAssertNil(ProcessStartTime.read(pid: -1))
        XCTAssertNil(ProcessStartTime.read(pid: Int32.max))
    }

    func testProcessLifetimeRejectsReusedPIDAndUnknownLaunchTime() {
        let captured = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(WindowSessionPlanner.isOriginalProcess(launchDate: Date(timeIntervalSince1970: 99), capturedAt: captured))
        XCTAssertFalse(WindowSessionPlanner.isOriginalProcess(launchDate: Date(timeIntervalSince1970: 101), capturedAt: captured))
        XCTAssertFalse(WindowSessionPlanner.isOriginalProcess(launchDate: nil, capturedAt: captured))
    }

    func testNewSessionPreservesFailedAndCorruptRecordsWithoutReplayingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("window-session.json")
        let claim = directory.appendingPathComponent("window-session.json.restoring.999999")
        let oldBytes = Data("corrupt legacy record".utf8)
        try oldBytes.write(to: original)
        let old = WindowSessionBackup(ownerPID: 1, displays: [], windows: [window()])
        try WindowSessionBackupStore.write(old, to: claim)
        let fresh = WindowSessionBackup(ownerPID: 2, displays: [], windows: [])
        let archive = try XCTUnwrap(WindowSessionBackupStore.beginSession(fresh, at: original))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(original.lastPathComponent)), oldBytes)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: archive.appendingPathComponent(claim.lastPathComponent)), old)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: original), fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claim.path))
        XCTAssertTrue(RecoveryClaimFiles.recoverable(in: directory, prefix: "window-session.json.restoring.").isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testArchiveFailureKeepsOldActiveRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("window-session.json")
        let old = WindowSessionBackup(ownerPID: 1, displays: [], windows: [])
        try WindowSessionBackupStore.write(old, to: original)
        try Data().write(to: directory.appendingPathComponent("window-history"))
        XCTAssertThrowsError(try WindowSessionBackupStore.beginSession(
            WindowSessionBackup(ownerPID: 2, displays: [], windows: []), at: original))
        XCTAssertEqual(try WindowSessionBackupStore.read(from: original), old)
    }

    func testNewSessionRefusesLiveRecoveryClaim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claim = directory.appendingPathComponent("window-session.json.restoring.1")
        try Data().write(to: claim)
        XCTAssertThrowsError(try WindowSessionBackupStore.beginSession(
            WindowSessionBackup(ownerPID: 2, displays: [], windows: []),
            at: directory.appendingPathComponent("window-session.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claim.path))
    }

    private func display(uuid: String, x: Double, y: Double, width: Double, height: Double) -> WindowDisplayGeometry {
        WindowDisplayGeometry(
            uuid: uuid,
            bounds: WindowSessionRect(x: x, y: y, width: width, height: height),
            isBuiltin: false
        )
    }

    private func window(
        windowID: UInt32? = 1,
        identifier: String? = nil,
        title: String? = "Document",
        ordinal: Int = 0,
        frame: WindowSessionRect = WindowSessionRect(x: -2400, y: -300, width: 1000, height: 700),
        display: WindowSessionRect = WindowSessionRect(x: -2560, y: -400, width: 2560, height: 1440)
    ) -> SavedWindow {
        SavedWindow(
            ownerPID: 100,
            bundleIdentifier: "example.app",
            applicationName: "Example",
            windowID: windowID,
            identifier: identifier,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            ordinal: ordinal,
            displayUUID: "external",
            frame: frame,
            relativeFrame: WindowSessionPlanner.relativeFrame(frame, in: display)
        )
    }
}
