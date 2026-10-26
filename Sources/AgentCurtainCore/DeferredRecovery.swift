import Foundation

public enum DeferredRecovery {
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
