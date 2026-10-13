import Darwin
import CoreGraphics
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandRunner {
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 15) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw BetterDisplayError.commandTimedOut
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, stdout: output, stderr: error)
    }
}

public enum BetterDisplayError: Error, LocalizedError {
    case executableNotFound
    case commandFailed(String)
    case commandTimedOut
    case invalidDisplayList
    case invalidBrightness(Int)
    case appNotRunning(String)
    case proRequired
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "betterdisplaycli was not found"
        case .commandFailed(let message): return "betterdisplaycli failed: \(message)"
        case .commandTimedOut: return "betterdisplaycli timed out"
        case .invalidDisplayList: return "betterdisplaycli returned no display IDs"
        case .invalidBrightness(let id): return "invalid brightness for displayID=\(id)"
        case .appNotRunning(let app):
            return "BetterDisplay.app is not running (\(app)); betterdisplaycli answers nothing without it"
        case .proRequired: return "BetterDisplay Pro is required to disconnect external displays"
        case .invalidValue(let feature): return "betterdisplaycli returned an invalid value for \(feature)"
        }
    }
}

public struct BetterDisplayClient: Sendable {
    public let executable: URL
    /// betterdisplaycli 只是个前端,BetterDisplay.app 不在时它什么都不回、
    /// 退出码还是 0。2026-09-06 早上机器重启后 app 没跟着起来,`curtain on`
    /// 就一直死在「没有显示器」上。所以拿不到显示器列表时,先把 app 拉起来再试。
    public let application: URL?
    /// 拉起 app 后最多等这么久让 CLI 通起来。
    public let launchWait: TimeInterval
    public let commandTimeout: TimeInterval
    /// 真正把 app 拉起来的动作。默认 `open -gj`;测试里换成空操作,免得真去开东西。
    public let launcher: @Sendable (URL) -> Void
    private let activeDisplayProvider: @Sendable () throws -> [Int]
    private let builtinDisplayProvider: @Sendable (Int) -> Bool

    public static let defaultLauncher: @Sendable (URL) -> Void = { application in
        _ = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-gj", application.path], timeout: 10)
    }

    public static let defaultActiveDisplayProvider: @Sendable () throws -> [Int] = {
        var count: UInt32 = 0
        let first = CGGetActiveDisplayList(0, nil, &count)
        guard first == .success else {
            throw BetterDisplayError.commandFailed("CGGetActiveDisplayList count failed: \(first.rawValue)")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let second = CGGetActiveDisplayList(count, &ids, &count)
        guard second == .success else {
            throw BetterDisplayError.commandFailed("CGGetActiveDisplayList failed: \(second.rawValue)")
        }
        return ids.prefix(Int(count)).map(Int.init)
    }

    public static let defaultBuiltinDisplayProvider: @Sendable (Int) -> Bool = {
        CGDisplayIsBuiltin(CGDirectDisplayID($0)) != 0
    }

    public init(executable: URL? = nil, application: URL? = URL(fileURLWithPath: "/Applications/BetterDisplay.app"),
                launchWait: TimeInterval = 10, commandTimeout: TimeInterval = 15,
                launcher: @escaping @Sendable (URL) -> Void = BetterDisplayClient.defaultLauncher,
                activeDisplayProvider: @escaping @Sendable () throws -> [Int] = BetterDisplayClient.defaultActiveDisplayProvider,
                builtinDisplayProvider: @escaping @Sendable (Int) -> Bool = BetterDisplayClient.defaultBuiltinDisplayProvider) throws {
        self.application = application
        self.launchWait = launchWait
        self.commandTimeout = commandTimeout
        self.launcher = launcher
        self.activeDisplayProvider = activeDisplayProvider
        self.builtinDisplayProvider = builtinDisplayProvider
        if let executable {
            self.executable = executable
            return
        }
        let candidates = [
            "/opt/homebrew/bin/betterdisplaycli",
            "/usr/local/bin/betterdisplaycli",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BetterDisplayError.executableNotFound
        }
        self.executable = URL(fileURLWithPath: path)
    }

    public func displayIDs() throws -> [Int] {
        try displays().map(\.displayID)
    }

    public func displays() throws -> [DisplayIdentity] {
        let result: CommandResult
        do {
            let initial = try checked(["get", "--identifiers"])
            result = initial.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try displayIDsAfterLaunchingApp() : initial
        } catch BetterDisplayError.commandTimedOut {
            result = try displayIDsAfterLaunchingApp()
        }
        let data = Data(result.stdout.utf8)
        let object: Any
        if let direct = try? JSONSerialization.jsonObject(with: data) {
            object = direct
        } else {
            let wrapped = Data(("[" + result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "]").utf8)
            guard let parsed = try? JSONSerialization.jsonObject(with: wrapped) else {
                throw BetterDisplayError.invalidDisplayList
            }
            object = parsed
        }

        let dictionaries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let dictionary = object as? [String: Any] {
            dictionaries = [dictionary]
        } else {
            throw BetterDisplayError.invalidDisplayList
        }
        let displays = dictionaries.compactMap { item -> DisplayIdentity? in
            let id = (item["displayID"] as? NSNumber)?.intValue
                ?? (item["displayID"] as? String).flatMap(Int.init)
            guard let id else { return nil }
            return DisplayIdentity(displayID: id, uuid: item["UUID"] as? String,
                isBuiltin: builtinDisplayProvider(id))
        }
        guard !displays.isEmpty else { throw BetterDisplayError.invalidDisplayList }
        return displays.sorted { $0.displayID < $1.displayID }
    }

    public func activeDisplays() throws -> [DisplayIdentity] {
        let active = Set(try activeDisplayProvider())
        return try displays().filter { active.contains($0.displayID) }
    }

    public func proAvailable() throws -> Bool {
        _ = try displays()
        let value = try feature("proAvailable")
        switch value.lowercased() {
        case "on", "true", "1": return true
        case "off", "false", "0": return false
        default: throw BetterDisplayError.invalidValue("proAvailable")
        }
    }

    public func feature(_ name: String, uuid: String? = nil) throws -> String {
        var arguments = ["get"]
        if let uuid { arguments.append("-UUID=\(uuid)") }
        arguments.append("-\(name)")
        let value = try checked(arguments).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BetterDisplayError.invalidValue(name) }
        return value
    }

    public func setFeature(_ name: String, value: String, uuid: String) throws {
        _ = try checked(["set", "-UUID=\(uuid)", "-\(name)=\(value)"])
    }

    /// Reconnection exposes displays before BetterDisplay has refreshed their mode.
    /// Wait for natural restoration before issuing one mode-changing write.
    public func restoreFeatureAfterSettling(_ name: String, value: String, uuid: String,
                                            settleTimeout: TimeInterval = 3) throws {
        func matchesAfterSettling() throws -> Bool {
            let deadline = Date().addingTimeInterval(settleTimeout)
            var stable = 0
            repeat {
                let actual = try feature(name, uuid: uuid)
                stable = actual == value ? stable + 1 : 0
                if stable >= 2 { return true }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            return false
        }
        if try matchesAfterSettling() { return }
        do { try setFeature(name, value: value, uuid: uuid) }
        catch {
            throw BetterDisplayError.commandFailed("\(name)=\(value) for \(uuid): \(error.localizedDescription)")
        }
        guard try matchesAfterSettling() else {
            throw BetterDisplayError.commandFailed("\(name) did not settle at \(value) for \(uuid)")
        }
    }

    public func disconnectAllButMain() throws {
        _ = try checked(["set", "-disconnectAllButMain"])
    }

    public func connectAllDisplays() throws {
        _ = try checked(["set", "-connectAllDisplays"])
    }

    public func waitForActiveDisplays(
        uuids expected: Set<String>,
        exact: Bool,
        timeout: TimeInterval = 15
    ) throws -> [DisplayIdentity] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [DisplayIdentity] = []
        repeat {
            last = try activeDisplays()
            let actual = Set(last.compactMap(\.uuid))
            if exact ? actual == expected : expected.isSubset(of: actual) { return last }
            usleep(250_000)
        } while Date() < deadline
        let actual = Set(last.compactMap(\.uuid)).sorted().joined(separator: ",")
        throw BetterDisplayError.commandFailed("display topology did not settle; active UUIDs: \(actual)")
    }

    public func waitForConnectionStates(
        _ expected: [String: Bool],
        timeout: TimeInterval = 15
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String] = [:]
        repeat {
            var matches = true
            for (uuid, wanted) in expected {
                let value = try feature("connected", uuid: uuid).lowercased()
                last[uuid] = value
                let connected = value == "on" || value == "true" || value == "1"
                if connected != wanted { matches = false }
            }
            if matches { return }
            usleep(250_000)
        } while Date() < deadline
        let summary = last.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        throw BetterDisplayError.commandFailed("display connections did not settle; \(summary)")
    }

    public func waitForMainDisplay(uuid: String, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            last = try feature("main", uuid: uuid).lowercased()
            if last == "on" || last == "true" || last == "1" { return }
            usleep(250_000)
        } while Date() < deadline
        throw BetterDisplayError.commandFailed(
            "main display did not settle; \(uuid)=\(last)"
        )
    }

    public func brightness(displayID: Int) throws -> Double {
        let result = try checked(["get", "-displayID=\(displayID)", "-brightness"])
        guard let value = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw BetterDisplayError.invalidBrightness(displayID)
        }
        return value
    }

    public func brightnessComponent(_ name: String, displayID: Int) throws -> Double {
        let result = try checked(["get", "-displayID=\(displayID)", "-\(name)"])
        guard let value = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw BetterDisplayError.invalidBrightness(displayID)
        }
        return value
    }

    public func restoreBrightnessComponent(_ name: String, displayID: Int, value: Double) throws {
        guard abs(try brightnessComponent(name, displayID: displayID) - value) > 0.01 else { return }
        let result = try checked(["set", "get", "-displayID=\(displayID)", "-\(name)=\(value)"])
        guard let readback = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              readback.isFinite, abs(readback - value) <= 0.01 else {
            throw BetterDisplayError.commandFailed("displayID=\(displayID) \(name) readback mismatch")
        }
    }

    public func setBrightness(displayID: Int, value: Double) throws {
        _ = try checked(["set", "-displayID=\(displayID)", "-brightness=\(value)"])
    }

    /// BetterDisplay supports combined operations, avoiding a second process for readback.
    public func setBrightnessAndReadback(displayID: Int, value: Double) throws -> Double {
        let result = try checked(["set", "get", "-displayID=\(displayID)", "-brightness=\(value)"])
        guard let readback = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), readback.isFinite else {
            throw BetterDisplayError.invalidBrightness(displayID)
        }
        return readback
    }

    /// CLI 空回答 = app 不在。装了就 `open -gj` 拉起来,轮询到它开口为止。
    private func displayIDsAfterLaunchingApp() throws -> CommandResult {
        guard let application, FileManager.default.fileExists(atPath: application.path) else {
            throw BetterDisplayError.appNotRunning(application?.path ?? "not installed")
        }
        launcher(application)
        let deadline = Date().addingTimeInterval(launchWait)
        while Date() < deadline {
            usleep(500_000)
            do {
                let retry = try checked(["get", "--identifiers"])
                if !retry.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return retry }
            } catch BetterDisplayError.commandTimedOut {
                continue
            }
        }
        throw BetterDisplayError.appNotRunning(application.path)
    }

    private func checked(_ arguments: [String]) throws -> CommandResult {
        let result = try CommandRunner.run(executable, arguments: arguments, timeout: commandTimeout)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BetterDisplayError.commandFailed(message.isEmpty ? "exit \(result.status)" : message)
        }
        return result
    }
}
