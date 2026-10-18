import Foundation
import Testing
@testable import AgentCurtainCore

@Suite struct BrightnessRestorationTests {
    @Test func reconciliationRedimsReappearingDisplayAndRefreshesChangedID() throws {
        let existing = [
            DisplayBrightness(displayID: 7, brightness: 0.6, uuid: "same-id"),
            DisplayBrightness(displayID: 8, brightness: 0.7, uuid: "changed-id"),
        ]
        let active = [
            DisplayIdentity(displayID: 7, uuid: "same-id"),
            DisplayIdentity(displayID: 18, uuid: "changed-id"),
        ]

        let plan = try BrightnessRestoration.reconciliationPlan(
            existing: existing,
            active: active,
            currentBrightness: { $0 == 7 ? 0.8 : 0 }
        )

        #expect(plan.updated.map(\.displayID) == [7, 18])
        #expect(plan.toDim.map(\.displayID) == [7, 18])
        #expect(plan.updated.map(\.brightness) == [0.6, 0.7])
    }

    @Test func followsUUIDAfterDisplayIDChanges() throws {
        let saved = DisplayBrightness(displayID: 3, brightness: 0.8, uuid: "dell")
        let active = [DisplayIdentity(displayID: 3, uuid: "other"), DisplayIdentity(displayID: 5, uuid: "dell")]
        #expect(try BrightnessRestoration.target(for: saved, active: active) == 5)
    }

    @Test func neverFallsBackToReusedIDWhenUUIDMissing() {
        #expect(throws: (any Error).self) {
            try BrightnessRestoration.target(for: DisplayBrightness(displayID: 3, brightness: 0.8, uuid: "dell"),
                active: [DisplayIdentity(displayID: 3, uuid: "other")])
        }
    }

    @Test func brightnessComponentsSurviveBackupAndDisplayIDRemap() throws {
        let saved = DisplayBrightness(displayID: 8, brightness: 0.6, uuid: "changed",
            hardwareBrightness: 0.75, softwareBrightness: 0.8)
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(DisplayBrightness.self, from: encoded) == saved)
        let plan = try BrightnessRestoration.reconciliationPlan(existing: [saved],
            active: [DisplayIdentity(displayID: 18, uuid: "changed")], currentBrightness: { _ in 0 })
        #expect(plan.updated.first?.hardwareBrightness == 0.75)
        #expect(plan.updated.first?.softwareBrightness == 0.8)
    }

    @Test func oldBackupRemainsReadable() throws {
        let data = Data(#"{"displayID":3,"brightness":0.8}"#.utf8)
        let saved = try JSONDecoder().decode(DisplayBrightness.self, from: data)
        #expect(saved.uuid == nil)
        #expect(try BrightnessRestoration.target(for: saved, active: [DisplayIdentity(displayID: 3, uuid: "dell")]) == 3)
    }

    @Test func rejectsAggregateBrightnessChangedByComponentWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        case "$*" in
          *--identifiers*) echo '[{"displayID":5,"UUID":"dell"}]' ;;
          *-hardwareBrightness=*) touch "${0%/*}/changed"; echo 0.75 ;;
          *-hardwareBrightness*) echo 0.2 ;;
          *-brightness=*) echo 0.6 ;;
          *) if [ -f "${0%/*}/changed" ]; then echo 0.75; else echo 0.6; fi ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [5] }, builtinDisplayProvider: { _ in false })
        #expect(throws: (any Error).self) {
            try BrightnessRestoration.restore(BrightnessBackup(ownerPID: 1, displays: [
                DisplayBrightness(displayID: 5, brightness: 0.6, uuid: "dell", hardwareBrightness: 0.75)
            ]), client: client, activeAttempts: 1)
        }
    }

    @Test func continuesAfterMissingDisplayAndRejectsFalseSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        if [ "$2" = "--identifiers" ]; then
            echo '[{"displayID":5,"UUID":"dell"},{"displayID":4,"UUID":"mi"}]'
        else
            printf '%s\n' "$*" >> "${0%/*}/calls"
            echo 0.15
        fi
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [5, 4] })
        let backup = BrightnessBackup(ownerPID: 1, displays: [
            DisplayBrightness(displayID: 2, brightness: 0.8, uuid: "absent"),
            DisplayBrightness(displayID: 3, brightness: 0.8, uuid: "dell"),
            DisplayBrightness(displayID: 4, brightness: 1, uuid: "mi")])
        #expect(throws: (any Error).self) {
            try BrightnessRestoration.restore(backup, client: client, activeAttempts: 1)
        }
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("-displayID=5 -brightness=0.8"))
        #expect(calls.contains("-displayID=4 -brightness=1.0"))
        // A successful restore must reproduce the saved non-default value.
        let script = try String(contentsOf: cli, encoding: .utf8).replacingOccurrences(of: "echo 0.15", with: "echo 0.2")
        try script.write(to: cli, atomically: false, encoding: .utf8)
        try BrightnessRestoration.restore(BrightnessBackup(ownerPID: 1, displays: [
            DisplayBrightness(displayID: 3, brightness: 0.2, uuid: "dell")]),
            client: client, activeAttempts: 1)
    }

    /// Inventory keeps disconnected displays; writing to them can hit a recycled
    /// displayID. Only live links may be written.
    @Test func inactiveInventoryDisplayIsNeverWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        if [ "$2" = "--identifiers" ]; then
            echo '[{"displayID":5,"UUID":"dell"},{"displayID":4,"UUID":"mi"}]'
        else
            printf '%s\n' "$*" >> "${0%/*}/calls"
            echo 0.8
        fi
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [5] })
        let backup = BrightnessBackup(ownerPID: 1, displays: [
            DisplayBrightness(displayID: 4, brightness: 0.8, uuid: "mi")])
        #expect(throws: (any Error).self) {
            try BrightnessRestoration.restore(backup, client: client, activeAttempts: 1)
        }
        let calls = (try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        #expect(!calls.contains("-displayID=4"), "inventory-only display must never be written")
    }

    /// Field data: the built-in panel reported 0.891 then read back 0.932 after the
    /// 0.6s window. That drift is evidence, not a failure, and must be recorded.
    @Test func builtinDriftAfterSettlingWindowIsRecordedNotFatal() throws {
        let (client, root) = try driftingClient(builtin: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try BrightnessRestoration.restore(BrightnessBackup(ownerPID: 1, displays: [
            DisplayBrightness(displayID: 5, brightness: 0.891, uuid: "panel")
        ]), client: client, activeAttempts: 1, settlingPasses: 1, settlingInterval: 0)
        #expect(report.drift.count == 1)
        #expect(report.drift.first?.expected == 0.891)
        #expect(report.drift.first?.actual == 0.932)
        #expect(report.drift.first?.isBuiltin == true)
        #expect(report.observed.first?.brightness == 0.932)
    }

    /// Only the built-in panel may follow ambient light. An external display that
    /// moves on its own remains a failure.
    @Test func externalDriftAfterSettlingWindowStillFails() throws {
        let (client, root) = try driftingClient(builtin: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try BrightnessRestoration.restore(BrightnessBackup(ownerPID: 1, displays: [
                DisplayBrightness(displayID: 5, brightness: 0.891, uuid: "panel")
            ]), client: client, activeAttempts: 1, settlingPasses: 1, settlingInterval: 0)
        }
    }

    /// The panel returns the saved value through the settling window, then drifts.
    private func driftingClient(builtin: Bool) throws -> (BetterDisplayClient, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        counter="${0%/*}/reads"
        if [ "$2" = "--identifiers" ]; then echo '[{"displayID":5,"UUID":"panel"}]'; exit 0; fi
        case "$*" in
          *-brightness=*) echo 0.891 ;;
          *-brightness*)
            n=0
            [ -f "$counter" ] && n=$(cat "$counter")
            n=$((n + 1))
            printf '%s' "$n" > "$counter"
            if [ "$n" -ge 2 ]; then echo 0.932; else echo 0.891; fi ;;
          *) echo 0.891 ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [5] }, builtinDisplayProvider: { _ in builtin })
        return (client, root)
    }
}
