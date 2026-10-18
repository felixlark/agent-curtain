import Foundation

public struct DisplayIdentity: Equatable, Sendable {
    public let displayID: Int
    public let uuid: String?
    public let isBuiltin: Bool

    public init(displayID: Int, uuid: String?, isBuiltin: Bool = false) {
        self.displayID = displayID
        self.uuid = uuid
        self.isBuiltin = isBuiltin
    }
}

/// A restored display whose brightness moved after the settling window closed.
/// Auto-brightness on the built-in panel is outside our control, so the change is
/// recorded as evidence instead of being published as an exact success.
public struct BrightnessDrift: Codable, Equatable, Sendable {
    public let displayID: Int
    public let uuid: String?
    public let expected: Double
    public let actual: Double
    public let isBuiltin: Bool

    public init(displayID: Int, uuid: String?, expected: Double, actual: Double, isBuiltin: Bool) {
        self.displayID = displayID
        self.uuid = uuid
        self.expected = expected
        self.actual = actual
        self.isBuiltin = isBuiltin
    }

    public var delta: Double { actual - expected }
}

public struct BrightnessRestoreReport: Equatable, Sendable {
    /// Values read back after the settling window, used as the audit's `after`.
    public let observed: [DisplayBrightness]
    /// Built-in panels that moved after the settling window closed.
    public let drift: [BrightnessDrift]

    public init(observed: [DisplayBrightness] = [], drift: [BrightnessDrift] = []) {
        self.observed = observed
        self.drift = drift
    }
}

public enum BrightnessRestoration {
    public static func target(for saved: DisplayBrightness, active: [DisplayIdentity]) throws -> Int {
        let matches = active.filter {
            if let uuid = saved.uuid { return $0.uuid == uuid }
            return $0.displayID == saved.displayID
        }
        guard matches.count == 1 else {
            throw BetterDisplayError.commandFailed("saved display \(saved.uuid ?? String(saved.displayID)) is unavailable; brightness backup retained")
        }
        return matches[0].displayID
    }

    /// Restore every saved display against the displays that are actually live.
    /// A disconnected display still appears in BetterDisplay's inventory but cannot
    /// accept brightness writes, so matching against inventory could write to a
    /// recycled displayID. Match the active set instead, after a bounded wait for
    /// displays that are still link-training.
    ///
    /// The settling window is verified across `settlingPasses` reads, then one more
    /// read records any late movement as drift (built-in panels only).
    public static func restore(
        _ backup: BrightnessBackup,
        client: BetterDisplayClient,
        activeAttempts: Int = 3,
        activeInterval: TimeInterval = 0.5,
        settlingPasses: Int = 5,
        settlingInterval: TimeInterval = 0.2,
        driftTolerance: Double = 0.01
    ) throws -> BrightnessRestoreReport {
        var active = try client.activeDisplays()
        // Wake exposes a display before its link is trained. Waiting cannot make a
        // genuinely absent display appear, so the wait stays bounded.
        for _ in 0..<(max(1, activeAttempts) - 1) {
            if backup.displays.allSatisfy({ (try? target(for: $0, active: active)) != nil }) { break }
            Thread.sleep(forTimeInterval: activeInterval)
            active = try client.activeDisplays()
        }

        var failures: [String] = []
        var observed: [DisplayBrightness] = []
        var drift: [BrightnessDrift] = []
        // A missing display must not prevent the remaining screens from recovering.
        for saved in backup.displays {
            do {
                let id = try target(for: saved, active: active)
                let isBuiltin = active.first { $0.displayID == id }?.isBuiltin ?? false
                let value = try client.setBrightnessAndReadback(displayID: id, value: saved.brightness)
                guard abs(value - saved.brightness) <= driftTolerance else {
                    throw BetterDisplayError.commandFailed("displayID=\(id) brightness \(value), expected \(saved.brightness)")
                }
                if let hardware = saved.hardwareBrightness {
                    try client.restoreBrightnessComponent("hardwareBrightness", displayID: id, value: hardware)
                }
                if let software = saved.softwareBrightness {
                    try client.restoreBrightnessComponent("softwareBrightness", displayID: id, value: software)
                }
                // Component writes can change the aggregate brightness. Verify the
                // entire tuple after the last write, across a settling interval.
                for _ in 0..<max(1, settlingPasses) {
                    Thread.sleep(forTimeInterval: settlingInterval)
                    let total = try client.brightness(displayID: id)
                    guard abs(total - saved.brightness) <= driftTolerance else {
                        throw BetterDisplayError.commandFailed("displayID=\(id) final brightness \(total), expected \(saved.brightness)")
                    }
                    for (name, expected) in [("hardwareBrightness", saved.hardwareBrightness),
                                             ("softwareBrightness", saved.softwareBrightness)] {
                        if let expected {
                            let actual = try client.brightnessComponent(name, displayID: id)
                            guard abs(actual - expected) <= driftTolerance else {
                                throw BetterDisplayError.commandFailed("displayID=\(id) final \(name) \(actual), expected \(expected)")
                            }
                        }
                    }
                }
                // One read after the settling window: a value that moves now is the
                // 0.891->0.932 case that used to be published as an exact success.
                let finalTotal = try client.brightness(displayID: id)
                observed.append(DisplayBrightness(displayID: id, brightness: finalTotal, uuid: saved.uuid,
                    hardwareBrightness: try? client.brightnessComponent("hardwareBrightness", displayID: id),
                    softwareBrightness: try? client.brightnessComponent("softwareBrightness", displayID: id)))
                if abs(finalTotal - saved.brightness) > driftTolerance {
                    // Only the built-in panel may follow ambient-light auto-brightness.
                    // An external display changing on its own is still a failure.
                    guard isBuiltin else {
                        throw BetterDisplayError.commandFailed(
                            "displayID=\(id) brightness drifted to \(finalTotal), expected \(saved.brightness)")
                    }
                    drift.append(BrightnessDrift(displayID: id, uuid: saved.uuid,
                        expected: saved.brightness, actual: finalTotal, isBuiltin: isBuiltin))
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw BetterDisplayError.commandFailed(failures.joined(separator: "; "))
        }
        return BrightnessRestoreReport(observed: observed, drift: drift)
    }

    public static func reconciliationPlan(
        existing: [DisplayBrightness],
        active: [DisplayIdentity],
        currentBrightness: (Int) throws -> Double
    ) throws -> (updated: [DisplayBrightness], toDim: [DisplayBrightness]) {
        var updated = existing
        var toDim: [DisplayBrightness] = []
        for identity in active {
            let index = existing.firstIndex { saved in
                if let uuid = saved.uuid { return uuid == identity.uuid }
                return saved.displayID == identity.displayID
            }
            if let index {
                let saved = existing[index]
                if saved.displayID == identity.displayID {
                    if try currentBrightness(identity.displayID) > 0.01 { toDim.append(saved) }
                } else {
                    let moved = DisplayBrightness(
                        displayID: identity.displayID,
                        brightness: saved.brightness,
                        uuid: saved.uuid,
                        hardwareBrightness: saved.hardwareBrightness,
                        softwareBrightness: saved.softwareBrightness
                    )
                    updated[index] = moved
                    toDim.append(moved)
                }
            } else {
                let added = DisplayBrightness(
                    displayID: identity.displayID,
                    brightness: try currentBrightness(identity.displayID),
                    uuid: identity.uuid
                )
                updated.append(added)
                toDim.append(added)
            }
        }
        return (updated, toDim)
    }
}
