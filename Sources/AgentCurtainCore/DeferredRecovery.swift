import Foundation

public enum DeferredRecovery {
    /// The oldest unresolved target owns an identity across sessions. Archive
    /// superseded records before removing duplicate replay targets, preserving
    /// each selected record's original capture timestamp and process identity.
    public static func arbitrate<Backup>(_ candidates: [URL],
        read: (URL) throws -> Backup, createdAt: (Backup) -> Date,
        keys: (Backup) -> [String], keeping: (Backup, Set<String>) -> Backup,
        write: (Backup, URL) throws -> Void) throws {
        let records = try candidates.map { ($0, try read($0)) }.sorted {
            let left = createdAt($0.1), right = createdAt($1.1)
            return left == right ? $0.0.path < $1.0.path : left < right
        }
        var owned = Set<String>()
        for (url, backup) in records {
            let identities = Set(keys(backup))
            let selected = identities.subtracting(owned)
            owned.formUnion(identities)
            guard selected != identities else { continue }
            _ = try RecoveryArchive.preserve(url, reason: "superseded-targets")
            try write(keeping(backup, selected), url)
        }
    }

    public static func candidates(for original: URL) throws -> [URL] {
        let prefix = original.deletingPathExtension().lastPathComponent + ".deferred."
        return try FileManager.default.contentsOfDirectory(at: original.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func destination(for original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(
            original.deletingPathExtension().lastPathComponent + ".deferred." + UUID().uuidString + ".json")
    }

    public static func isDeferred(_ candidate: URL, for original: URL) -> Bool {
        candidate.lastPathComponent.hasPrefix(original.deletingPathExtension().lastPathComponent + ".deferred.")
    }

    public static func saveDisplays(_ backup: DisplaySessionBackup, pending: Set<String>,
                                    source: URL, original: URL) throws {
        guard !pending.isEmpty else { return }
        _ = try RecoveryArchive.preserve(source, reason: "deferred-displays")
        try DisplaySessionBackupStore.write(DisplaySessionBackup(ownerPID: backup.ownerPID,
            createdAt: backup.createdAt, connectionBackend: backup.connectionBackend,
            displays: backup.displays.filter { pending.contains($0.uuid) }), to: destination(for: original))
    }

    public static func saveBrightness(_ backup: BrightnessBackup, pending: [DisplayBrightness],
                                     source: URL, original: URL) throws {
        guard !pending.isEmpty else { return }
        _ = try RecoveryArchive.preserve(source, reason: "deferred-brightness")
        try BrightnessBackupStore.write(BrightnessBackup(ownerPID: backup.ownerPID,
            createdAt: backup.createdAt, displays: pending), to: destination(for: original))
    }

    public static func saveWindows(_ backup: WindowSessionBackup, pending: [SavedWindow],
                                  source: URL, original: URL) throws {
        guard !pending.isEmpty else { return }
        _ = try RecoveryArchive.preserve(source, reason: "deferred-windows")
        try WindowSessionBackupStore.write(WindowSessionBackup(ownerPID: backup.ownerPID,
            createdAt: backup.createdAt, displays: backup.displays, windows: pending), to: destination(for: original))
    }
}
