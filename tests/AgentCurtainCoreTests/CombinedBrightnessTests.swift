import Foundation
import Testing
@testable import AgentCurtainCore

@Suite struct CombinedBrightnessTests {
    @Test func quantizedComponentDoesNotTriggerAnUnnecessaryWrite() throws {
        let fixture = try CombinedBrightnessFixture(stdout: "0.741\n")
        defer { fixture.remove() }

        try fixture.client.restoreBrightnessComponent("hardwareBrightness", displayID: 1, value: 0.73)

        #expect(try fixture.arguments() == "get\n-displayID=1\n-hardwareBrightness\n")
    }

    @Test func componentWriteAcceptsQuantizedReadback() throws {
        let fixture = try CombinedBrightnessFixture(stdout: "0.1\n")
        defer { fixture.remove() }
        try """
        #!/bin/sh
        fixture_dir=${0%/*}
        printf '%s\\n' "$@" >> "$fixture_dir/arguments"
        if [ "$1" = "set" ]; then echo 0.741; else echo 0.1; fi
        """.write(to: fixture.root.appendingPathComponent("fake-betterdisplaycli"), atomically: false, encoding: .utf8)

        try fixture.client.restoreBrightnessComponent("hardwareBrightness", displayID: 1, value: 0.73)

        #expect(try fixture.arguments().contains("set\nget\n-displayID=1\n-hardwareBrightness=0.73\n"))
    }

    @Test func componentWriteStillRejectsLargeMismatch() throws {
        let fixture = try CombinedBrightnessFixture(stdout: "0.1\n")
        defer { fixture.remove() }

        #expect(throws: BetterDisplayError.self) {
            try fixture.client.restoreBrightnessComponent("hardwareBrightness", displayID: 1, value: 0.73)
        }
    }

    @Test func setsAndReadsOneDisplayWithOneCommand() throws {
        let fixture = try CombinedBrightnessFixture(stdout: " \t0.375\n")
        defer { fixture.remove() }

        let readback = try fixture.client.setBrightnessAndReadback(displayID: 42, value: 0.75)

        #expect(readback == 0.375)
        #expect(try fixture.arguments() == "set\nget\n-displayID=42\n-brightness=0.75\n")
    }

    @Test(arguments: ["", " \n", "invalid", "nan", "inf", "-inf", "0.2\n0.3\n"])
    func rejectsMissingInvalidOrNonfiniteReadback(_ output: String) throws {
        let fixture = try CombinedBrightnessFixture(stdout: output)
        defer { fixture.remove() }

        do {
            _ = try fixture.client.setBrightnessAndReadback(displayID: 17, value: 0)
            Issue.record("expected invalidBrightness")
        } catch let error as BetterDisplayError {
            guard case .invalidBrightness(let displayID) = error else {
                Issue.record("expected invalidBrightness, got \(error)")
                return
            }
            #expect(displayID == 17)
        }
    }

    @Test(arguments: ["device unavailable\n", ""])
    func propagatesCommandFailureEvenWithNumericOutput(_ stderr: String) throws {
        let fixture = try CombinedBrightnessFixture(stdout: "0.0\n", stderr: stderr, exitStatus: 23)
        defer { fixture.remove() }

        do {
            _ = try fixture.client.setBrightnessAndReadback(displayID: 9, value: 0)
            Issue.record("expected commandFailed")
        } catch let error as BetterDisplayError {
            guard case .commandFailed(let message) = error else {
                Issue.record("expected commandFailed, got \(error)")
                return
            }
            #expect(message == (stderr.isEmpty ? "exit 23" : "device unavailable"))
        }
    }
}

private struct CombinedBrightnessFixture {
    let root: URL
    let client: BetterDisplayClient

    init(stdout: String, stderr: String = "", exitStatus: Int = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("combined-brightness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-betterdisplaycli")
        try stdout.write(to: root.appendingPathComponent("stdout"), atomically: true, encoding: .utf8)
        try stderr.write(to: root.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        fixture_dir=${0%/*}
        printf '%s\\n' "$@" >> "$fixture_dir/arguments"
        /bin/cat "$fixture_dir/stdout"
        /bin/cat "$fixture_dir/stderr" >&2
        exit \(exitStatus)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = try BetterDisplayClient(executable: executable, application: nil, launcher: { _ in })
    }

    func arguments() throws -> String {
        try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
