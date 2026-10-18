import Foundation

enum TimedFeature: String, CaseIterable {
    case system, display
    var title: String { self == .system ? "Mac не засыпает" : "Экран не гаснет" }
}
struct PowerSelection: Codable, Equatable {
    var system: Bool, display: Bool
}
struct ProtectionLease: Equatable {
    let id: UUID
    var deadline: TimeInterval
}
struct TimedPowerSnapshot {
    var remaining: [TimedFeature: Int] = [:]
    var returns: [TimedFeature: Bool] = [:]
    var failed = false
}
struct TimedPowerPlan {
    var baseline: PowerSelection
    var leases: [TimedFeature: ProtectionLease] = [:]
    var desired: PowerSelection {
        let display = baseline.display || leases[.display] != nil
        return PowerSelection(system: baseline.system || leases[.system] != nil || display, display: display)
    }
    mutating func start(_ feature: TimedFeature, minutes: Int, now: TimeInterval) throws {
        guard DurationHistory.valid(minutes) else { throw PowerError(message: "Выберите время от 1 минуты до 7 дней.") }
        leases[feature] = ProtectionLease(id: UUID(), deadline: now + Double(minutes * 60))
    }
    mutating func expire(now: TimeInterval) {
        leases = leases.filter { now < $0.value.deadline }
    }
    mutating func manual(_ command: String) {
        switch command {
        case "sleep-on": leases[.system] = nil; baseline.system = true
        case "display-on": leases[.display] = nil; baseline.system = true; baseline.display = true
        case "sleep-off", "all-off": leases.removeAll(); baseline = PowerSelection(system: false, display: false)
        case "display-off":
            // Manual screen-off preserves the existing sleep selection, as before.
            baseline.system = desired.system; baseline.display = false; leases[.display] = nil
        case "all-on": leases.removeAll(); baseline = PowerSelection(system: true, display: true)
        default: break
        }
    }
    func snapshot(now: TimeInterval, failed: Bool) -> TimedPowerSnapshot {
        TimedPowerSnapshot(remaining: leases.mapValues { max(0, Int(ceil($0.deadline - now))) },
                           returns: [.system: baseline.system, .display: baseline.display], failed: failed)
    }
}

final class DurationHistory {
    static let presets = [15, 30, 60, 120]
    static let limit = 5
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    static func valid(_ minutes: Int) -> Bool { (1...10080).contains(minutes) }
    static func label(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        return hours == 0 ? "\(rest) мин" : rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин"
    }
    private func key(_ feature: TimedFeature) -> String { "TimedDuration." + feature.rawValue }
    func values(_ feature: TimedFeature) -> [Int] {
        var result: [Int] = []
        // Reject booleans, fractions and strings instead of coercing malformed preferences.
        for value in defaults.array(forKey: key(feature)) ?? [] {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= 1, n.doubleValue <= 10080 else { continue }
            let minutes = n.intValue
            if !Self.presets.contains(minutes) && !result.contains(minutes) { result.append(minutes) }
        }
        return Array(result.prefix(Self.limit))
    }
    func remember(_ minutes: Int, for feature: TimedFeature) {
        guard Self.valid(minutes) else { return }
        defaults.set(minutes, forKey: key(feature) + ".last")
        guard !Self.presets.contains(minutes) else { return }
        let next = [minutes] + values(feature).filter { $0 != minutes }
        defaults.set(Array(next.prefix(Self.limit)), forKey: key(feature))
    }
    func remove(_ minutes: Int, for feature: TimedFeature) {
        defaults.set(values(feature).filter { $0 != minutes }, forKey: key(feature))
        if last(feature) == minutes { defaults.removeObject(forKey: key(feature) + ".last") }
    }
    func last(_ feature: TimedFeature) -> Int {
        guard let n = defaults.object(forKey: key(feature) + ".last") as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 1, n.doubleValue <= 10080 else { return 60 }
        return n.intValue
    }
    static func parse(hours: String, minutes: String) -> Int? {
        let h = hours.trimmingCharacters(in: .whitespaces), m = minutes.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !m.isEmpty, h.utf8.allSatisfy({ (48...57).contains($0) }),
              m.utf8.allSatisfy({ (48...57).contains($0) }), let hours = Int(h), let minutes = Int(m),
              hours <= 168, minutes <= 59 else { return nil }
        let result = hours * 60 + minutes
        return valid(result) ? result : nil
    }
}
