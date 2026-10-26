import AgentCurtainCore
import Darwin
import Foundation

final class DisplaySessionController {
    private let paths: CurtainPaths
    private let clientFactory: () throws -> BetterDisplayClient
    private let restoreOperation: (DisplaySessionBackup, BetterDisplayClient) throws -> DisplayRestoreReport
    private(set) var lastBackendKind: DisplayConnectionBackendKind?
    private(set) var betterDisplayProStatus = "unknown"
    /// Diagnostics from retired or abandoned recovery entries. Never fails an
    /// operation: the curtain is usable, the shortfall is auditable.
    private(set) var lastRestoreWarning: String?
    /// Displays retired by the most recent restore, handed to the window path so
    /// windows on vanished displays are retired instead of pending forever.
    private(set) var lastRetiredDisplays: Set<String> = []

    func resetRetirement() {
        lastRestoreWarning = nil
        lastRetiredDisplays = []
    }

    init(paths: CurtainPaths,
         clientFactory: @escaping () throws -> BetterDisplayClient = { try BetterDisplayClient() },
         restoreOperation: @escaping (DisplaySessionBackup, BetterDisplayClient) throws -> DisplayRestoreReport = {
             try DisplaySessionOperations.restoreAvailable($0, client: $1,
                 backend: DisplayConnectionBackendFactory.restoreBackend(for: $0, client: $1))
         }) {
        self.paths = paths
        self.clientFactory = clientFactory
        self.restoreOperation = restoreOperation
    }

    func capture() throws -> Int {
        try paths.prepareDirectories()
        let recoveryLock = try RecoveryTransactionLock(url: paths.recoveryLock)
        defer { withExtendedLifetime(recoveryLock) {} }
        // A snapshot left by an interrupted session is recoverable state, not a
        // reason to refuse a new draw. Recover it first, exactly as startup does.
        try restoreAllDisplays()
        guard !hasBackup else { throw DisplaySessionControllerError.unrestoredBackup }
        let client = try clientFactory()
        let backend = try DisplayConnectionBackendFactory.select(client: client)
        let captured = try DisplaySessionOperations.capture(
            ownerPID: getpid(),
            client: client,
            connectionBackend: backend.kind
        )
        // A still-present but unplugged display keeps its saved entry so a hot-plug
        // can restore it. A display the system no longer knows about is retired:
        // keeping it would make every future restore write an impossible identity.
        let inventory = Set(try client.displays().compactMap(\.uuid))
        let allPrevious = try DeferredRecovery.candidates(for: paths.displaySessionBackup).flatMap {
            try DisplaySessionBackupStore.read(from: $0).displays
        }
        var previous: [DisplayTopology] = []
        for saved in allPrevious where !previous.contains(where: { $0.uuid == saved.uuid }) {
            previous.append(saved)
        }
        let capturedUUIDs = Set(captured.displays.map(\.uuid))
        let retained = previous.filter { !capturedUUIDs.contains($0.uuid) && inventory.contains($0.uuid) }
        let retired = previous.filter { !capturedUUIDs.contains($0.uuid) && !inventory.contains($0.uuid) }
        if !retired.isEmpty {
            lastRestoreWarning = RecoveryRetirement.describeUnavailable(retired.map(\.uuid))
            lastRetiredDisplays.formUnion(retired.map(\.uuid))
        }
        let backup = DisplaySessionBackup(ownerPID: getpid(), connectionBackend: backend.kind,
            displays: captured.displays.map { current in previous.first { $0.uuid == current.uuid } ?? current } + retained)
        try DisplaySessionBackupStore.write(backup, to: paths.displaySessionBackup)
        lastBackendKind = backend.kind
        return backup.displays.count
    }

    func disconnectExternalDisplays(isCancelled: @Sendable () -> Bool = { false }) throws -> Int {
        let client = try clientFactory()
        let saved = try DisplaySessionBackupStore.read(from: paths.displaySessionBackup)
        let backup = DisplaySessionOperations.refreshDisplayIDs(
            in: saved,
            identities: try client.displays()
        )
        if backup != saved {
            try DisplaySessionBackupStore.write(backup, to: paths.displaySessionBackup)
        }
        let backend = try DisplayConnectionBackendFactory.restoreBackend(for: backup, client: client)
        lastBackendKind = backup.connectionBackend ?? backend.kind
        let activeExternal = try DisplaySessionOperations.activeExternalDisplays(in: backup, client: client)
        try DisplaySessionOperations.disconnectDisplays(
            activeExternal,
            backup: backup,
            client: client,
            backend: backend,
            isCancelled: isCancelled
        )
        return backup.displays.count
    }

    func reconcileNewDisplays() throws -> Int {
        guard FileManager.default.fileExists(atPath: paths.displaySessionBackup.path) else {
            throw DisplaySessionControllerError.unrestoredBackup
        }
        let client = try clientFactory()
        let existing = try DisplaySessionBackupStore.read(from: paths.displaySessionBackup)
        let updated = try DisplaySessionOperations.mergeNewActiveDisplays(into: existing, client: client)
        if updated != existing {
            try DisplaySessionBackupStore.write(updated, to: paths.displaySessionBackup)
        }
        let activeExternal = try DisplaySessionOperations.activeExternalDisplays(
            in: updated,
            client: client
        )
        guard !activeExternal.isEmpty else { return updated.displays.count }
        let backend = try DisplayConnectionBackendFactory.restoreBackend(for: updated, client: client)
        lastBackendKind = updated.connectionBackend ?? backend.kind
        try DisplaySessionOperations.disconnectDisplays(
            activeExternal,
            backup: updated,
            client: client,
            backend: backend
        )
        return updated.displays.count
    }

    func restoreAllDisplays() throws {
        resetRetirement()
        let original = paths.displaySessionBackup
        var candidates: [URL] = []
        if let claimed = try DisplaySessionBackupStore.claim(original) { candidates.append(claimed) }
        candidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "display-session.json.restoring."
        ))
        let deferred = try DeferredRecovery.candidates(for: original)
        if !deferred.isEmpty {
            let active = Set(try clientFactory().activeDisplays().compactMap(\.uuid))
            candidates.insert(contentsOf: try deferred.filter {
                try DisplaySessionBackupStore.read(from: $0).displays.contains { active.contains($0.uuid) }
            }, at: 0)
        }

        guard !candidates.isEmpty else { return }
        var firstError: Error?
        for claimed in RecoveryClaimFiles.unique(candidates) {
            do {
                let client = try clientFactory()
                let complete = try DisplaySessionBackupStore.read(from: claimed)
                let isDeferred = DeferredRecovery.isDeferred(claimed, for: original)
                let active = isDeferred ? Set(try client.activeDisplays().compactMap(\.uuid)) : nil
                let saved = DisplaySessionBackup(ownerPID: complete.ownerPID, createdAt: complete.createdAt,
                    connectionBackend: complete.connectionBackend,
                    displays: complete.displays.filter { active?.contains($0.uuid) ?? true })
                let backup = DisplaySessionOperations.refreshDisplayIDs(
                    in: saved,
                    identities: try client.displays()
                )
                if backup != saved && !isDeferred {
                    try DisplaySessionBackupStore.write(backup, to: claimed)
                }
                let report = try restoreOperation(backup, client)
                lastBackendKind = backup.connectionBackend
                if !report.retired.isEmpty {
                    // The saved hardware is gone. Keep the evidence and move on: a
                    // permanently pending entry is what made `curtain on` unusable.
                    lastRestoreWarning = RecoveryRetirement.describeUnavailable(report.retired)
                    lastRetiredDisplays.formUnion(report.retired)
                }
                if !report.warnings.isEmpty {
                    lastRestoreWarning = ([lastRestoreWarning] + report.warnings)
                        .compactMap { $0 }.joined(separator: "; ")
                }
                if isDeferred {
                    let restored = Set(report.restored)
                    let remaining = complete.displays.filter { !restored.contains($0.uuid) }
                    if remaining.isEmpty {
                        try FileManager.default.removeItem(at: claimed)
                    } else {
                        try DisplaySessionBackupStore.write(DisplaySessionBackup(ownerPID: complete.ownerPID,
                            createdAt: complete.createdAt, connectionBackend: complete.connectionBackend,
                            displays: remaining), to: claimed)
                    }
                } else {
                    try DeferredRecovery.saveDisplays(backup, pending: Set(report.retired + report.deferred),
                        source: claimed, original: original)
                    try FileManager.default.removeItem(at: claimed)
                }
            } catch {
                firstError = firstError ?? error
                if !DeferredRecovery.isDeferred(claimed, for: original) {
                    try? DisplaySessionBackupStore.relinquish(claimed, to: original)
                }
            }
        }
        if let firstError { throw firstError }
    }

    func recoverStaleBackup() throws {
        guard hasBackup else { return }
        try restoreAllDisplays()
    }

    func currentActiveDisplayCount() throws -> Int {
        try clientFactory().activeDisplays().count
    }

    func refreshBackendDiagnostics() {
        guard let client = try? clientFactory() else {
            betterDisplayProStatus = "unknown"
            return
        }
        do {
            betterDisplayProStatus = try client.proAvailable() ? "on" : "off"
        } catch {
            betterDisplayProStatus = "unknown"
        }
    }

    var pendingRestoreCount: Int {
        if let active = try? DisplaySessionBackupStore.read(from: paths.displaySessionBackup) {
            return active.displays.filter { !$0.isBuiltin }.count
        }
        // A failed relinquish can leave the snapshot only as an in-flight claim;
        // report it rather than claiming nothing is pending.
        for claim in RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "display-session.json.restoring."
        ) {
            if let claimed = try? DisplaySessionBackupStore.read(from: claim) {
                return claimed.displays.filter { !$0.isBuiltin }.count
            }
        }
        return 0
    }

    var privateDisplaySPIStatus: String {
        SystemDisplayConnectionBackend.availabilityStatus
    }

    var displayBackendStatus: String? {
        if let lastBackendKind { return lastBackendKind.rawValue }
        if let saved = try? DisplaySessionBackupStore.read(from: paths.displaySessionBackup) {
            return saved.connectionBackend?.rawValue ?? DisplayConnectionBackendKind.betterDisplay.rawValue
        }
        return DisplayConnectionBackendFactory.preferredKindWithoutProbingBetterDisplay?.rawValue
    }

    private var hasBackup: Bool {
        RecoveryClaimFiles.hasPendingSnapshot(
            active: paths.displaySessionBackup,
            claimPrefix: "display-session.json.restoring.",
            in: paths.stateDirectory
        )
    }
}

enum DisplaySessionControllerError: Error, LocalizedError {
    case unrestoredBackup

    var errorDescription: String? {
        switch self {
        case .unrestoredBackup: return "an unrestored display session backup already exists"
        }
    }
}
