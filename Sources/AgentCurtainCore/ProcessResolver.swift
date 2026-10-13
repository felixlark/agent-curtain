import Darwin
import Foundation

public enum InputDecision {
    public static func shouldAllow(
        pid: Int32,
        allowedPIDs: Set<Int32>,
        deniedPIDs: Set<Int32>,
        injectionMarker: Int64? = nil,
        eventMarker: Int64 = 0
    ) -> Bool {
        guard pid != 0 else { return false }
        if deniedPIDs.contains(pid) { return false }
        if let injectionMarker, injectionMarker != 0, eventMarker == injectionMarker { return true }
        return allowedPIDs.contains(pid)
    }
}

public struct ProcessRule: Equatable, Sendable {
    public let executablePath: String?
    public let executableName: String?

    public init(_ raw: String) {
        guard raw.hasPrefix("/") else {
            executablePath = nil
            executableName = raw
            return
        }

        let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        if url.pathExtension == "app", let executable = Bundle(url: url)?.executableURL {
            executablePath = executable.standardizedFileURL.resolvingSymlinksInPath().path
        } else {
            executablePath = url.path
        }
        executableName = nil
    }

    public func matches(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let executablePath { return normalized == executablePath }
        if let executableName { return URL(fileURLWithPath: normalized).lastPathComponent == executableName }
        return false
    }
}

public enum ProcessResolver {
    public static func snapshot() -> [(pid: Int32, path: String)] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard actual > 0 else { return [] }

        var result: [(pid: Int32, path: String)] = []
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            // PROC_PIDPATHINFO_MAXSIZE is a C expression macro and is no longer
            // imported by the macOS 26 Swift SDK. libproc documents 4 KiB as
            // the maximum buffer accepted by proc_pidpath.
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            result.append((pid, String(cString: buffer)))
        }
        return result
    }

    public static func matchingPIDs(rules: [String], processes: [(pid: Int32, path: String)] = snapshot()) -> Set<Int32> {
        let resolved = rules.map(ProcessRule.init)
        return Set(processes.compactMap { process in
            resolved.contains(where: { $0.matches(path: process.path) }) ? process.pid : nil
        })
    }
}
