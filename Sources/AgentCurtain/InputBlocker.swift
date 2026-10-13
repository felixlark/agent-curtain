import AgentCurtainCore
import ApplicationServices
import Foundation

final class InputBlocker {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var refreshTimer: Timer?
    private var allowedRules: [String] = []
    private var deniedRules: [String] = []
    private var allowedPIDs = Set<Int32>()
    private var deniedPIDs = Set<Int32>()
    private var injectionMarker: Int64?
    private var blockedCount: UInt64 = 0
    private var allowedCount: UInt64 = 0

    var onReleaseHotkey: (() -> Void)?

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start(configuration: CurtainConfiguration, injectionMarker: Int64?) throws {
        precondition(Thread.isMainThread)
        guard tap == nil else { return }
        self.injectionMarker = injectionMarker
        update(configuration: configuration)

        let mask = Self.blockedEventTypes.reduce(CGEventMask(0)) { result, type in
            result | (CGEventMask(1) << type.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let blocker = Unmanaged<InputBlocker>.fromOpaque(userInfo).takeUnretainedValue()
                return blocker.handle(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            throw InputBlockerError.cannotCreateEventTap
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tap = newTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshPIDs()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        lock.lock()
        allowedPIDs.removeAll()
        deniedPIDs.removeAll()
        injectionMarker = nil
        lock.unlock()
    }

    func update(configuration: CurtainConfiguration) {
        allowedRules = configuration.allowedRules
        deniedRules = configuration.deniedRules
        refreshPIDs()
    }

    func counters() -> (blocked: UInt64, allowed: UInt64, allowedPIDs: Int, deniedPIDs: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (blockedCount, allowedCount, allowedPIDs.count, deniedPIDs.count)
    }

    private func refreshPIDs() {
        let processes = ProcessResolver.snapshot()
        let allowed = ProcessResolver.matchingPIDs(rules: allowedRules, processes: processes)
        let denied = ProcessResolver.matchingPIDs(rules: deniedRules, processes: processes)
        lock.lock()
        allowedPIDs = allowed
        deniedPIDs = denied
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == 32,
           Self.hasAllCurtainModifiers(event.flags) {
            DispatchQueue.main.async { [weak self] in self?.onReleaseHotkey?() }
            return nil
        }

        let pid = Int32(event.getIntegerValueField(.eventSourceUnixProcessID))
        lock.lock()
        let allowed = InputDecision.shouldAllow(
            pid: pid,
            allowedPIDs: allowedPIDs,
            deniedPIDs: deniedPIDs,
            injectionMarker: injectionMarker,
            eventMarker: event.getIntegerValueField(.eventSourceUserData)
        )
        if allowed { allowedCount += 1 } else { blockedCount += 1 }
        lock.unlock()
        return allowed ? Unmanaged.passUnretained(event) : nil
    }

    static func hasAllCurtainModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && flags.contains(.maskCommand)
    }

    private static let blockedEventTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged,
        .scrollWheel, .mouseMoved,
    ]
}

enum InputBlockerError: Error, LocalizedError {
    case cannotCreateEventTap

    var errorDescription: String? {
        "cannot create the HID event tap; enable AgentCurtain in System Settings > Privacy & Security > Accessibility"
    }
}
