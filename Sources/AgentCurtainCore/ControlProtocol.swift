import Foundation

public enum ControlCommand: Equatable, Sendable {
    case draw(duration: TimeInterval?, allowAnyInjected: Bool)
    case open
    case status
    case reload
    case quit

    public static func parse(_ line: String) throws -> ControlCommand {
        let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard let verb = fields.first else { throw ControlProtocolError.emptyCommand }

        switch verb {
        case "off":
            guard fields.count == 1 else { throw ControlProtocolError.invalidArguments }
            return .open
        case "status":
            guard fields.count == 1 else { throw ControlProtocolError.invalidArguments }
            return .status
        case "reload":
            guard fields.count == 1 else { throw ControlProtocolError.invalidArguments }
            return .reload
        case "quit":
            guard fields.count == 1 else { throw ControlProtocolError.invalidArguments }
            return .quit
        case "on":
            var duration: TimeInterval?
            var allowAny = false
            for field in fields.dropFirst() {
                if field == "--allow-any-injected" {
                    guard !allowAny else { throw ControlProtocolError.invalidArguments }
                    allowAny = true
                } else if let value = TimeInterval(field), value > 0, duration == nil {
                    duration = value
                } else {
                    throw ControlProtocolError.invalidArguments
                }
            }
            return .draw(duration: duration, allowAnyInjected: allowAny)
        default:
            throw ControlProtocolError.unknownCommand
        }
    }
}

public enum ControlProtocolError: Error, LocalizedError {
    case emptyCommand
    case unknownCommand
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case .emptyCommand: return "empty command"
        case .unknownCommand: return "unknown command"
        case .invalidArguments: return "invalid arguments"
        }
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var state: String?
    public var displays: Int?
    public var activeDisplays: Int?
    public var displayMode: String?
    public var restorePending: Int?
    public var windowRestorePending: Int?
    public var windows: Int?
    public var restoredWindows: Int?
    public var displayBackend: String?
    public var betterDisplayPro: String?
    public var privateDisplaySPI: String?
    public var blocked: UInt64?
    public var allowed: UInt64?
    public var denied: Int?
    public var since: String?
    public var warning: String?
    public var error: String?

    public init(
        ok: Bool,
        state: String? = nil,
        displays: Int? = nil,
        activeDisplays: Int? = nil,
        displayMode: String? = nil,
        restorePending: Int? = nil,
        windowRestorePending: Int? = nil,
        windows: Int? = nil,
        restoredWindows: Int? = nil,
        displayBackend: String? = nil,
        betterDisplayPro: String? = nil,
        privateDisplaySPI: String? = nil,
        blocked: UInt64? = nil,
        allowed: UInt64? = nil,
        denied: Int? = nil,
        since: String? = nil,
        warning: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.state = state
        self.displays = displays
        self.activeDisplays = activeDisplays
        self.displayMode = displayMode
        self.restorePending = restorePending
        self.windowRestorePending = windowRestorePending
        self.windows = windows
        self.restoredWindows = restoredWindows
        self.displayBackend = displayBackend
        self.betterDisplayPro = betterDisplayPro
        self.privateDisplaySPI = privateDisplaySPI
        self.blocked = blocked
        self.allowed = allowed
        self.denied = denied
        self.since = since
        self.warning = warning
        self.error = error
    }

    public func jsonLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(self)) ?? Data("{\"ok\":false,\"error\":\"encoding failed\"}".utf8)) + Data([0x0A])
    }
}
