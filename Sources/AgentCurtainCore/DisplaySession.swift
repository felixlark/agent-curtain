import Darwin
import Foundation
import CoreGraphics

public struct DisplayTopology: Codable, Equatable, Sendable {
    public let uuid: String
    public let displayID: Int
    public let isBuiltin: Bool
    public let wasMain: Bool
    public let placement: String
    public let resolution: String
    public let rotation: String?

    public init(
        uuid: String,
        displayID: Int,
        isBuiltin: Bool,
        wasMain: Bool,
        placement: String,
        resolution: String,
        rotation: String?
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.isBuiltin = isBuiltin
        self.wasMain = wasMain
        self.placement = placement
        self.resolution = resolution
        self.rotation = rotation
    }
}

public struct DisplaySessionBackup: Codable, Equatable, Sendable {
    public let version: Int
    public let ownerPID: Int32
    public let createdAt: Date
    public let connectionBackend: DisplayConnectionBackendKind?
    public let displays: [DisplayTopology]

    public init(
        ownerPID: Int32,
        createdAt: Date = Date(),
        connectionBackend: DisplayConnectionBackendKind? = nil,
        displays: [DisplayTopology]
    ) {
        version = connectionBackend == nil ? 1 : 2
        self.ownerPID = ownerPID
        let milliseconds = (createdAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        self.createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.connectionBackend = connectionBackend
        self.displays = displays
    }

    public var builtin: DisplayTopology? { displays.first(where: \.isBuiltin) }
}

public enum DisplaySessionBackupStore {
    public static func write(_ backup: DisplaySessionBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> DisplaySessionBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DisplaySessionBackup.self, from: Data(contentsOf: url))
    }

    public static func claim(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let claimed = URL(fileURLWithPath: url.path + ".restoring.\(getpid())")
        do {
            try FileManager.default.moveItem(at: url, to: claimed)
            return claimed
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        }
    }

    public static func relinquish(_ claimed: URL, to original: URL) throws {
        guard FileManager.default.fileExists(atPath: claimed.path) else { return }
        try FileManager.default.moveItem(at: claimed, to: original)
    }
}

public enum DisplaySessionError: Error, LocalizedError {
    case missingUUID(Int)
    case invalidBuiltinCount(Int)
    case missingMainDisplay
    case noBackup

    public var errorDescription: String? {
        switch self {
        case .missingUUID(let id): return "displayID=\(id) has no stable UUID"
        case .invalidBuiltinCount(let count): return "expected one active built-in display, found \(count)"
        case .missingMainDisplay: return "the saved main display is unavailable"
        case .noBackup: return "display session backup is missing"
        }
    }
}

public enum DisplaySessionOperations {
    public static func capture(
        ownerPID: Int32,
        client: BetterDisplayClient,
        connectionBackend: DisplayConnectionBackendKind? = nil
    ) throws -> DisplaySessionBackup {
        let active = try client.activeDisplays()
        let builtinCount = active.filter(\.isBuiltin).count
        guard builtinCount == 1 else { throw DisplaySessionError.invalidBuiltinCount(builtinCount) }

        let displays = try active.map { identity -> DisplayTopology in
            guard let uuid = identity.uuid, !uuid.isEmpty else {
                throw DisplaySessionError.missingUUID(identity.displayID)
            }
            let main = try client.feature("main", uuid: uuid).lowercased()
            return DisplayTopology(
                uuid: uuid,
                displayID: identity.displayID,
                isBuiltin: identity.isBuiltin,
                wasMain: main == "true" || main == "on" || main == "1",
                placement: try client.feature("placement", uuid: uuid),
                resolution: try client.feature("resolution", uuid: uuid),
                rotation: try? client.feature("rotation", uuid: uuid)
            )
        }
        guard displays.contains(where: \.wasMain) else { throw DisplaySessionError.missingMainDisplay }
        return DisplaySessionBackup(
            ownerPID: ownerPID,
            connectionBackend: connectionBackend,
            displays: displays
        )
    }

    public static func disconnectExternalDisplays(
        backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        backend: any DisplayConnectionBackend,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Int {
        try disconnectDisplays(
            backup.displays.filter { !$0.isBuiltin },
            backup: backup,
            client: client,
            backend: backend,
            isCancelled: isCancelled
        )
        return backup.displays.count
    }

    public static func disconnectDisplays(
        _ displays: [DisplayTopology],
        backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        backend: any DisplayConnectionBackend,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        guard let builtin = backup.builtin else { throw DisplaySessionError.invalidBuiltinCount(0) }
        guard displays.contains(where: { !$0.isBuiltin }) else { return }
        if isCancelled() { throw CancellationError() }
        let activeUUIDs = Set(try client.activeDisplays().compactMap(\.uuid))
        if activeUUIDs.contains(builtin.uuid) {
            let main = try client.feature("main", uuid: builtin.uuid).lowercased()
            if main != "true" && main != "on" && main != "1" {
                try client.setFeature("main", value: "on", uuid: builtin.uuid)
                try client.waitForMainDisplay(uuid: builtin.uuid)
            }
        } else if backend.kind != .systemSPI {
            throw DisplayConnectionBackendError.configuration(
                "built-in display is not active before BetterDisplay fallback disconnect"
            )
        }
        if isCancelled() { throw CancellationError() }
        try backend.disconnect(
            displays: displays,
            backup: backup,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        _ = try client.waitForActiveDisplays(uuids: [builtin.uuid], exact: true)
    }

    public static func mergeNewActiveDisplays(
        into backup: DisplaySessionBackup,
        client: BetterDisplayClient
    ) throws -> DisplaySessionBackup {
        let refreshed = refreshDisplayIDs(in: backup, identities: try client.displays())
        let known = Set(refreshed.displays.map(\.uuid))
        let active = try client.activeDisplays()
        let additions = try active.compactMap { identity -> DisplayTopology? in
            guard let uuid = identity.uuid else { throw DisplaySessionError.missingUUID(identity.displayID) }
            guard !known.contains(uuid) else { return nil }
            let main = try client.feature("main", uuid: uuid).lowercased()
            return DisplayTopology(
                uuid: uuid,
                displayID: identity.displayID,
                isBuiltin: identity.isBuiltin,
                wasMain: main == "true" || main == "on" || main == "1",
                placement: try client.feature("placement", uuid: uuid),
                resolution: try client.feature("resolution", uuid: uuid),
                rotation: try? client.feature("rotation", uuid: uuid)
            )
        }
        guard !additions.isEmpty else { return refreshed }
        return DisplaySessionBackup(ownerPID: refreshed.ownerPID, createdAt: refreshed.createdAt,
            connectionBackend: refreshed.connectionBackend,
            displays: refreshed.displays + additions)
    }

    public static func refreshDisplayIDs(
        in backup: DisplaySessionBackup,
        identities: [DisplayIdentity]
    ) -> DisplaySessionBackup {
        var currentIDs: [String: Int] = [:]
        for identity in identities {
            if let uuid = identity.uuid { currentIDs[uuid] = identity.displayID }
        }
        let refreshed = backup.displays.map { saved -> DisplayTopology in
            guard let current = currentIDs[saved.uuid], current != saved.displayID else { return saved }
            return DisplayTopology(
                uuid: saved.uuid,
                displayID: current,
                isBuiltin: saved.isBuiltin,
                wasMain: saved.wasMain,
                placement: saved.placement,
                resolution: saved.resolution,
                rotation: saved.rotation
            )
        }
        guard refreshed != backup.displays else { return backup }
        return DisplaySessionBackup(
            ownerPID: backup.ownerPID,
            createdAt: backup.createdAt,
            connectionBackend: backup.connectionBackend,
            displays: refreshed
        )
    }

    public static func activeExternalDisplays(
        in backup: DisplaySessionBackup,
        client: BetterDisplayClient
    ) throws -> [DisplayTopology] {
        let activeUUIDs = Set(try client.activeDisplays().compactMap(\.uuid))
        return backup.displays.filter { !$0.isBuiltin && activeUUIDs.contains($0.uuid) }
    }

    public static func restore(
        _ backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        backend: any DisplayConnectionBackend
    ) throws {
        _ = try restoreLayoutAndModes(backup, client: client, backend: backend, attempts: 3)
    }

    /// Restore only the displays the system still reports, and retire the rest.
    ///
    /// A saved snapshot can outlive its hardware: the operator unplugs a monitor,
    /// or macOS renumbers the topology. Submitting those identifiers to
    /// WindowServer is what produces `complete returned 1001` on every unlock, so
    /// they are never written. They leave the snapshot with an archived record
    /// instead of blocking `curtain on` forever.
    ///
    /// `configurationAttempts` bounds the retry loop for the transaction itself.
    /// A display that still fails after the bound is abandoned as a warning: the
    /// operator gets a usable curtain either way.
    public static func restoreAvailable(
        _ backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        backend: any DisplayConnectionBackend,
        configurationAttempts: Int = 3,
        layout: ((DisplaySessionBackup, BetterDisplayClient, Int) throws -> Void)? = nil
    ) throws -> DisplayRestoreReport {
        let saved = backup.displays
        let inventory = Set(try client.displays().compactMap(\.uuid))
        let active = Set(try client.activeDisplays().compactMap(\.uuid))
        let partition = RecoveryRetirement.partition(saved.map(\.uuid),
            inventory: inventory, active: active)
        let availableUUIDs = Set(partition.available)
        let available = saved.filter { availableUUIDs.contains($0.uuid) }
        let unavailable = saved.filter { !availableUUIDs.contains($0.uuid) }
        guard !available.isEmpty else {
            return DisplayRestoreReport(retired: unavailable.map(\.uuid))
        }

        let scoped = DisplaySessionBackup(ownerPID: backup.ownerPID, createdAt: backup.createdAt,
            connectionBackend: backup.connectionBackend, displays: available)
        let warnings = try restoreLayoutAndModes(scoped, client: client, backend: backend,
            attempts: configurationAttempts, layout: layout)
        return DisplayRestoreReport(restored: warnings.isEmpty ? available.map(\.uuid) : [],
            retired: unavailable.map(\.uuid), warnings: warnings,
            deferred: warnings.isEmpty ? [] : available.map(\.uuid))
    }

    /// A WindowServer transaction that keeps refusing cannot be fixed by retrying
    /// forever; it must degrade to an audited warning.
    static func isAbandonableConfigurationFailure(_ error: Error) -> Bool {
        isRetryable(error)
    }

    private static func restoreLayoutAndModes(
        _ backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        backend: any DisplayConnectionBackend,
        attempts: Int,
        layout: ((DisplaySessionBackup, BetterDisplayClient, Int) throws -> Void)? = nil
    ) throws -> [String] {
        var warnings: [String] = []
        for attempt in 0..<max(1, attempts) {
            do {
                try backend.reconnectDisplays(backup: backup)
                break
            } catch {
                if case DisplayConnectionBackendError.verification = error {
                    return ["display reconnect deferred: \(error.localizedDescription)"]
                }
                guard isRetryable(error) else { throw error }
                if attempt + 1 == max(1, attempts) {
                    return ["display reconnect deferred after \(max(1, attempts)) attempts: \(error.localizedDescription)"]
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        var failures: [String] = []
        if backend.kind == .systemSPI {
            do {
                if let layout { try layout(backup, client, attempts) }
                else { try restoreLayoutInOneTransaction(backup, client: client, attempts: attempts) }
            }
            catch {
                if isAbandonableConfigurationFailure(error) {
                    warnings.append("display layout deferred after \(max(1, attempts)) attempts: \(error.localizedDescription)")
                } else {
                    failures.append("layout: \(error.localizedDescription)")
                }
            }
        } else {
            if let main = backup.displays.first(where: \.wasMain) {
                do {
                    let current = try client.feature("main", uuid: main.uuid).lowercased()
                    if current != "true" && current != "on" && current != "1" {
                        try client.setFeature("main", value: "on", uuid: main.uuid)
                    }
                } catch {
                    failures.append("main \(main.uuid): \(error.localizedDescription)")
                }
            }

            for saved in backup.displays {
                do {
                    if try client.feature("placement", uuid: saved.uuid) != saved.placement {
                        try client.setFeature("placement", value: saved.placement, uuid: saved.uuid)
                    }
                } catch {
                    failures.append("\(saved.uuid) placement: \(error.localizedDescription)")
                }
            }
        }
        for saved in backup.displays {
            do {
                if let rotation = saved.rotation {
                    try client.restoreFeatureAfterSettling("rotation", value: rotation, uuid: saved.uuid)
                }
                try client.restoreFeatureAfterSettling("resolution", value: saved.resolution, uuid: saved.uuid)
            } catch {
                failures.append("\(saved.uuid): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw BetterDisplayError.commandFailed(failures.joined(separator: "; "))
        }
        return warnings
    }

    /// Main display and all origins share one WindowServer transaction. Per-screen
    /// placement writes otherwise trigger several screen-change waves and app reflows.
    ///
    /// `attempts` bounds how many times a transaction may be reissued. `complete`
    /// returning 1001 means the configuration was rejected, usually because the
    /// topology changed while it was being prepared. The transaction is rebuilt
    /// from a fresh active set on each retry, and the last error is surfaced once
    /// the bound is exhausted so the caller can degrade instead of hanging.
    static func restoreLayoutInOneTransaction(
        _ backup: DisplaySessionBackup,
        client: BetterDisplayClient,
        attempts: Int = 3,
        activeDisplays: (() throws -> [DisplayIdentity])? = nil,
        commit: ([(CGDirectDisplayID, Int32, Int32)]) throws -> Void = DisplaySessionOperations.commitLayout
    ) throws {
        let expectedUUIDs = Set(backup.displays.map(\.uuid))
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                // WindowServer display IDs settle before BetterDisplay's UUID metadata.
                // Transitional UNKNOWN entries are not identities and must never key a map.
                let active = try activeDisplays?()
                    ?? client.waitForActiveDisplays(uuids: expectedUUIDs, exact: false)
                let ids = try layoutDisplayIDs(active, expectedUUIDs: expectedUUIDs)
                let changes = try backup.displays.map { saved -> (CGDirectDisplayID, Int32, Int32) in
                    guard let id = ids[saved.uuid], let origin = placementOrigin(saved.placement) else {
                        throw BetterDisplayError.invalidValue("placement \(saved.uuid): \(saved.placement)")
                    }
                    return (id, origin.0, origin.1)
                }
                try commit(changes)
                // Validate by UUID after committing; a successful transaction alone is not proof.
                for saved in backup.displays {
                    guard try client.feature("placement", uuid: saved.uuid) == saved.placement else {
                        throw BetterDisplayError.commandFailed("layout readback mismatch for \(saved.uuid)")
                    }
                }
                if let main = backup.displays.first(where: \.wasMain) {
                    try client.waitForMainDisplay(uuid: main.uuid)
                }
                return
            } catch {
                lastError = error
                guard attempt + 1 < max(1, attempts), isRetryable(error) else { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        throw lastError ?? DisplayConnectionBackendError.configuration("layout did not complete")
    }

    /// 1001 (`kCGErrorFailure`) is returned when the configuration is rejected,
    /// typically a race with a display attach/detach. Rebuilding it once is useful;
    /// repeating it forever is not.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case DisplayConnectionBackendError.configuration(let message):
            return message == "complete returned 1001"
        default:
            return false
        }
    }

    static func commitLayout(_ changes: [(CGDirectDisplayID, Int32, Int32)]) throws {
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            throw DisplayConnectionBackendError.configuration("layout begin returned \(begin.rawValue)")
        }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(configuration) } }
        for (id, x, y) in changes {
            let result = CGConfigureDisplayOrigin(configuration, id, x, y)
            guard result == .success else {
                throw DisplayConnectionBackendError.configuration("origin displayID=\(id) returned \(result.rawValue)")
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard result == .success else {
            throw DisplayConnectionBackendError.configuration("complete returned \(result.rawValue)")
        }
        completed = true
    }

    static func layoutDisplayIDs(_ active: [DisplayIdentity], expectedUUIDs: Set<String>) throws -> [String: CGDirectDisplayID] {
        var ids: [String: CGDirectDisplayID] = [:]
        for identity in active {
            guard let uuid = identity.uuid, expectedUUIDs.contains(uuid) else { continue }
            guard identity.displayID > 0, let id = CGDirectDisplayID(exactly: identity.displayID),
                  ids.updateValue(id, forKey: uuid) == nil else {
                throw BetterDisplayError.invalidDisplayList
            }
        }
        guard expectedUUIDs.isSubset(of: Set(ids.keys)) else { throw BetterDisplayError.invalidDisplayList }
        return ids
    }

    static func placementOrigin(_ value: String) -> (Int32, Int32)? {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int32(parts[0]), let y = Int32(parts[1]) else { return nil }
        return (x, y)
    }

}
