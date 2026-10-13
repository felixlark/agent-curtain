import Darwin
import Foundation

/// A session-scoped marker. Never persist it outside the private state directory.
public enum InjectionMarkerStore {
    public static func write(_ marker: Int64, to url: URL) throws {
        guard marker != 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".marker-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data("\(marker)\n".utf8))
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func clear(at url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
