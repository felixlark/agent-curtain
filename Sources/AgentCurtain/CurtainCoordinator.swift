import AgentCurtainCore
import Foundation

final class CurtainCoordinator {
    enum Phase: String {
        case starting
        case open
        case drawing
        case drawn
        case opening
    }

    private let paths: CurtainPaths
    private let blocker = InputBlocker()
    private let banners = BannerController()
    private let brightness: BrightnessController
    private let displaySession: DisplaySessionController
    private let windowSession: WindowSessionController
    private let expectation: CurtainExpectation
    private let worker = DispatchQueue(label: "com.longbiaochen.AgentCurtain.operations")
    private var configuration = CurtainConfiguration(allowedRules: [], deniedRules: [])
    private var autoOpenTimer: Timer?
    private var drawCancellation: CurtainCancellation?
    private var screenReconcileWorkItem: DispatchWorkItem?
    private var screenReconcileCancellation: CurtainCancellation?
    private var pendingOpenCompletions: [(ControlResponse) -> Void] = []

    private(set) var phase: Phase = .starting
    private(set) var since: Date?
    private(set) var injectionMarker: Int64?
    private(set) var displayCount = 0
    private(set) var activeDisplayCount = 0
    private(set) var lastError: String?
    /// Diagnostics from the last recovery. These never make an operation fail, but
    /// they are surfaced so a completed recovery is still auditable.
    private(set) var recoveryWarnings: [String] = []
    var recoveryWarning: String? {
        let all = ([windowSession.recoveryWarning, brightness.lastRecoveryWarning] + recoveryWarnings)
            .compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }
    var onChange: (() -> Void)?

    init(paths: CurtainPaths) {
        self.paths = paths
        brightness = BrightnessController(paths: paths)
        displaySession = DisplaySessionController(paths: paths)
        windowSession = WindowSessionController(paths: paths)
        expectation = CurtainExpectation(paths: paths)
        blocker.onReleaseHotkey = { [weak self] in self?.open(completion: { _ in }) }
        banners.onScreensChanged = { [weak self] in self?.screensChanged() }
    }

    func prepare(completion: @escaping () -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            var nextConfiguration: CurtainConfiguration?
            var messages: [String] = []
            var startupWarnings: [String] = []
            do { nextConfiguration = try CurtainConfiguration.load(from: self.paths) }
            catch { messages.append("configuration: \(error.localizedDescription)") }
            do { try InjectionMarkerStore.clear(at: self.paths.injectionMarker) }
            catch { messages.append("injection marker: \(error.localizedDescription)") }

            do {
                let recoveryLock = try RecoveryTransactionLock(url: self.paths.recoveryLock)
                let restoration = withExtendedLifetime(recoveryLock) {
                    self.restoreProtectionStateLocked()
                }
                if let error = restoration.error { messages.append(error.localizedDescription) }
                startupWarnings = restoration.warnings
            } catch { messages.append("recovery lock: \(error.localizedDescription)") }

            self.displaySession.refreshBackendDiagnostics()
            var activeDisplayCount: Int?
            do { activeDisplayCount = try self.displaySession.currentActiveDisplayCount() }
            catch {
                // Diagnostics only: an unreadable count must not fail startup.
                startupWarnings.append("active displays: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                if let nextConfiguration { self.configuration = nextConfiguration }
                if let activeDisplayCount { self.activeDisplayCount = activeDisplayCount }
                self.recoveryWarnings = startupWarnings
                self.phase = .open
                self.lastError = messages.isEmpty
                    ? nil
                    : "startup recovery failed: \(messages.joined(separator: "; "))"
                self.changed()
                completion()
            }
        }
    }

    func handle(_ command: ControlCommand, completion: @escaping (ControlResponse) -> Void) {
        switch command {
        case .draw(let duration, let injectionMarker):
            draw(duration: duration, injectionMarker: injectionMarker, completion: completion)
        case .open:
            open(completion: completion)
        case .status:
            completion(response(ok: lastError == nil))
        case .reload:
            reload(completion: completion)
        case .quit:
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "quit must be handled by the app delegate"))
        }
    }

    func draw(
        duration: TimeInterval? = nil,
        injectionMarker: Int64? = nil,
        completion: @escaping (ControlResponse) -> Void
    ) {
        precondition(Thread.isMainThread)
        if phase == .drawn {
            completion(response(ok: true))
            return
        }
        guard phase == .open else {
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "curtain transition already in progress"))
            return
        }
        guard InputBlocker.isAccessibilityTrusted(prompt: true) else {
            lastError = "Accessibility permission is required for AgentCurtain"
            changed()
            completion(ControlResponse(ok: false, state: "open", error: lastError))
            return
        }
        if injectionMarker == 0 {
            completion(ControlResponse(ok: false, state: "open", error: "injection marker must be nonzero"))
            return
        }

        phase = .drawing
        lastError = nil
        let cancellation = CurtainCancellation()
        drawCancellation = cancellation
        banners.show(.enabling)
        changed()
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let count = try self.displaySession.capture()
                _ = try self.windowSession.capture()
                _ = try self.brightness.dimAllDisplays(
                    displaySessionBackup: self.paths.displaySessionBackup,
                    isCancelled: { cancellation.isCancelled }
                )
                DispatchQueue.main.async {
                    guard self.phase == .drawing, self.drawCancellation === cancellation else {
                        completion(ControlResponse(ok: false, state: self.phase.rawValue, error: "draw was cancelled"))
                        return
                    }
                    do {
                        if let injectionMarker {
                            try InjectionMarkerStore.write(injectionMarker, to: self.paths.injectionMarker)
                        } else {
                            try InjectionMarkerStore.clear(at: self.paths.injectionMarker)
                        }
                        self.injectionMarker = injectionMarker
                        try self.blocker.start(
                            configuration: self.configuration,
                            injectionMarker: injectionMarker
                        )
                        self.worker.async {
                            do {
                                _ = try self.displaySession.disconnectExternalDisplays(
                                    isCancelled: { cancellation.isCancelled }
                                )
                                DispatchQueue.main.async {
                                    guard self.phase == .drawing,
                                          self.drawCancellation === cancellation else {
                                        completion(ControlResponse(ok: false, state: self.phase.rawValue,
                                            error: "draw was cancelled"))
                                        return
                                    }
                                    self.banners.show(injectionMarker == nil ? .protected : .markerProtected)
                                    self.displayCount = count
                                    self.activeDisplayCount = 1
                                    self.since = Date()
                                    self.phase = .drawn
                                    self.drawCancellation = nil
                                    try? self.expectation.record()
                                    self.scheduleAutomaticOpen(after: duration)
                                    self.changed()
                                    completion(self.response(ok: true))
                                }
                            } catch {
                                DispatchQueue.main.async {
                                    self.failDrawing(error, completion: completion)
                                }
                            }
                        }
                    } catch {
                        self.failDrawing(error, completion: completion)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.failDrawing(error, completion: completion)
                }
            }
        }
    }

    func open(completion: @escaping (ControlResponse) -> Void) {
        precondition(Thread.isMainThread)
        var markerClearError: Error?
        if phase != .starting {
            injectionMarker = nil
            do { try InjectionMarkerStore.clear(at: paths.injectionMarker) }
            catch { markerClearError = error }
        }
        if phase == .open && lastError == nil {
            if let markerClearError {
                completion(ControlResponse(ok: false, state: phase.rawValue,
                    error: "cannot clear injection marker: \(markerClearError.localizedDescription)"))
            } else {
                completion(response(ok: true))
            }
            return
        }
        if phase == .starting {
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "AgentCurtain is still starting"))
            return
        }
        pendingOpenCompletions.append(completion)
        if phase == .opening { return }

        phase = .opening
        drawCancellation?.cancel()
        drawCancellation = nil
        screenReconcileWorkItem?.cancel()
        screenReconcileWorkItem = nil
        screenReconcileCancellation?.cancel()
        screenReconcileCancellation = nil
        banners.show(.disabling)
        // 主动拉开才清除意图。崩溃、被卸载、被替换都到不了这里 ——
        // 那正是看护要认出来的情况。
        try? expectation.clear()
        autoOpenTimer?.invalidate()
        autoOpenTimer = nil
        blocker.stop()
        changed()
        let cleanupError = markerClearError
        worker.async { [weak self] in
            guard let self else { return }
            let restoration = self.restoreProtectionState()
            let errors = [restoration.error?.localizedDescription, cleanupError?.localizedDescription].compactMap { $0 }
            DispatchQueue.main.async {
                self.recoveryWarnings = restoration.warnings
                self.finishOpening(
                    restoreError: errors.isEmpty ? nil : CurtainRecoveryError(messages: errors),
                    restoredActiveDisplayCount: restoration.activeDisplayCount
                )
            }
        }
    }

    private func failDrawing(_ error: Error, completion: @escaping (ControlResponse) -> Void) {
        guard phase == .drawing else {
            completion(ControlResponse(ok: false, state: phase.rawValue, error: error.localizedDescription))
            return
        }
        phase = .opening
        drawCancellation?.cancel()
        drawCancellation = nil
        blocker.stop()
        injectionMarker = nil
        try? InjectionMarkerStore.clear(at: paths.injectionMarker)
        lastError = error.localizedDescription
        banners.show(.disabling)
        changed()
        worker.async { [weak self] in
            guard let self else { return }
            let restoration = self.restoreProtectionState()
            DispatchQueue.main.async {
                self.recoveryWarnings = restoration.warnings
                self.finishOpening(
                    restoreError: restoration.error,
                    operationError: error,
                    restoredActiveDisplayCount: restoration.activeDisplayCount
                )
                completion(ControlResponse(ok: false, state: "open", error: self.lastError))
            }
        }
    }

    private struct RestorationOutcome {
        var error: Error?
        var activeDisplayCount: Int?
        var warnings: [String] = []
    }

    private func restoreProtectionState() -> RestorationOutcome {
        do {
            let recoveryLock = try RecoveryTransactionLock(url: paths.recoveryLock)
            return withExtendedLifetime(recoveryLock) { restoreProtectionStateLocked() }
        } catch {
            return RestorationOutcome(error: error)
        }
    }

    private func restoreProtectionStateLocked() -> RestorationOutcome {
        var messages: [String] = []
        var warnings: [String] = []
        var displaysRestored = true
        do { try displaySession.restoreAllDisplays() }
        catch {
            displaysRestored = false
            messages.append("display restore: \(error.localizedDescription)")
        }
        if let retirement = displaySession.lastRestoreWarning {
            warnings.append(retirement)
        }
        do { try brightness.restoreAllDisplays() }
        catch { messages.append("brightness restore: \(error.localizedDescription)") }
        if displaysRestored {
            // Windows saved on a retired display cannot be placed again. Passing the
            // retired set lets the window path retire them instead of pending forever.
            do { _ = try windowSession.restoreAllWindows(
                retiredDisplays: displaySession.lastRetiredDisplays) }
            catch { messages.append("window restore: \(error.localizedDescription)") }
        }
        var activeCount: Int?
        do { activeCount = try displaySession.currentActiveDisplayCount() }
        catch {
            // The displays, brightness and windows have already been restored. Reading
            // the resulting count back is diagnostics, so a failure here is recorded as
            // a warning instead of reporting a completed recovery as an operation failure.
            warnings.append("active displays: \(error.localizedDescription)")
        }
        return RestorationOutcome(
            error: messages.isEmpty ? nil : CurtainRecoveryError(messages: messages),
            activeDisplayCount: activeCount,
            warnings: warnings)
    }

    private func finishOpening(
        restoreError: Error?,
        operationError: Error? = nil,
        restoredActiveDisplayCount: Int? = nil
    ) {
        let restoredDisplayCount = displayCount
        phase = .open
        since = nil
        displayCount = 0
        if let restoredActiveDisplayCount {
            activeDisplayCount = restoredActiveDisplayCount
        } else if restoreError == nil && restoredDisplayCount > 0 {
            activeDisplayCount = restoredDisplayCount
        }
        drawCancellation = nil
        let errors = [operationError?.localizedDescription, restoreError?.localizedDescription].compactMap { $0 }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        if lastError == nil {
            banners.finishRelease()
        } else {
            banners.show(.failed)
        }
        changed()
        // A release/quit can arrive during rollback as well as normal opening.
        let response = response(ok: restoreError == nil)
        let callbacks = pendingOpenCompletions
        pendingOpenCompletions.removeAll()
        callbacks.forEach { $0(response) }
    }

    func reload(completion: @escaping (ControlResponse) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let config = try CurtainConfiguration.load(from: self.paths)
                DispatchQueue.main.async {
                    self.configuration = config
                    if self.phase == .drawn { self.blocker.update(configuration: config) }
                    self.changed()
                    completion(self.response(ok: true))
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.changed()
                    completion(ControlResponse(ok: false, state: self.phase.rawValue, error: error.localizedDescription))
                }
            }
        }
    }

    func response(ok: Bool) -> ControlResponse {
        let counters = blocker.counters()
        let stableState = phase == .drawn ? "drawn" : (phase == .open ? "open" : phase.rawValue)
        let restorePending = displaySession.pendingRestoreCount
        return ControlResponse(
            ok: ok,
            state: stableState,
            injectionMarker: injectionMarker,
            displays: displayCount,
            activeDisplays: activeDisplayCount,
            displayMode: phase == .drawn ? "internal-only" : (restorePending > 0 ? "restore-pending" : "all-displays"),
            restorePending: restorePending,
            windowRestorePending: windowSession.pendingRestoreCount,
            windows: windowSession.lastCapturedCount,
            restoredWindows: windowSession.lastRestoredCount,
            displayBackend: displaySession.displayBackendStatus,
            betterDisplayPro: displaySession.betterDisplayProStatus,
            privateDisplaySPI: displaySession.privateDisplaySPIStatus,
            blocked: counters.blocked,
            allowed: counters.allowed,
            denied: counters.deniedPIDs,
            since: since.map { ISO8601DateFormatter().string(from: $0) },
            warning: recoveryWarning,
            error: ok ? nil : lastError
        )
    }

    var statusSummary: String {
        let counters = blocker.counters()
        switch phase {
        case .drawn:
            let title = injectionMarker == nil ? "屏幕关闭·输入锁定" : "屏幕关闭·仅放行注入"
            return "\(title) · 仅内屏 · 阻断 \(counters.blocked) · 放行 \(counters.allowed)"
        case .open:
            return lastError.map { "操作未完成 · \($0)" } ?? "已解除保护"
        case .starting: return "正在启动…"
        case .drawing: return "启用保护中…"
        case .opening: return "解除保护中…"
        }
    }

    private func scheduleAutomaticOpen(after duration: TimeInterval?) {
        autoOpenTimer?.invalidate()
        guard let duration else { return }
        autoOpenTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.open(completion: { _ in })
        }
    }

    private func screensChanged() {
        guard phase == .drawn else { return }
        screenReconcileWorkItem?.cancel()
        screenReconcileCancellation?.cancel()
        let cancellation = CurtainCancellation()
        screenReconcileCancellation = cancellation
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.worker.async {
                guard !cancellation.isCancelled else { return }
                do {
                    let count = try self.brightness.dimNewDisplays()
                    guard !cancellation.isCancelled else { return }
                    let managedCount = try self.displaySession.reconcileNewDisplays()
                    DispatchQueue.main.async {
                        guard self.phase == .drawn, !cancellation.isCancelled else { return }
                        self.displayCount = max(count, managedCount)
                        self.activeDisplayCount = 1
                        self.changed()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard !cancellation.isCancelled else { return }
                        self.lastError = "display reconciliation failed: \(error.localizedDescription)"
                        self.changed()
                    }
                }
            }
        }
        screenReconcileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func changed() {
        onChange?()
    }
}

private struct CurtainRecoveryError: Error, LocalizedError {
    let messages: [String]
    var errorDescription: String? { messages.joined(separator: "; ") }
}

private final class CurtainCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
