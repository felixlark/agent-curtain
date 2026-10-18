import AgentCurtainCore
import Darwin
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 7, let ownerPID = Int32(arguments[1]) else {
    fail(
        "usage: AgentCurtainRestoreWatchdog <owner-pid> <brightness-backup> " +
            "<display-session-backup> <window-session-backup> <betterdisplaycli> <agent-curtain-app>",
        code: 2
    )
}

let brightnessBackupURL = URL(fileURLWithPath: arguments[2])
let displaySessionBackupURL = URL(fileURLWithPath: arguments[3])
let windowSessionBackupURL = URL(fileURLWithPath: arguments[4])
let applicationURL = URL(fileURLWithPath: arguments[6])
let client: BetterDisplayClient
do {
    // Test seam, alongside CURTAIN_WATCHDOG_OPEN_EXECUTABLE: the integration fixture
    // cannot make CGGetActiveDisplayList report its synthetic display, so it names the
    // live link IDs explicitly. Production always queries the system.
    let activeDisplayProvider: @Sendable () throws -> [Int]
    if let override = ProcessInfo.processInfo.environment["CURTAIN_WATCHDOG_ACTIVE_DISPLAYS"], !override.isEmpty {
        let ids = override.split(separator: ",").compactMap { Int($0) }
        activeDisplayProvider = { ids }
    } else {
        activeDisplayProvider = BetterDisplayClient.defaultActiveDisplayProvider
    }
    client = try BetterDisplayClient(executable: URL(fileURLWithPath: arguments[5]),
        activeDisplayProvider: activeDisplayProvider)
} catch {
    fail(error.localizedDescription)
}

while kill(ownerPID, 0) == 0 {
    usleep(250_000)
}

var failures: [String] = []
var windowRecoveryPending = false

do {
    // Keep topology and brightness recovery independent from the app process, but
    // leave nonempty window snapshots for the TCC-authorized main executable.
    // The scope is intentional: the app must not be launched while this lock lives.
    let recoveryLock = try RecoveryTransactionLock(
        url: displaySessionBackupURL.deletingLastPathComponent().appendingPathComponent("recovery.lock")
    )
    withExtendedLifetime(recoveryLock) {
        var displaysRestored = true
        var displayCandidates: [URL] = []
        if let claimed = try? DisplaySessionBackupStore.claim(displaySessionBackupURL) {
            displayCandidates.append(claimed)
        }
        displayCandidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: displaySessionBackupURL.deletingLastPathComponent(),
            prefix: "display-session.json.restoring."
        ))
        if !displayCandidates.isEmpty {
            do {
                for claimed in RecoveryClaimFiles.unique(displayCandidates) {
                    do {
                        let saved = try DisplaySessionBackupStore.read(from: claimed)
                        let backup = DisplaySessionOperations.refreshDisplayIDs(
                            in: saved,
                            identities: try client.displays()
                        )
                        if backup != saved {
                            try DisplaySessionBackupStore.write(backup, to: claimed)
                        }
                        let backend = try DisplayConnectionBackendFactory.restoreBackend(for: backup, client: client)
                        try DisplaySessionOperations.restore(backup, client: client, backend: backend)
                        try FileManager.default.removeItem(at: claimed)
                    } catch {
                        try? DisplaySessionBackupStore.relinquish(claimed, to: displaySessionBackupURL)
                        throw error
                    }
                }
            } catch {
                displaysRestored = false
                failures.append("display restore failed: \(error.localizedDescription)")
            }
        }

        var brightnessCandidates: [URL] = []
        if let claimed = try? BrightnessBackupStore.claim(brightnessBackupURL) {
            brightnessCandidates.append(claimed)
        }
        brightnessCandidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: brightnessBackupURL.deletingLastPathComponent(),
            prefix: "brightness.json.restoring."
        ))
        if !brightnessCandidates.isEmpty {
            do {
                for claimed in RecoveryClaimFiles.unique(brightnessCandidates) {
                    do {
                        let backup = try BrightnessBackupStore.read(from: claimed)
                        _ = try BrightnessRestoration.restore(backup, client: client)
                        try FileManager.default.removeItem(at: claimed)
                    } catch {
                        try? BrightnessBackupStore.relinquish(claimed, to: brightnessBackupURL)
                        throw error
                    }
                }
            } catch {
                failures.append("brightness restore failed: \(error.localizedDescription)")
            }
        }

        var windowCandidates: [URL] = []
        if displaysRestored, FileManager.default.fileExists(atPath: windowSessionBackupURL.path) {
            windowCandidates.append(windowSessionBackupURL)
        }
        if displaysRestored {
            windowCandidates.append(contentsOf: RecoveryClaimFiles.recoverable(
                in: windowSessionBackupURL.deletingLastPathComponent(),
                prefix: "window-session.json.restoring."
            ))
        }
        for claimed in RecoveryClaimFiles.unique(windowCandidates) {
            do {
                let backup = try WindowSessionBackupStore.read(from: claimed)
                if backup.windows.isEmpty {
                    try FileManager.default.removeItem(at: claimed)
                } else {
                    windowRecoveryPending = true
                    if claimed != windowSessionBackupURL,
                       !FileManager.default.fileExists(atPath: windowSessionBackupURL.path) {
                        try WindowSessionBackupStore.relinquish(claimed, to: windowSessionBackupURL)
                    }
                }
            } catch {
                failures.append("window handoff failed: \(error.localizedDescription)")
            }
        }
    }
} catch {
    failures.append("recovery lock failed: \(error.localizedDescription)")
}

func launchMainApplication() throws {
    let executable = ProcessInfo.processInfo.environment["CURTAIN_WATCHDOG_OPEN_EXECUTABLE"] ?? "/usr/bin/open"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-gj", applicationURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableLoad, userInfo: [
            NSLocalizedDescriptionKey: "app launcher exited with status \(process.terminationStatus)",
        ])
    }
}

var appRelaunched = false
do {
    try launchMainApplication()
    appRelaunched = true
} catch {
    failures.append("app relaunch failed: \(error.localizedDescription)")
}

if windowRecoveryPending && appRelaunched {
    let directory = windowSessionBackupURL.deletingLastPathComponent()
    let deadline = Date().addingTimeInterval(15)
    repeat {
        let claims = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let pending = FileManager.default.fileExists(atPath: windowSessionBackupURL.path) ||
            claims.contains(where: { $0.hasPrefix("window-session.json.restoring.") })
        if !pending {
            windowRecoveryPending = false
            break
        }
        usleep(250_000)
    } while Date() < deadline
    if windowRecoveryPending {
        failures.append("window restore handoff timed out")
    }
}

if failures.isEmpty { exit(0) }
fail(failures.joined(separator: "; "))
