import Foundation

/// Retiring recovery entries that can never be satisfied is part of the contract:
/// a saved display that is physically gone must not pin `restore-pending` forever.
/// The evidence is archived next to the live snapshot instead of being deleted.
public enum RecoveryArchive {
    public static func destination(for url: URL, reason: String, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).retired-\(reason)-\(stamp).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base).retired-\(reason)-\(stamp)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    /// Preserve the record with mode 0600 before the live snapshot is retired.
    public static func preserve(_ url: URL, reason: String, now: Date = Date()) throws -> URL {
        let destination = try destination(for: url, reason: reason, now: now)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}

public enum RecoveryRetirement {
    /// Split saved identities by whether the system still knows about them.
    /// A UUID that appears in neither the inventory nor the active set cannot be
    /// enabled: submitting it is exactly the `complete returned 1001` case.
    public static func partition(
        _ uuids: [String],
        inventory: Set<String>,
        active: Set<String>
    ) -> (available: [String], unavailable: [String]) {
        var available: [String] = []
        var unavailable: [String] = []
        for uuid in uuids {
            if inventory.contains(uuid) || active.contains(uuid) {
                available.append(uuid)
            } else {
                unavailable.append(uuid)
            }
        }
        return (available, unavailable)
    }

    public static func describeUnavailable(_ uuids: [String]) -> String {
        "saved displays are no longer present and were retired: \(uuids.sorted().joined(separator: ", "))"
    }
}

/// Outcome of one display restore attempt. Displays the system no longer reports
/// are retired with a warning instead of pinning `restore-pending` forever; the
/// caller archives the evidence and still reports a usable state.
public struct DisplayRestoreReport: Equatable, Sendable {
    /// UUIDs that were reconnected and repositioned.
    public let restored: [String]
    /// UUIDs the system no longer reports (detached or replaced hardware).
    public let retired: [String]
    /// Non-fatal shortfalls: layout abandoned after retries, mode readback, etc.
    public let warnings: [String]

    public init(restored: [String] = [], retired: [String] = [], warnings: [String] = []) {
        self.restored = restored
        self.retired = retired
        self.warnings = warnings
    }

    public var isFullyRestored: Bool { retired.isEmpty && warnings.isEmpty }
}

/// A saved window that was dropped because its display was retired. Reported in
/// the recovery warning and the audit record, never silently discarded.
public struct RetiredWindow: Codable, Equatable, Sendable {
    public let applicationName: String
    public let windowID: UInt32?
    public let ordinal: Int
    public let displayUUID: String

    public init(applicationName: String, windowID: UInt32?, ordinal: Int, displayUUID: String) {
        self.applicationName = applicationName
        self.windowID = windowID
        self.ordinal = ordinal
        self.displayUUID = displayUUID
    }

    public var description: String {
        "\(applicationName) window \(windowID.map(String.init) ?? String(ordinal)) on retired display \(displayUUID)"
    }
}
