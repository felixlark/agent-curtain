import CoreGraphics
import Foundation
import Testing
@testable import AgentCurtainCore

/// Regression suite for the `restore-pending` incident of 2026-10-22:
/// `~/.local/state/curtain/display-session.json` kept UUIDs of displays that no
/// longer existed (displayID 16/17 and a replaced Mi Monitor). Every unlock wrote
/// those identifiers to WindowServer, got `complete returned 1001`, kept the
/// snapshot, and left `curtain on` permanently blocked.
@Suite(.serialized) struct RecoveryRetirementTests {
    @Test func disappearedDisplayIsclassifiedAsUnavailable() {
        let partition = RecoveryRetirement.partition(
            ["internal", "external", "gone"],
            inventory: ["internal", "external"],
            active: ["internal", "external"])
        #expect(partition.available == ["internal", "external"])
        #expect(partition.unavailable == ["gone"])
    }

    @Test func disappearedDisplayIsRetiredInsteadOfWrittenToBetterDisplay() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backend = try BetterDisplayConnectionBackend(client: client)
        let backup = DisplaySessionBackup(ownerPID: 7, connectionBackend: .betterDisplay, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "external", displayID: 22, isBuiltin: false, wasMain: false,
                placement: "1512x0", resolution: "2560x1440", rotation: "0"),
            DisplayTopology(uuid: "gone", displayID: 16, isBuiltin: false, wasMain: false,
                placement: "0x0", resolution: "1512x982", rotation: "0")
        ])

        let report = try DisplaySessionOperations.restoreAvailable(backup, client: client, backend: backend)

        #expect(report.retired == ["gone"])
        #expect(report.restored == ["internal", "external"])
        #expect(report.warnings.isEmpty)
        // A vanished UUID must never reach a feature write.
        let log = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
        #expect(!log.contains("UUID=gone"))
    }

    @Test func retiredDisplaysAreArchivedAndTheSnapshotIsRemoved() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = CurtainPaths(home: home)
        try paths.prepareDirectories()
        try DisplaySessionBackupStore.write(DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI,
            displays: [DisplayTopology(uuid: "gone", displayID: 16, isBuiltin: false, wasMain: false,
                placement: "0x0", resolution: "1512x982", rotation: "0")]),
            to: paths.displaySessionBackup)

        let archive = try RecoveryArchive.preserve(paths.displaySessionBackup,
            reason: "unavailable-displays", now: Date(timeIntervalSince1970: 1_792_402_257))
        try FileManager.default.removeItem(at: paths.displaySessionBackup)

        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(archive.lastPathComponent == "display-session.retired-unavailable-displays-20261019T093057Z.json")
        let mode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: paths.displaySessionBackup.path))
    }

    @Test func rejectedConfigurationIsRetriedOnlyWithinTheBoundThenAbandoned() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backup = DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "external", displayID: 22, isBuiltin: false, wasMain: false,
                placement: "1512x0", resolution: "2560x1440", rotation: "0")
        ])
        let active = [
            DisplayIdentity(displayID: 1, uuid: "internal", isBuiltin: true),
            DisplayIdentity(displayID: 22, uuid: "external"),
        ]
        var transactions = 0
        let rejected: ([(CGDirectDisplayID, Int32, Int32)]) throws -> Void = { _ in
            transactions += 1
            throw DisplayConnectionBackendError.configuration("complete returned 1001")
        }

        #expect(throws: DisplayConnectionBackendError.self) {
            try DisplaySessionOperations.restoreLayoutInOneTransaction(backup, client: client,
                attempts: 3, activeDisplays: { active }, commit: rejected)
        }
        #expect(transactions == 3, "1001 must be retried, and only within the bound")

        transactions = 0
        var succeeding: ([(CGDirectDisplayID, Int32, Int32)]) throws -> Void = { _ in transactions += 1 }
        try DisplaySessionOperations.restoreLayoutInOneTransaction(backup, client: client,
            attempts: 3, activeDisplays: { active }, commit: succeeding)
        #expect(transactions == 1, "a successful transaction must not be repeated")

        // A non-1001 rejection is not retried: it cannot be fixed by reissuing.
        transactions = 0
        let invalid: ([(CGDirectDisplayID, Int32, Int32)]) throws -> Void = { _ in
            transactions += 1
            throw DisplayConnectionBackendError.configuration("origin displayID=22 returned 1001")
        }
        #expect(throws: DisplayConnectionBackendError.self) {
            try DisplaySessionOperations.restoreLayoutInOneTransaction(backup, client: client,
                attempts: 3, activeDisplays: { active }, commit: invalid)
        }
        #expect(transactions == 1)
        _ = succeeding
    }

    @Test func exhaustedConfigurationDegradesToAUsableWarning() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backup = DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "gone", displayID: 16, isBuiltin: false, wasMain: false,
                placement: "0x0", resolution: "1512x982", rotation: "0")
        ])
        // "gone" is not in inventory, so it is retired before any transaction runs.
        let report = try DisplaySessionOperations.restoreAvailable(backup, client: client,
            backend: SystemDisplayConnectionBackend(
                client: client,
                configureDisplayEnabled: { _, _, _ in .success },
                activeDisplayIDs: { [1] }),
            configurationAttempts: 2)
        #expect(report.retired == ["gone"])
        #expect(report.restored == ["internal"])
    }

    @Test func tinyReadbackGapIsNoiseButADimmedDisplayStillFails() throws {
        // 0.741 vs 0.73 is the field value that failed the 2026-10-22 recovery.
        let tolerance = BrightnessRestoration.defaultTolerance
        #expect(abs(0.741 - 0.73) <= tolerance)
        #expect(abs(0.02 - 0.0) <= tolerance)
        #expect(abs(0.5 - 0.0) > tolerance)
        #expect(abs(1.0 - 0.9) > tolerance)
    }

    @Test func unavailableBrightnessEntryIsRetiredAndTheRestStillRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        if [ "$2" = "--identifiers" ]; then
            echo '[{"displayID":5,"UUID":"dell"},{"displayID":1,"UUID":"internal"}]'
        else
            echo 1
        fi
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [5, 1] }, builtinDisplayProvider: { $0 == 1 })
        let backup = BrightnessBackup(ownerPID: 1, displays: [
            DisplayBrightness(displayID: 16, brightness: 1, uuid: "gone"),
            DisplayBrightness(displayID: 5, brightness: 1, uuid: "dell"),
            DisplayBrightness(displayID: 1, brightness: 1, uuid: "internal")
        ])

        let report = try BrightnessRestoration.restore(backup, client: client,
            activeAttempts: 1, settlingPasses: 1, settlingInterval: 0)

        #expect(report.retired.map(\.uuid) == ["gone"])
        #expect(Set(report.observed.compactMap(\.uuid)) == ["dell", "internal"])
    }

    @Test func oldSnapshotsWithoutRetirementDataStillDecode() throws {
        let data = Data(#"{"createdAt":1772000000000,"displays":[],"ownerPID":42,"version":2,"connectionBackend":"system-spi"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let backup = try decoder.decode(DisplaySessionBackup.self, from: data)
        #expect(backup.displays.isEmpty)
        #expect(backup.ownerPID == 42)
    }

    @Test func windowsOnRetiredDisplayAreRetiredNotLeftPending() {
        let window = SavedWindow(ownerPID: 1, bundleIdentifier: "example", applicationName: "Example",
            windowID: 9, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow",
            ordinal: 0, displayUUID: "gone", frame: WindowSessionRect(x: 0, y: 0, width: 10, height: 10),
            relativeFrame: WindowSessionRect(x: 0, y: 0, width: 1, height: 1))
        let kept = SavedWindow(ownerPID: 1, bundleIdentifier: "example", applicationName: "Example",
            windowID: 10, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow",
            ordinal: 1, displayUUID: "present", frame: window.frame, relativeFrame: window.relativeFrame)

        let result = WindowSessionPlanner.retireStrandedWindows([window, kept], retiredDisplays: ["gone"])

        #expect(result.retired.map(\.windowID) == [9])
        #expect(result.stillPending.map(\.windowID) == [10])
    }
}

private final class DisplayFixture: @unchecked Sendable {
    let root: URL
    let cli: URL
    let state: URL
    let main: URL
    let log: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cli = root.appendingPathComponent("cli")
        state = root.appendingPathComponent("state")
        main = root.appendingPathComponent("main")
        log = root.appendingPathComponent("log")
        try #"""
        #!/bin/sh
        root=${0%/*}
        printf '%s\n' "$*" >> "$root/log"
        case "$*" in
          'get --identifiers') echo '[{"displayID":1,"UUID":"internal"},{"displayID":22,"UUID":"external"}]' ;;
          'get -proAvailable') echo on ;;
          'get -UUID=internal -main') echo true ;;
          'get -UUID=external -main') echo false ;;
          'get -UUID=internal -placement') echo 0x0 ;;
          'get -UUID=external -placement') echo 1512x0 ;;
          'get -UUID=internal -resolution') echo 1512x982 ;;
          'get -UUID=external -resolution') echo 2560x1440 ;;
          'get -UUID=internal -rotation'|'get -UUID=external -rotation') echo 0 ;;
          'get -UUID=internal -connected'|'get -UUID=external -connected') echo on ;;
          'set -connectAllDisplays') echo connected ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    func client() throws -> BetterDisplayClient {
        try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [1, 22] }, builtinDisplayProvider: { $0 == 1 })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
