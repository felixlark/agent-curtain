import Foundation
import Testing
@testable import AgentCurtainCore

@Test func controlProtocolParsesCompatibleCommands() throws {
    #expect(try ControlCommand.parse("on") == .draw(duration: nil, allowAnyInjected: false))
    #expect(try ControlCommand.parse("on 60 --allow-any-injected") == .draw(duration: 60, allowAnyInjected: true))
    #expect(try ControlCommand.parse("off") == .open)
    #expect(try ControlCommand.parse("status") == .status)
    #expect(try ControlCommand.parse("quit") == .quit)
    #expect(throws: ControlProtocolError.self) { try ControlCommand.parse("on -1") }
    #expect(throws: ControlProtocolError.self) { try ControlCommand.parse("off now") }
}

@Test func denyAlwaysWinsAndPhysicalInputIsAlwaysBlocked() {
    let allowed: Set<Int32> = [42, 43]
    let denied: Set<Int32> = [43, 44]
    #expect(!InputDecision.shouldAllow(pid: 0, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
    #expect(InputDecision.shouldAllow(pid: 42, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: false))
    #expect(!InputDecision.shouldAllow(pid: 43, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
    #expect(InputDecision.shouldAllow(pid: 45, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
}

@Test func processNamesMatchExactlyRatherThanBySubstring() {
    let rule = ProcessRule("UURemoteServer")
    #expect(rule.matches(path: "/Applications/UURemote.app/Contents/Helpers/UURemoteServer"))
    #expect(!rule.matches(path: "/tmp/UURemoteServer-helper"))
}

@Test func configurationCreatesSecureDefaultDenylist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = CurtainPaths(home: root)
    let config = try CurtainConfiguration.load(from: paths)
    #expect(config.deniedRules == CurtainConfiguration.defaultDeniedRules)
    let attrs = try FileManager.default.attributesOfItem(atPath: paths.denylist.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func brightnessBackupRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("brightness.json")
    let backup = BrightnessBackup(ownerPID: 123, displays: [DisplayBrightness(displayID: 7, brightness: 0.75)])
    try BrightnessBackupStore.write(backup, to: url)
    #expect(try BrightnessBackupStore.read(from: url) == backup)
    let claimedURL = try BrightnessBackupStore.claim(url)
    let claimed = try #require(claimedURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try BrightnessBackupStore.relinquish(claimed, to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func expectationSurvivesUntilTheCurtainIsDeliberatelyOpened() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("curtain-expectation-\(UUID().uuidString)")
    let paths = CurtainPaths(home: root)
    try paths.prepareDirectories()
    let expectation = CurtainExpectation(paths: paths)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!expectation.isRecorded)

    let moment = Date(timeIntervalSince1970: 1_772_000_000)
    try expectation.record(at: moment)
    #expect(expectation.isRecorded)
    #expect(expectation.recordedAt.map { abs($0.timeIntervalSince(moment)) < 1 } == true)

    // 重复记录是幂等的：拉上已经拉上的幕帘不应该让判据变化。
    try expectation.record(at: moment)
    #expect(expectation.isRecorded)

    try expectation.clear()
    #expect(!expectation.isRecorded)
    #expect(expectation.recordedAt == nil)
    // 清除不存在的意图不能报错 —— open 会在任何 phase 下被调用。
    try expectation.clear()
}

// MARK: - 2026-09-06 的两处故障

private func socketPair() throws -> (server: Int32, client: Int32) {
    var fds: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (fds[0], fds[1])
}

@Test func lineReaderSurvivesInheritedNonBlockingFlagAndLateClient() throws {
    // 复现:监听 fd 的 O_NONBLOCK 被 accept 出来的连接继承,
    // 客户端的字节 300ms 后才到。旧实现在这里把 EAGAIN 当 EOF。
    let (server, client) = try socketPair()
    defer { close(server); close(client) }
    _ = fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK)

    let writer = Thread {
        usleep(300_000)
        _ = "status\n".withCString { send(client, $0, 7, 0) }
    }
    writer.start()
    #expect(ControlLineReader.readLine(from: server, timeout: 5) == .success("status"))
}

@Test func lineReaderDistinguishesEmptyTimeoutAndBadEncoding() throws {
    do {  // 对端什么都没发就关了 → 空命令,不是「不是 UTF-8」
        let (server, client) = try socketPair()
        close(client)
        defer { close(server) }
        #expect(ControlLineReader.readLine(from: server, timeout: 1) == .failure(.empty))
    }
    do {  // 对端一直不说话 → 超时,而且不会把服务端卡死
        let (server, client) = try socketPair()
        defer { close(server); close(client) }
        let started = Date()
        #expect(ControlLineReader.readLine(from: server, timeout: 0.3) == .failure(.timedOut))
        #expect(Date().timeIntervalSince(started) < 3)
    }
    do {  // 真的不是 UTF-8 才报这个
        let (server, client) = try socketPair()
        defer { close(server); close(client) }
        let bytes: [UInt8] = [0xFF, 0xFE, 0x0A]
        _ = bytes.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
        #expect(ControlLineReader.readLine(from: server, timeout: 1) == .failure(.notUTF8))
    }
}

/// 假的 betterdisplaycli:前 `mute` 次调用回空(模拟 app 没在跑),之后回一块显示器。
private func makeMutedFakeCLI(in root: URL, mute: Int) throws -> URL {
    let counter = root.appendingPathComponent("calls")
    let script = root.appendingPathComponent("fake-betterdisplaycli")
    try """
    #!/bin/zsh
    n=$(cat "\(counter.path)" 2>/dev/null || echo 0)
    n=$((n + 1)); echo $n > "\(counter.path)"
    if [[ "$*" == "get --identifiers" ]]; then
      (( n > \(mute) )) && echo '{"displayID":"7"}'
    fi
    exit 0
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@Test func betterDisplayClientLaunchesTheAppWhenTheCLIIsMute() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = try makeMutedFakeCLI(in: root, mute: 2)
    let app = root.appendingPathComponent("BetterDisplay.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

    final class Launches: @unchecked Sendable { var urls: [URL] = [] }
    let launches = Launches()
    let client = try BetterDisplayClient(executable: cli, application: app, launchWait: 5) { launches.urls.append($0) }

    #expect(try client.displayIDs() == [7])
    #expect(launches.urls == [app])   // 拉了一次,且拉的是给定的 app
}

@Test func betterDisplayClientRecoversWhenTheCLIInitiallyTimesOut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = root.appendingPathComponent("calls")
    let cli = root.appendingPathComponent("fake-betterdisplaycli")
    try """
    #!/bin/zsh
    n=$(cat "\(counter.path)" 2>/dev/null || echo 0)
    n=$((n + 1)); echo $n > "\(counter.path)"
    if (( n == 1 )); then sleep 1; else echo '{"displayID":"7"}'; fi
    """.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let app = root.appendingPathComponent("BetterDisplay.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

    final class Launches: @unchecked Sendable { var count = 0 }
    let launches = Launches()
    let client = try BetterDisplayClient(executable: cli, application: app,
        launchWait: 2, commandTimeout: 0.1) { _ in launches.count += 1 }

    #expect(try client.displayIDs() == [7])
    #expect(launches.count == 1)
}

@Test func betterDisplayClientExplainsWhenTheAppIsNotInstalled() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = try makeMutedFakeCLI(in: root, mute: 99)
    let missing = root.appendingPathComponent("nowhere/BetterDisplay.app")
    let client = try BetterDisplayClient(executable: cli, application: missing, launchWait: 1) { _ in }

    #expect(throws: BetterDisplayError.self) { try client.displayIDs() }
    do { _ = try client.displayIDs() } catch let error as BetterDisplayError {
        guard case .appNotRunning = error else { Issue.record("expected appNotRunning, got \(error)"); return }
    }
}
