import Foundation

public struct CurtainPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var configDirectory: URL { home.appendingPathComponent(".config/curtain", isDirectory: true) }
    public var stateDirectory: URL { home.appendingPathComponent(".local/state/curtain", isDirectory: true) }
    public var allowlist: URL { configDirectory.appendingPathComponent("allowlist") }
    public var denylist: URL { configDirectory.appendingPathComponent("denylist") }
    public var controlSocket: URL { stateDirectory.appendingPathComponent("control.sock") }
    public var brightnessBackup: URL { stateDirectory.appendingPathComponent("brightness.json") }
    public var displaySessionBackup: URL { stateDirectory.appendingPathComponent("display-session.json") }
    public var windowSessionBackup: URL { stateDirectory.appendingPathComponent("window-session.json") }
    public var watchdogLog: URL { stateDirectory.appendingPathComponent("watchdog.log") }
    public var recoveryLock: URL { stateDirectory.appendingPathComponent("recovery.lock") }
    /// 见 CurtainExpectation —— 外部看护靠它判断幕帘是不是掉了。
    public var expectation: URL { stateDirectory.appendingPathComponent("expected") }
    public var injectionMarker: URL { stateDirectory.appendingPathComponent("injection-marker") }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }
}
