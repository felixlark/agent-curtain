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

    public static func restore(_ backup: BrightnessBackup, client: BetterDisplayClient) throws {
        let active = try client.displays()
        var failures: [String] = []
        // A missing display must not prevent the remaining screens from recovering.
        for saved in backup.displays {
            do {
                let id = try target(for: saved, active: active)
                let value = try client.setBrightnessAndReadback(displayID: id, value: saved.brightness)
                guard abs(value - saved.brightness) <= 0.01 else {
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
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.2)
                    let total = try client.brightness(displayID: id)
                    guard abs(total - saved.brightness) <= 0.01 else {
                        throw BetterDisplayError.commandFailed("displayID=\(id) final brightness \(total), expected \(saved.brightness)")
                    }
                    for (name, expected) in [("hardwareBrightness", saved.hardwareBrightness),
                                             ("softwareBrightness", saved.softwareBrightness)] {
                        if let expected {
                            let actual = try client.brightnessComponent(name, displayID: id)
                            guard abs(actual - expected) <= 0.01 else {
                                throw BetterDisplayError.commandFailed("displayID=\(id) final \(name) \(actual), expected \(expected)")
                            }
                        }
                    }
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw BetterDisplayError.commandFailed(failures.joined(separator: "; "))
        }
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
