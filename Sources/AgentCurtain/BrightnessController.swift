import AgentCurtainCore
import Darwin
import Foundation

final class BrightnessController {
    private let paths: CurtainPaths
    private var watchdog: Process?
    private var watchdogLogHandle: FileHandle?

    init(paths: CurtainPaths) {
        self.paths = paths
    }

    func dimAllDisplays(displaySessionBackup: URL, isCancelled: () -> Bool = { false }) throws -> Int {
        try paths.prepareDirectories()
        guard !FileManager.default.fileExists(atPath: paths.brightnessBackup.path) else {
            throw BrightnessControllerError.unrestoredBackup
        }

        let client = try BetterDisplayClient()
        let identities = try client.displays()
        let displays = try identities.map { identity in
            if isCancelled() { throw CancellationError() }
            return DisplayBrightness(displayID: identity.displayID, brightness: try client.brightness(displayID: identity.displayID), uuid: identity.uuid,
                hardwareBrightness: try? client.brightnessComponent("hardwareBrightness", displayID: identity.displayID),
                softwareBrightness: try? client.brightnessComponent("softwareBrightness", displayID: identity.displayID))
        }
        if isCancelled() { throw CancellationError() }
        let backup = BrightnessBackup(ownerPID: getpid(), displays: displays)
        try BrightnessBackupStore.write(backup, to: paths.brightnessBackup)

        do {
            if isCancelled() { throw CancellationError() }
            try startWatchdog(betterDisplay: client.executable, displaySessionBackup: displaySessionBackup)
            for display in displays {
                if isCancelled() { throw CancellationError() }
                let readback = try client.setBrightnessAndReadback(displayID: display.displayID, value: 0)
                guard readback <= 0.01 else {
                    throw BrightnessControllerError.dimReadback(display.displayID, readback)
                }
            }
            return displays.count
        } catch {
            try? restoreAllDisplays()
            throw error
        }
    }

    func restoreAllDisplays() throws {
        let client = try BetterDisplayClient()
        let original = paths.brightnessBackup
        var candidates: [URL] = []
        if let claimed = try BrightnessBackupStore.claim(original) {
            candidates.append(claimed)
        }
        candidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "brightness.json.restoring."
        ))

        var firstError: Error?
        for claimed in RecoveryClaimFiles.unique(candidates) {
            do {
                let backup = try BrightnessBackupStore.read(from: claimed)
                do { try BrightnessRestoration.restore(backup, client: client) }
                catch { recordAudit(backup: backup, client: client, error: error); throw error }
                recordAudit(backup: backup, client: client, error: nil)
                try FileManager.default.removeItem(at: claimed)
            } catch {
                firstError = firstError ?? error
                try? BrightnessBackupStore.relinquish(claimed, to: original)
            }
        }
        if let firstError { throw firstError }
        watchdog?.terminate()
        watchdog = nil
        try? watchdogLogHandle?.close()
        watchdogLogHandle = nil
    }

    private func recordAudit(backup: BrightnessBackup, client: BetterDisplayClient, error: Error?) {
        struct Audit: Encodable {
            let before: BrightnessBackup
            let after: [DisplayBrightness]
            let error: String?
        }
        let identities = (try? client.displays()) ?? []
        let after = backup.displays.compactMap { saved -> DisplayBrightness? in
            guard let id = try? BrightnessRestoration.target(for: saved, active: identities),
                  let total = try? client.brightness(displayID: id) else { return nil }
            return DisplayBrightness(displayID: id, brightness: total, uuid: saved.uuid,
                hardwareBrightness: try? client.brightnessComponent("hardwareBrightness", displayID: id),
                softwareBrightness: try? client.brightnessComponent("softwareBrightness", displayID: id))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(Audit(before: backup, after: after, error: error?.localizedDescription)) {
            let url = paths.stateDirectory.appendingPathComponent("last-brightness-recovery.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func dimNewDisplays() throws -> Int {
        let original = paths.brightnessBackup
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw BrightnessControllerError.unrestoredBackup
        }
        let client = try BetterDisplayClient()
        let existing = try BrightnessBackupStore.read(from: original)
        // Disconnected saved displays remain in BetterDisplay's inventory but
        // cannot accept brightness queries. Reconcile only live display links.
        let active = try client.activeDisplays()
        let plan = try BrightnessRestoration.reconciliationPlan(
            existing: existing.displays,
            active: active,
            currentBrightness: { try client.brightness(displayID: $0) }
        )
        guard !plan.toDim.isEmpty else { return active.count }
        let updated = BrightnessBackup(ownerPID: existing.ownerPID,
            createdAt: existing.createdAt, displays: plan.updated)
        try BrightnessBackupStore.write(updated, to: original)
        for display in plan.toDim {
            let readback = try client.setBrightnessAndReadback(displayID: display.displayID, value: 0)
            guard readback <= 0.01 else {
                throw BrightnessControllerError.dimReadback(display.displayID, readback)
            }
        }
        return active.count
    }

    func recoverStaleBackup() throws {
        guard FileManager.default.fileExists(atPath: paths.brightnessBackup.path) || hasOrphanedClaim else { return }
        try restoreAllDisplays()
    }

    private var hasOrphanedClaim: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: paths.stateDirectory.path)) ?? []
        return contents.contains(where: { $0.hasPrefix("brightness.json.restoring.") })
    }

    private func startWatchdog(betterDisplay: URL, displaySessionBackup: URL) throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AgentCurtainRestoreWatchdog")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BrightnessControllerError.watchdogMissing
        }
        let process = Process()
        if !FileManager.default.fileExists(atPath: paths.watchdogLog.path) {
            _ = FileManager.default.createFile(atPath: paths.watchdogLog.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.watchdogLog.path)
        let logHandle = try FileHandle(forWritingTo: paths.watchdogLog)
        try logHandle.seekToEnd()
        process.executableURL = helper
        process.arguments = [String(getpid()), paths.brightnessBackup.path,
            displaySessionBackup.path, paths.windowSessionBackup.path, betterDisplay.path,
            Bundle.main.bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        try process.run()
        usleep(150_000)
        guard process.isRunning else { throw BrightnessControllerError.watchdogFailed }
        watchdog = process
        watchdogLogHandle = logHandle
    }
}

enum BrightnessControllerError: Error, LocalizedError {
    case unrestoredBackup
    case dimReadback(Int, Double)
    case watchdogMissing
    case watchdogFailed

    var errorDescription: String? {
        switch self {
        case .unrestoredBackup: return "an unrestored brightness backup already exists"
        case .dimReadback(let id, let value): return "displayID=\(id) remained at brightness \(value)"
        case .watchdogMissing: return "the embedded brightness recovery watchdog is missing"
        case .watchdogFailed: return "the brightness recovery watchdog failed to start"
        }
    }
}
