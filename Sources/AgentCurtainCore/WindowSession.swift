import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public struct WindowSessionRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    public func isNear(_ other: WindowSessionRect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}

public struct WindowDisplayGeometry: Codable, Equatable, Sendable {
    public let uuid: String
    public let bounds: WindowSessionRect
    public let isBuiltin: Bool

    public init(uuid: String, bounds: WindowSessionRect, isBuiltin: Bool) {
        self.uuid = uuid
        self.bounds = bounds
        self.isBuiltin = isBuiltin
    }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public let ownerPID: Int32
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowID: UInt32?
    public let identifier: String?
    public let title: String?
    public let role: String
    public let subrole: String
    public let ordinal: Int
    public let displayUUID: String
    public let frame: WindowSessionRect
    public let relativeFrame: WindowSessionRect

    public init(
        ownerPID: Int32,
        bundleIdentifier: String?,
        applicationName: String,
        windowID: UInt32?,
        identifier: String?,
        title: String?,
        role: String,
        subrole: String,
        ordinal: Int,
        displayUUID: String,
        frame: WindowSessionRect,
        relativeFrame: WindowSessionRect
    ) {
        self.ownerPID = ownerPID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowID = windowID
        self.identifier = identifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.ordinal = ordinal
        self.displayUUID = displayUUID
        self.frame = frame
        self.relativeFrame = relativeFrame
    }
}

public struct WindowSessionBackup: Codable, Equatable, Sendable {
    public let version: Int
    public let ownerPID: Int32
    public let createdAt: Date
    public let displays: [WindowDisplayGeometry]
    public let windows: [SavedWindow]

    public init(
        ownerPID: Int32,
        createdAt: Date = Date(),
        displays: [WindowDisplayGeometry],
        windows: [SavedWindow]
    ) {
        version = 1
        self.ownerPID = ownerPID
        let milliseconds = (createdAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        self.createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.displays = displays
        self.windows = windows
    }
}

public enum WindowSessionBackupStore {
    public static func write(_ backup: WindowSessionBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A new explicit draw supersedes old window placement, never hardware recovery.
    /// Copy evidence before atomically publishing the fresh snapshot. On failure the
    /// old active record remains available; archived records are never auto-replayed.
    public static func beginSession(_ backup: WindowSessionBackup, at url: URL) throws -> URL? {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let claims = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("window-session.json.restoring.") }
        let recoverable = RecoveryClaimFiles.recoverable(in: directory, prefix: "window-session.json.restoring.")
        guard Set(claims).isSubset(of: Set(recoverable)) else {
            throw WindowSessionError.restoreFailures(["another process is restoring windows"])
        }
        let prior = (fm.fileExists(atPath: url.path) ? [url] : []) + recoverable
        var archive: URL?
        if !prior.isEmpty {
            let destination = directory.appendingPathComponent("window-history/\(UUID().uuidString)")
            try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            for source in prior {
                let copy = destination.appendingPathComponent(source.lastPathComponent)
                try fm.copyItem(at: source, to: copy)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            archive = destination
        }
        // Retire abandoned claims only after every record has been preserved.
        // If publication then fails, the original remains and claims are in history.
        for claim in recoverable { try fm.removeItem(at: claim) }
        try write(backup, to: url)
        return archive
    }

    public static func read(from url: URL) throws -> WindowSessionBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WindowSessionBackup.self, from: Data(contentsOf: url))
    }

    public static func claim(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let claimed = URL(fileURLWithPath: url.path + ".restoring.\(getpid())")
        do {
            try FileManager.default.moveItem(at: url, to: claimed)
            return claimed
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        }
    }

    public static func relinquish(_ claimed: URL, to original: URL) throws {
        guard FileManager.default.fileExists(atPath: claimed.path) else { return }
        try FileManager.default.moveItem(at: claimed, to: original)
    }
}

public struct WindowMatchCandidate: Equatable, Sendable {
    public let windowID: UInt32?
    public let identifier: String?
    public let title: String?
    public let role: String
    public let subrole: String
    public let ordinal: Int

    public init(
        windowID: UInt32?,
        identifier: String?,
        title: String?,
        role: String,
        subrole: String,
        ordinal: Int
    ) {
        self.windowID = windowID
        self.identifier = identifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.ordinal = ordinal
    }
}

public enum WindowSessionPlanner {
    public static func shouldManageWindow(bundleIdentifier: String?, subrole: String, hasScreenWindow: Bool) -> Bool {
        // macOS owns menu-bar geometry. AX exposes these as movable dialogs,
        // but WindowServer immediately relocates them after our writes.
        if bundleIdentifier == "com.apple.MenuBarAgent" { return false }
        // Transient AX dialogs without a layer-zero WindowServer window are not
        // desktop windows; they can disappear or change identity during reflow.
        return subrole != kAXDialogSubrole as String || hasScreenWindow
    }

    public static func isOriginalProcess(launchDate: Date?, capturedAt: Date) -> Bool {
        guard let launchDate else { return false }
        return launchDate <= capturedAt
    }

    // A spanning window may have its center in a gap. Use largest overlap, and
    // include the built-in display because main-display changes also move its windows.
    public static func captureDisplay(for frame: WindowSessionRect, displays: [WindowDisplayGeometry]) -> WindowDisplayGeometry? {
        displays.filter { frame.cgRect.intersects($0.bounds.cgRect) }.max {
            let left = frame.cgRect.intersection($0.bounds.cgRect)
            let right = frame.cgRect.intersection($1.bounds.cgRect)
            return left.width * left.height < right.width * right.height
        }
    }

    public static func relativeFrame(_ frame: WindowSessionRect, in display: WindowSessionRect) -> WindowSessionRect {
        guard display.width > 0, display.height > 0 else { return frame }
        return WindowSessionRect(
            x: (frame.x - display.x) / display.width,
            y: (frame.y - display.y) / display.height,
            width: frame.width / display.width,
            height: frame.height / display.height
        )
    }

    public static func targetFrame(for saved: SavedWindow, on display: WindowDisplayGeometry) -> WindowSessionRect {
        if let original = savedDisplayBounds(for: saved), original.isNear(display.bounds, tolerance: 0.5) {
            return saved.frame
        }
        let relative = saved.relativeFrame
        return WindowSessionRect(
            x: (display.bounds.x + relative.x * display.bounds.width).rounded(),
            y: (display.bounds.y + relative.y * display.bounds.height).rounded(),
            width: max(1, (relative.width * display.bounds.width).rounded()),
            height: max(1, (relative.height * display.bounds.height).rounded())
        )
    }

    public static func frameFittingVisibleArea(_ target: WindowSessionRect, in visible: WindowSessionRect) -> WindowSessionRect {
        let width = min(target.width, visible.width)
        let height = min(target.height, visible.height)
        return WindowSessionRect(
            x: min(max(target.x, visible.x), visible.x + visible.width - width),
            y: min(max(target.y, visible.y), visible.y + visible.height - height),
            width: width,
            height: height
        )
    }

    /// Split restore targets by whether their saved display returned. A single
    /// missing display must not block windows on the displays that are present.
    public static func partitionRestoreTargets(
        _ windows: [SavedWindow],
        availableUUIDs: Set<String>
    ) -> (restorable: [SavedWindow], stranded: [SavedWindow]) {
        var restorable: [SavedWindow] = []
        var stranded: [SavedWindow] = []
        for window in windows {
            if availableUUIDs.contains(window.displayUUID) {
                restorable.append(window)
            } else {
                stranded.append(window)
            }
        }
        return (restorable, stranded)
    }

    /// A window whose display was retired can never be placed again. Its record is
    /// dropped from the pending snapshot and reported, so the remaining windows can
    /// still be restored and the pending count does not stick.
    public static func retireStrandedWindows(
        _ stranded: [SavedWindow],
        retiredDisplays: Set<String>
    ) -> (retired: [RetiredWindow], stillPending: [SavedWindow]) {
        var retired: [RetiredWindow] = []
        var pending: [SavedWindow] = []
        for window in stranded {
            if retiredDisplays.contains(window.displayUUID) {
                retired.append(RetiredWindow(applicationName: window.applicationName,
                    windowID: window.windowID, ordinal: window.ordinal,
                    displayUUID: window.displayUUID))
            } else {
                pending.append(window)
            }
        }
        return (retired, pending)
    }

    /// Decide whether a saved window that matched no live candidate is gone.
    /// Window identity is only trustworthy inside the same process. Without a
    /// WindowServer identity there is nothing to look the window up by, so only a
    /// genuine shortfall proves it disappeared: the application still reports
    /// windows and every one of them is already claimed by another saved window.
    /// An empty live list may just mean the application has not rebuilt its
    /// windows yet, so it stays pending for the next unlock.
    public static func unmatchedWindowDisappeared(
        _ saved: SavedWindow,
        sameProcess: Bool,
        liveWindowIDs: Set<UInt32>,
        liveCount: Int,
        matchedCount: Int
    ) -> Bool {
        guard sameProcess else { return false }
        if let windowID = saved.windowID { return !liveWindowIDs.contains(windowID) }
        return liveCount > 0 && matchedCount == liveCount
    }

    /// Some applications clamp a window so it fits their usable area (menu bar,
    /// Dock, minimum size) and ignore the remainder of the write. Retrying cannot
    /// converge. The signature is a target that protrudes past the usable area
    /// while the settled frame fits inside it.
    public static func isClampLimited(
        target: WindowSessionRect,
        actual: WindowSessionRect,
        visible: WindowSessionRect,
        tolerance: Double = 2
    ) -> Bool {
        func fits(_ rect: WindowSessionRect) -> Bool {
            rect.x >= visible.x - tolerance &&
                rect.y >= visible.y - tolerance &&
                rect.x + rect.width <= visible.x + visible.width + tolerance &&
                rect.y + rect.height <= visible.y + visible.height + tolerance
        }
        return !fits(target) && fits(actual)
    }

    public static func matches(
        saved: [SavedWindow],
        candidates: [WindowMatchCandidate],
        trustWindowIDs: Bool = true
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var unused = Set(candidates.indices)

        func assign(where predicate: (SavedWindow, WindowMatchCandidate) -> Bool) {
            for savedIndex in saved.indices where result[savedIndex] == nil {
                let matches = unused.filter { predicate(saved[savedIndex], candidates[$0]) }
                guard matches.count == 1, let candidateIndex = matches.first else { continue }
                result[savedIndex] = candidateIndex
                unused.remove(candidateIndex)
            }
        }

        assign { saved, candidate in
            trustWindowIDs && saved.windowID != nil && saved.windowID == candidate.windowID &&
                compatible(saved, candidate)
        }
        assign { saved, candidate in
            nonempty(saved.identifier) != nil && saved.identifier == candidate.identifier &&
                compatible(saved, candidate)
        }
        assign { saved, candidate in
            nonempty(saved.title) != nil && saved.title == candidate.title && compatible(saved, candidate)
        }

        // AX returns windows in stable application order during a display topology change.
        // Use that order only when no windows appeared or disappeared in this application.
        if trustWindowIDs && saved.count == candidates.count {
            assign { saved, candidate in
                saved.ordinal == candidate.ordinal && compatible(saved, candidate)
            }
        }
        return result
    }

    private static func compatible(_ saved: SavedWindow, _ candidate: WindowMatchCandidate) -> Bool {
        saved.role == candidate.role && saved.subrole == candidate.subrole
    }

    private static func savedDisplayBounds(for saved: SavedWindow) -> WindowSessionRect? {
        let relative = saved.relativeFrame
        guard relative.width != 0, relative.height != 0 else { return nil }
        let width = saved.frame.width / relative.width
        let height = saved.frame.height / relative.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return WindowSessionRect(
            x: saved.frame.x - relative.x * width,
            y: saved.frame.y - relative.y * height,
            width: width,
            height: height
        )
    }
}

public struct WindowRestorationReport: Equatable, Sendable {
    public let saved: Int
    public let restored: Int
    public let disappeared: Int
    public let excluded: Int
    public let remaining: [SavedWindow]
    public let failures: [String]
    /// Windows whose application clamped the frame after we asked for the saved one.
    /// They are restored (not pending), but the shortfall is recorded rather than
    /// hidden: retrying the same write can never converge.
    public let deviations: [String]
    /// Windows dropped because their saved display no longer exists. They kept the
    /// snapshot pending forever, so the shortfall is recorded and retired.
    public let retiredWindows: [RetiredWindow]

    public init(saved: Int, restored: Int, disappeared: Int, excluded: Int = 0,
                remaining: [SavedWindow] = [], failures: [String] = [],
                deviations: [String] = [], retiredWindows: [RetiredWindow] = []) {
        self.saved = saved
        self.restored = restored
        self.disappeared = disappeared
        self.excluded = excluded
        self.remaining = remaining
        self.failures = failures
        self.deviations = deviations
        self.retiredWindows = retiredWindows
    }
}

public enum WindowSessionError: Error, LocalizedError {
    case accessibilityPermission
    case noActiveDisplays
    case missingDisplays([String])
    case restoreFailures([String])

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            return "Accessibility permission is required to restore window positions"
        case .noActiveDisplays:
            return "no active displays are available for window capture"
        case .missingDisplays(let uuids):
            return "saved window displays are unavailable: \(uuids.joined(separator: ", "))"
        case .restoreFailures(let failures):
            return "window restore failed: \(failures.joined(separator: "; "))"
        }
    }
}

public enum WindowSessionOperations {
    public static func processStartTime(pid: Int32) -> Date? { ProcessStartTime.read(pid: pid) }

    public static var activeDisplayUUIDs: Set<String> {
        Set(activeDisplayGeometries().map(\.uuid))
    }

    public static func capture(ownerPID: Int32, excludingBundleIdentifier: String? = nil) throws -> WindowSessionBackup {
        guard AXIsProcessTrusted() else { throw WindowSessionError.accessibilityPermission }
        let displays = activeDisplayGeometries()
        guard !displays.isEmpty else { throw WindowSessionError.noActiveDisplays }
        let cgWindows = cgWindowSnapshots()
        var saved: [SavedWindow] = []

        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0,
                  application.bundleIdentifier != excludingBundleIdentifier,
                  application.activationPolicy != .prohibited else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            let windows = axWindows(in: appElement)
            for (ordinal, window) in windows.enumerated() {
                guard isRestorableWindow(window),
                      axBool(window, kAXMinimizedAttribute as CFString) != true,
                      axBool(window, "AXFullScreen" as CFString) != true,
                      let frame = axWindowFrame(window),
                      let display = WindowSessionPlanner.captureDisplay(for: frame, displays: displays) else { continue }
                let metadata = matchCGWindow(
                    pid: pid,
                    frame: frame,
                    title: axString(window, kAXTitleAttribute as CFString),
                    snapshots: cgWindows
                )
                // A definite offscreen CG window belongs to another Space. Missing CG metadata
                // is not enough reason to discard an otherwise movable AX window.
                guard metadata?.isOnscreen != false,
                      WindowSessionPlanner.shouldManageWindow(bundleIdentifier: application.bundleIdentifier,
                        subrole: axString(window, kAXSubroleAttribute as CFString) ?? "",
                        hasScreenWindow: metadata != nil) else { continue }
                saved.append(SavedWindow(
                    ownerPID: pid,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.localizedName ?? application.bundleIdentifier ?? "pid \(pid)",
                    windowID: metadata?.windowID,
                    identifier: axString(window, kAXIdentifierAttribute as CFString),
                    title: axString(window, kAXTitleAttribute as CFString),
                    role: axString(window, kAXRoleAttribute as CFString) ?? "",
                    subrole: axString(window, kAXSubroleAttribute as CFString) ?? "",
                    ordinal: ordinal,
                    displayUUID: display.uuid,
                    frame: frame,
                    relativeFrame: WindowSessionPlanner.relativeFrame(frame, in: display.bounds)
                ))
            }
        }
        return WindowSessionBackup(ownerPID: ownerPID, displays: displays, windows: saved)
    }

    public static func restore(_ backup: WindowSessionBackup) throws -> WindowRestorationReport {
        try restore(backup, retiredDisplays: [])
    }

    /// `retiredDisplays` names saved displays the display-recovery path retired
    /// because the system no longer reports them. Windows saved on those displays
    /// can never be placed again, so they are retired too instead of pending.
    public static func restore(
        _ backup: WindowSessionBackup,
        retiredDisplays: Set<String>
    ) throws -> WindowRestorationReport {
        guard backup.windows.isEmpty || AXIsProcessTrusted() else {
            throw WindowSessionError.accessibilityPermission
        }
        let managed = backup.windows.filter {
            WindowSessionPlanner.shouldManageWindow(bundleIdentifier: $0.bundleIdentifier,
                subrole: $0.subrole, hasScreenWindow: $0.windowID != nil)
        }
        let excluded = backup.windows.count - managed.count
        let offline = Set(managed.map(\.displayUUID)).subtracting(activeDisplayUUIDs)
        let deferred = WindowSessionPlanner.retireStrandedWindows(managed,
            retiredDisplays: offline.union(retiredDisplays.subtracting(activeDisplayUUIDs)))
        let selection = WindowApplicationSelection.resolve(deferred.stillPending) {
            try runningApplication(for: ApplicationIdentity($0), capturedAt: backup.createdAt) != nil
        }
        var surviving = selection.surviving
        var disappeared = selection.disappeared
        var unresolved = selection.failures
        var unmatched = selection.remaining
        var retiredWindows = deferred.retired
        let neededUUIDs = Set(surviving.map(\.displayUUID))
        let displays = waitForDisplays(neededUUIDs: neededUUIDs)
        let missing = neededUUIDs.subtracting(displays.keys).sorted()
        if !missing.isEmpty {
            // A display that did not come back must not strand the windows on the
            // displays that did. Keep the stranded windows for the next unlock and
            // restore the rest, matching the per-display isolation used for brightness.
            let partition = WindowSessionPlanner.partitionRestoreTargets(
                surviving, availableUUIDs: Set(displays.keys))
            surviving = partition.restorable
            retiredWindows.append(contentsOf: WindowSessionPlanner.retireStrandedWindows(
                partition.stranded, retiredDisplays: Set(missing)).retired)
        }
        if surviving.isEmpty {
            return WindowRestorationReport(saved: backup.windows.count, restored: 0,
                disappeared: disappeared, excluded: excluded, remaining: unmatched,
                failures: unresolved, retiredWindows: retiredWindows)
        }

        // WindowServer reports geometry before every application has handled its screen-change
        // notification. Let that first wave settle, then verify all windows together below.
        Thread.sleep(forTimeInterval: 0.5)
        let grouped = Dictionary(grouping: surviving, by: ApplicationIdentity.init)
        var tasks: [WindowRestoreTask] = []

        for (identity, savedWindows) in grouped {
            do {
                guard let resolvedApplication = try runningApplication(for: identity, capturedAt: backup.createdAt) else {
                    disappeared += savedWindows.count
                    continue
                }
                let application = resolvedApplication.application
                let appElement = AXUIElementCreateApplication(application.processIdentifier)
                let elements = try reliableAXWindows(in: appElement)
                let snapshots = cgWindowSnapshots().filter { $0.pid == application.processIdentifier }
                let live = elements.enumerated().compactMap { ordinal, element -> LiveWindow? in
                    guard isRestorableWindow(element) else { return nil }
                    let frame = axWindowFrame(element)
                    let metadata = frame.flatMap {
                        matchCGWindow(pid: application.processIdentifier, frame: $0,
                            title: axString(element, kAXTitleAttribute as CFString), snapshots: snapshots)
                    }
                    return LiveWindow(
                        element: element,
                        match: WindowMatchCandidate(
                            windowID: metadata?.windowID,
                            identifier: axString(element, kAXIdentifierAttribute as CFString),
                            title: axString(element, kAXTitleAttribute as CFString),
                            role: axString(element, kAXRoleAttribute as CFString) ?? "",
                            subrole: axString(element, kAXSubroleAttribute as CFString) ?? "",
                            ordinal: ordinal
                        )
                    )
                }
                let matches = WindowSessionPlanner.matches(
                    saved: savedWindows,
                    candidates: live.map(\.match),
                    trustWindowIDs: resolvedApplication.sameProcess
                )
                let currentWindowIDs = Set(snapshots.map(\.windowID))
                for savedIndex in savedWindows.indices {
                    guard let liveIndex = matches[savedIndex] else {
                        let saved = savedWindows[savedIndex]
                        if WindowSessionPlanner.unmatchedWindowDisappeared(saved,
                            sameProcess: resolvedApplication.sameProcess,
                            liveWindowIDs: currentWindowIDs,
                            liveCount: live.count,
                            matchedCount: matches.count) {
                            disappeared += 1
                        } else {
                            unmatched.append(saved)
                            unresolved.append("\(saved.applicationName) window \(saved.windowID.map(String.init) ?? String(saved.ordinal))")
                        }
                        continue
                    }
                    let saved = savedWindows[savedIndex]
                    guard let display = displays[saved.displayUUID] else { continue }
                    let target = WindowSessionPlanner.targetFrame(for: saved, on: display)
                    tasks.append(WindowRestoreTask(saved: saved, element: live[liveIndex].element, target: target))
                }
            } catch {
                unmatched.append(contentsOf: savedWindows)
                unresolved.append(error.localizedDescription)
            }
        }

        // Retry until every window is in place. A frame that stops changing while it
        // is still off target means the application refuses the write, so record it
        // below instead of re-sending the same value until the deadline.
        let deadline = Date().addingTimeInterval(3)
        var pendingIndices = Array(tasks.indices)
        var lastFrames = [WindowSessionRect?](repeating: nil, count: tasks.count)
        var clamped = Set<Int>()
        var stablePasses = 0
        repeat {
            for index in tasks.indices where axWindowFrame(tasks[index].element)?.isNear(tasks[index].target, tolerance: 2) != true {
                _ = applyWindowFramePrecisely(tasks[index].element, frame: tasks[index].target)
            }
            Thread.sleep(forTimeInterval: 0.15)
            // Recomputed from every task each pass so a window that drifts back out
            // after settling is picked up again, exactly as before.
            var offTarget: [Int] = []
            for index in tasks.indices {
                let actual = axWindowFrame(tasks[index].element)
                guard actual?.isNear(tasks[index].target, tolerance: 2) != true else {
                    lastFrames[index] = nil
                    clamped.remove(index)
                    continue
                }
                if let actual, actual == lastFrames[index] {
                    clamped.insert(index)
                } else {
                    clamped.remove(index)
                }
                lastFrames[index] = actual
                offTarget.append(index)
            }
            pendingIndices = offTarget
            if pendingIndices.isEmpty {
                stablePasses += 1
                if stablePasses >= 8 { break }
            } else {
                stablePasses = 0
            }
        } while Date() < deadline

        let visible = pendingIndices.isEmpty ? [:] : visibleDisplayFrames()
        // The Dock can claim space after the display reconnects. Some apps refuse to
        // grow beyond the current visible frame even when the saved frame was valid.
        if !pendingIndices.isEmpty {
            let fallback = pendingIndices.compactMap { index -> (Int, WindowRestoreTask)? in
                guard let area = visible[tasks[index].saved.displayUUID] else { return nil }
                let fitted = WindowSessionPlanner.frameFittingVisibleArea(tasks[index].target, in: area)
                guard fitted != tasks[index].target else { return nil }
                return (index, WindowRestoreTask(saved: tasks[index].saved, element: tasks[index].element, target: fitted))
            }
            let fallbackDeadline = Date().addingTimeInterval(2)
            for (_, task) in fallback {
                repeat {
                    if axWindowFrame(task.element)?.isNear(task.target, tolerance: 2) == true { break }
                    _ = applyWindowFramePrecisely(task.element, frame: task.target)
                    Thread.sleep(forTimeInterval: 0.15)
                } while Date() < fallbackDeadline
            }
            let settled = Set(fallback.filter {
                axWindowFrame($0.1.element)?.isNear($0.1.target, tolerance: 2) == true
            }.map(\.0))
            pendingIndices.removeAll { settled.contains($0) }
        }

        // A settled window that cannot fit its saved frame is clamped by its own
        // application. Count it as restored and record the deviation: the window is
        // where the application allows it to be, and retrying changes nothing.
        var pendingTasks: [WindowRestoreTask] = []
        var deviations: [String] = []
        for index in pendingIndices {
            let task = tasks[index]
            let actual = axWindowFrame(task.element)
            if clamped.contains(index), let actual,
               let area = visible[task.saved.displayUUID],
               WindowSessionPlanner.isClampLimited(target: task.target, actual: actual, visible: area) {
                deviations.append("\(task.saved.applicationName) window \(task.saved.windowID.map(String.init) ?? String(task.saved.ordinal)) clamped to \(actual) instead of \(task.target)")
                continue
            }
            pendingTasks.append(task)
        }

        let failed = unresolved + pendingTasks.map {
                "\($0.saved.applicationName) window \($0.saved.windowID.map(String.init) ?? String($0.saved.ordinal)) target=\($0.target) actual=\(String(describing: axWindowFrame($0.element)))"
            }
        return WindowRestorationReport(saved: backup.windows.count,
            restored: tasks.count - pendingTasks.count, disappeared: disappeared, excluded: excluded,
            remaining: unmatched + pendingTasks.map(\.saved), failures: failed,
            deviations: deviations, retiredWindows: retiredWindows)
    }
}

// Resolve once per application, retaining unknown targets while allowing unrelated
// applications to proceed. This selection does not access or manipulate the GUI.
struct WindowApplicationSelection {
    var surviving: [SavedWindow] = []
    var remaining: [SavedWindow] = []
    var disappeared = 0
    var failures: [String] = []

    static func resolve(_ windows: [SavedWindow],
                        applicationExists: (SavedWindow) throws -> Bool) -> Self {
        var result = Self()
        for group in Dictionary(grouping: windows, by: ApplicationIdentity.init).values {
            do {
                if try applicationExists(group[0]) {
                    result.surviving.append(contentsOf: group)
                } else {
                    result.disappeared += group.count
                }
            } catch {
                result.remaining.append(contentsOf: group)
                result.failures.append(error.localizedDescription)
            }
        }
        return result
    }
}

private struct ApplicationIdentity: Hashable {
    let ownerPID: Int32
    let bundleIdentifier: String?
    let applicationName: String

    init(_ window: SavedWindow) {
        ownerPID = window.ownerPID
        bundleIdentifier = window.bundleIdentifier
        applicationName = window.applicationName
    }
}

private struct LiveWindow {
    let element: AXUIElement
    let match: WindowMatchCandidate
}

private struct WindowRestoreTask {
    let saved: SavedWindow
    let element: AXUIElement
    let target: WindowSessionRect
}

private struct CGWindowSnapshot {
    let pid: Int32
    let windowID: UInt32
    let title: String?
    let frame: WindowSessionRect
    let isOnscreen: Bool
}

private func activeDisplayGeometries() -> [WindowDisplayGeometry] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).compactMap { id in
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return WindowDisplayGeometry(
            uuid: string,
            bounds: WindowSessionRect(CGDisplayBounds(id)),
            isBuiltin: CGDisplayIsBuiltin(id) != 0
        )
    }
}

private func visibleDisplayFrames() -> [String: WindowSessionRect] {
    var result: [String: WindowSessionRect] = [:]
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        let id = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let key = CFUUIDCreateString(nil, uuid) as String? else { continue }
        let bounds = CGDisplayBounds(id)
        let frame = screen.frame
        let usable = screen.visibleFrame
        result[key] = WindowSessionRect(
            x: bounds.minX + usable.minX - frame.minX,
            y: bounds.minY + frame.maxY - usable.maxY,
            width: usable.width,
            height: usable.height
        )
    }
    return result
}

private func waitForDisplays(neededUUIDs: Set<String>, timeout: TimeInterval = 4) -> [String: WindowDisplayGeometry] {
    guard !neededUUIDs.isEmpty else { return [:] }
    let deadline = Date().addingTimeInterval(timeout)
    var previous: [String: WindowDisplayGeometry] = [:]
    var stableSamples = 0
    repeat {
        let current = Dictionary(uniqueKeysWithValues: activeDisplayGeometries().map { ($0.uuid, $0) })
        if neededUUIDs.isSubset(of: Set(current.keys)) {
            if current == previous {
                stableSamples += 1
                if stableSamples >= 2 { return current }
            } else {
                stableSamples = 0
            }
        }
        previous = current
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return previous
}

// NSRunningApplication.launchDate can be nil for long-lived system apps such as
// Finder. libproc supplies the kernel start time without requiring new privileges.
// A short/failed read remains unknown; never infer that the process disappeared.
enum ProcessStartTime {
    static func read(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) +
            Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

private func runningApplication(for identity: ApplicationIdentity, capturedAt: Date) throws -> (application: NSRunningApplication, sameProcess: Bool)? {
    // The kernel is authoritative for PID lifetime; application metadata may lag
    // WindowServer reconfiguration. A live PID with unavailable metadata is unknown,
    // never proof that the saved windows disappeared.
    guard let existing = try WindowApplicationMetadata.resolve(
        pid: identity.ownerPID, capturedAt: capturedAt, expectedBundleIdentifier: identity.bundleIdentifier,
        application: { NSRunningApplication(processIdentifier: identity.ownerPID) },
        bundleIdentifier: { $0.bundleIdentifier }
    ) else { return nil }
    return (existing, true)
}

// LaunchServices metadata can be temporarily absent during wake/display recovery.
// Keep the retry bounded, and recheck kernel lifetime on every sample so that a
// terminated or reused PID cannot become a restoration target during the wait.
enum WindowApplicationMetadata {
    static func resolve<Application>(
        pid: Int32, capturedAt: Date, expectedBundleIdentifier: String?,
        isAlive: (() -> Bool)? = nil,
        startTime: (() -> Date?)? = nil,
        application: () -> Application?,
        bundleIdentifier: (Application) -> String?,
        attempts: Int = 11,
        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
    ) throws -> Application? {
        for attempt in 0..<max(1, attempts) {
            guard isAlive?() ?? (kill(pid, 0) == 0 || errno == EPERM) else { return nil }
            // A transient kernel read failure leaves the process unknown, not gone.
            // Never accept an identity that cannot be tied to the captured process;
            // retry within the bounded window and only fail once the attempts run out.
            if let launchDate = startTime.map({ $0() }) ?? ProcessStartTime.read(pid: pid) {
                guard WindowSessionPlanner.isOriginalProcess(launchDate: launchDate, capturedAt: capturedAt) else { return nil }
            } else {
                if attempt + 1 >= max(1, attempts) {
                    throw WindowSessionError.restoreFailures(["cannot verify process lifetime for pid \(pid)"])
                }
                wait()
                continue
            }
            if let existing = application() {
                let actual = bundleIdentifier(existing)
                if expectedBundleIdentifier == nil || actual == expectedBundleIdentifier { return existing }
                if let actual {
                    throw WindowSessionError.restoreFailures(["application identity mismatch for live pid \(pid): expected \(expectedBundleIdentifier!), got \(actual)"])
                }
            }
            if attempt + 1 < max(1, attempts) { wait() }
        }
        throw WindowSessionError.restoreFailures(["application metadata unavailable for live pid \(pid)"])
    }
}

private func reliableAXWindows(in application: AXUIElement) throws -> [AXUIElement] {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
    guard error == .success, let windows = value as? [AXUIElement] else {
        var pid = pid_t()
        _ = AXUIElementGetPid(application, &pid)
        throw WindowSessionError.restoreFailures(["cannot enumerate live windows for pid \(pid): AXError=\(error.rawValue)"])
    }
    return windows
}

private func axWindows(in application: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows
}

private func isRestorableWindow(_ window: AXUIElement) -> Bool {
    guard let frame = axWindowFrame(window), frame.width > 0, frame.height > 0 else { return false }
    let subrole = axString(window, kAXSubroleAttribute as CFString) ?? ""
    guard subrole.isEmpty || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else {
        return false
    }
    var positionSettable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success &&
        positionSettable.boolValue
}

private func axWindowFrame(_ window: AXUIElement) -> WindowSessionRect? {
    guard let point = axPoint(window, kAXPositionAttribute as CFString),
          let size = axSize(window, kAXSizeAttribute as CFString),
          size.width > 0, size.height > 0 else { return nil }
    return WindowSessionRect(x: point.x, y: point.y, width: size.width, height: size.height)
}

private func cgWindowSnapshots() -> [CGWindowSnapshot] {
    guard let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return raw.compactMap { info in
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return CGWindowSnapshot(
            pid: pid,
            windowID: windowID,
            title: info[kCGWindowName as String] as? String,
            frame: WindowSessionRect(frame),
            isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
        )
    }
}

private func matchCGWindow(
    pid: Int32,
    frame: WindowSessionRect,
    title: String?,
    snapshots: [CGWindowSnapshot]
) -> CGWindowSnapshot? {
    let near = snapshots.filter { $0.pid == pid && $0.frame.isNear(frame, tolerance: 2) }
    if let title, !title.isEmpty {
        let titled = near.filter { $0.title == title }
        if titled.count == 1 { return titled[0] }
    }
    return near.count == 1 ? near[0] : nil
}

private func applyWindowFramePrecisely(_ window: AXUIElement, frame: WindowSessionRect) -> Bool {
    var point = CGPoint(x: frame.x, y: frame.y)
    var size = CGSize(width: frame.width, height: frame.height)
    guard let pointValue = AXValueCreate(.cgPoint, &point),
          let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

    let application = applicationElement(for: window)
    var restoreEnhancedUI = false
    if let application,
       axBool(application, "AXEnhancedUserInterface" as CFString) == true,
       setAXBool(application, attribute: "AXEnhancedUserInterface" as CFString, value: false) {
        restoreEnhancedUI = true
    }
    defer {
        if restoreEnhancedUI, let application {
            _ = setAXBool(application, attribute: "AXEnhancedUserInterface" as CFString, value: true)
        }
    }

    for _ in 0..<2 {
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        Thread.sleep(forTimeInterval: 0.012)
        if axWindowFrame(window)?.isNear(frame, tolerance: 2) == true { return true }
    }
    return false
}

private func applicationElement(for window: AXUIElement) -> AXUIElement? {
    var pid = pid_t()
    guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
    return AXUIElementCreateApplication(pid)
}

private func setAXBool(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success, settable.boolValue else {
        return false
    }
    return AXUIElementSetAttributeValue(element, attribute, value as CFBoolean) == .success
}

private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? Bool
}

private func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

private func contains(_ bounds: WindowSessionRect, _ point: CGPoint) -> Bool {
    point.x >= bounds.x && point.x < bounds.x + bounds.width &&
        point.y >= bounds.y && point.y < bounds.y + bounds.height
}

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
