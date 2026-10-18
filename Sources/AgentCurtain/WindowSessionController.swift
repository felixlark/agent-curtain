import AgentCurtainCore
import Foundation

final class WindowSessionController {
    private let paths: CurtainPaths
    private let captureOperation: () throws -> WindowSessionBackup
    private let restoreOperation: (WindowSessionBackup) throws -> WindowRestorationReport
    private(set) var recoveryWarning: String?
    private(set) var lastCapturedCount = 0
    private(set) var lastRestoredCount = 0

    init(
        paths: CurtainPaths,
        captureOperation: @escaping () throws -> WindowSessionBackup = {
            try WindowSessionOperations.capture(ownerPID: getpid(), excludingBundleIdentifier: Bundle.main.bundleIdentifier)
        },
        restoreOperation: @escaping (WindowSessionBackup) throws -> WindowRestorationReport = WindowSessionOperations.restore
    ) {
        self.paths = paths
        self.captureOperation = captureOperation
        self.restoreOperation = restoreOperation
    }

    func capture() throws -> Int {
        try paths.prepareDirectories()
        let recoveryLock = try RecoveryTransactionLock(url: paths.recoveryLock)
        defer { withExtendedLifetime(recoveryLock) {} }
        let backup = try captureOperation()
        let archive = try WindowSessionBackupStore.beginSession(backup, at: paths.windowSessionBackup)
        recoveryWarning = archive.map { "旧窗口布局未完全恢复，已留档：\($0.path)；本次使用当前布局" }
        lastCapturedCount = backup.windows.count
        lastRestoredCount = 0
        return backup.windows.count
    }

    @discardableResult
    func restoreAllWindows() throws -> WindowRestorationReport? {
        let original = paths.windowSessionBackup
        var candidates: [URL] = []
        if let claimed = try WindowSessionBackupStore.claim(original) { candidates.append(claimed) }
        candidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "window-session.json.restoring."
        ))

        guard !candidates.isEmpty else { return nil }
        var combined: WindowRestorationReport?
        var firstError: Error?
        for claimed in RecoveryClaimFiles.unique(candidates) {
            do {
                let backup = try WindowSessionBackupStore.read(from: claimed)
                var report: WindowRestorationReport?
                var operationError: Error?
                defer { recordAudit(before: backup, report: report, error: operationError) }
                do { report = try restoreOperation(backup) }
                catch { operationError = error; throw error }
                let result = report!
                lastRestoredCount = result.restored
                if !result.failures.isEmpty {
                    // Retire completed targets before returning the partial failure.
                    // The original timestamp still protects against PID reuse.
                    let pending = WindowSessionBackup(ownerPID: backup.ownerPID,
                        createdAt: backup.createdAt, displays: backup.displays, windows: result.remaining)
                    try WindowSessionBackupStore.write(pending, to: claimed)
                    let error = WindowSessionError.restoreFailures(result.failures)
                    operationError = error
                    throw error
                }
                combined = WindowRestorationReport(
                    saved: (combined?.saved ?? 0) + result.saved,
                    restored: (combined?.restored ?? 0) + result.restored,
                    disappeared: (combined?.disappeared ?? 0) + result.disappeared
                )
                try FileManager.default.removeItem(at: claimed)
            } catch {
                firstError = firstError ?? error
                try? WindowSessionBackupStore.relinquish(claimed, to: original)
            }
        }
        if let firstError { throw firstError }
        lastRestoredCount = combined?.restored ?? 0
        return combined
    }

    private func recordAudit(before: WindowSessionBackup, report: WindowRestorationReport?, error: Error?) {
        struct Audit: Encodable {
            let before: WindowSessionBackup
            let after: WindowSessionBackup?
            let restored: Int
            let disappeared: Int
            let excluded: Int
            let remaining: [SavedWindow]
            let error: String?
        }
        let audit = Audit(before: before, after: try? captureOperation(),
            restored: report?.restored ?? 0, disappeared: report?.disappeared ?? 0,
            excluded: report?.excluded ?? 0, remaining: report?.remaining ?? before.windows,
            error: error?.localizedDescription)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(audit) {
            let url = paths.stateDirectory.appendingPathComponent("last-window-recovery.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func recoverStaleBackup() throws {
        guard hasBackup else { return }
        try restoreAllWindows()
    }

    var pendingRestoreCount: Int {
        if let active = try? WindowSessionBackupStore.read(from: paths.windowSessionBackup) {
            return active.windows.count
        }
        // A failed relinquish can leave the snapshot only as an in-flight claim;
        // report it rather than claiming nothing is pending.
        for claim in RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "window-session.json.restoring."
        ) {
            if let claimed = try? WindowSessionBackupStore.read(from: claim) {
                return claimed.windows.count
            }
        }
        return 0
    }

    private var hasBackup: Bool {
        RecoveryClaimFiles.hasPendingSnapshot(
            active: paths.windowSessionBackup,
            claimPrefix: "window-session.json.restoring.",
            in: paths.stateDirectory
        )
    }
}

enum WindowSessionControllerError: Error, LocalizedError {
    case unrestoredBackup

    var errorDescription: String? {
        "an unrestored window session backup already exists"
    }
}
