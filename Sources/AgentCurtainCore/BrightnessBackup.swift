import Darwin
import Foundation

public struct DisplayBrightness: Codable, Equatable, Sendable {
    public let displayID: Int
    public let brightness: Double
    public let uuid: String?
    public let hardwareBrightness: Double?
    public let softwareBrightness: Double?

    public init(displayID: Int, brightness: Double, uuid: String? = nil,
                hardwareBrightness: Double? = nil, softwareBrightness: Double? = nil) {
        self.displayID = displayID
        self.brightness = brightness
        self.uuid = uuid
        self.hardwareBrightness = hardwareBrightness
        self.softwareBrightness = softwareBrightness
    }
}

public struct BrightnessBackup: Codable, Equatable, Sendable {
    public let ownerPID: Int32
    public let createdAt: Date
    public let displays: [DisplayBrightness]

    public init(ownerPID: Int32, createdAt: Date = Date(), displays: [DisplayBrightness]) {
        self.ownerPID = ownerPID
        let milliseconds = (createdAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        self.createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.displays = displays
    }
}

public enum BrightnessBackupStore {
    public static func write(_ backup: BrightnessBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> BrightnessBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(BrightnessBackup.self, from: Data(contentsOf: url))
    }

    public static func claim(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let claimed = URL(fileURLWithPath: url.path + ".restoring.\(getpid())")
        do {
            try FileManager.default.moveItem(at: url, to: claimed)
            return claimed
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        }
    }

    public static func relinquish(_ claimed: URL, to original: URL) throws {
        guard FileManager.default.fileExists(atPath: claimed.path) else { return }
        try FileManager.default.moveItem(at: claimed, to: original)
    }
}
