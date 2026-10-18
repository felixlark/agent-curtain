import Darwin
import Foundation

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public final class RecoveryTransactionLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        if systemFlock(descriptor, LOCK_EX) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = systemFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

public enum RecoveryClaimFiles {
    public static func unique(_ files: [URL]) -> [URL] {
        var paths = Set<String>()
        return files.filter { file in
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath().path
            return paths.insert(canonical).inserted
        }
    }

    public static func recoverable(in directory: URL, prefix: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { file in
            guard file.lastPathComponent.hasPrefix(prefix),
                  let claimant = Int32(file.lastPathComponent.dropFirst(prefix.count)) else { return false }
            if claimant == getpid() { return true }
            if kill(claimant, 0) == 0 { return false }
            return errno == ESRCH
        }
    }

    /// A snapshot is pending either as the active file or as any in-flight claim,
    /// including a live one owned by another process. Callers use this both to
    /// refuse to overwrite unrecovered state and to decide when to recover first.
    public static func hasPendingSnapshot(active: URL, claimPrefix: String, in directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: active.path) { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasPrefix(claimPrefix) }
    }
}
