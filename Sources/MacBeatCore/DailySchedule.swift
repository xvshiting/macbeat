import Foundation

public struct DailyPeriod: Codable, Equatable, Identifiable {
    public var id: UUID
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool
    public init(id: UUID = UUID(), startMinute: Int, endMinute: Int, enabled: Bool = true) {
        self.id = id; self.startMinute = startMinute; self.endMinute = endMinute; self.enabled = enabled
    }
    public var isValid: Bool { (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute }
    public var minutes: Int { endMinute - startMinute }
}

/// Same-day local wall-clock windows. 1440 means the next local midnight, not 24 elapsed hours.
public struct DailySchedule: Codable, Equatable {
    public var enabled: Bool
    public var periods: [DailyPeriod]
    public init(enabled: Bool = false, startMinute: Int = 540, endMinute: Int = 1080) {
        self.enabled = enabled
        self.periods = Self.legacyPeriods(start: startMinute, end: endMinute)
    }
    public init(enabled: Bool, periods: [DailyPeriod]) { self.enabled = enabled; self.periods = periods }
    private static func legacyPeriods(start: Int, end: Int) -> [DailyPeriod] {
        if (0..<1440).contains(start), (0..<1440).contains(end), end < start {
            return (end > 0 ? [DailyPeriod(startMinute: 0, endMinute: end)] : []) + [DailyPeriod(startMinute: start, endMinute: 1440)]
        }
        return [DailyPeriod(startMinute: start, endMinute: end)]
    }
    private enum CodingKeys: String, CodingKey { case enabled, periods, startMinute, endMinute }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        if let values = try c.decodeIfPresent([DailyPeriod].self, forKey: .periods) { periods = values }
        else { periods = Self.legacyPeriods(start: try c.decode(Int.self, forKey: .startMinute), end: try c.decode(Int.self, forKey: .endMinute)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(periods, forKey: .periods)
    }
    public var isValid: Bool {
        guard periods.allSatisfy(\.isValid), Set(periods.map(\.id)).count == periods.count else { return false }
        let active = periods.filter(\.enabled).sorted { $0.startMinute < $1.startMinute }
        return zip(active, active.dropFirst()).allSatisfy { $0.endMinute <= $1.startMinute }
    }
    public var totalMinutes: Int { periods.filter(\.enabled).reduce(0) { $0 + $1.minutes } }
    public struct MergeProposal: Equatable, Identifiable {
        public var id: UUID { candidate.id }
        public let candidate: DailyPeriod
        public let overlapping: [DailyPeriod]
        public let merged: DailyPeriod
    }
    public func mergeProposal(for candidate: DailyPeriod) -> MergeProposal? {
        guard candidate.isValid, candidate.enabled else { return nil }
        var merged = candidate, matches: [DailyPeriod] = [], changed = true
        while changed {
            changed = false
            for other in periods where other.enabled && other.id != candidate.id && !matches.contains(where: { $0.id == other.id }) {
                if max(merged.startMinute, other.startMinute) < min(merged.endMinute, other.endMinute) {
                    matches.append(other); changed = true
                    merged.startMinute = min(merged.startMinute, other.startMinute)
                    merged.endMinute = max(merged.endMinute, other.endMinute)
                }
            }
        }
        return matches.isEmpty ? nil : MergeProposal(candidate: candidate, overlapping: matches, merged: merged)
    }
    public mutating func apply(_ candidate: DailyPeriod, merging: Bool = false) {
        let proposal = merging ? mergeProposal(for: candidate) : nil
        let ids = Set((proposal?.overlapping ?? []).map(\.id) + [candidate.id])
        periods.removeAll { ids.contains($0.id) }
        periods.append(proposal?.merged ?? candidate)
        periods.sort { $0.startMinute < $1.startMinute }
    }
    public struct Window: Equatable { public let start: Date; public let end: Date }
    private func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) }
        return calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
            matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
    private func windows(on day: Date, calendar: Calendar) -> [Window] {
        var result: [Window] = []
        for period in periods.filter(\.enabled).sorted(by: { $0.startMinute < $1.startMinute }) {
            guard let start = time(period.startMinute, on: day, calendar: calendar),
                  let end = time(period.endMinute, on: day, calendar: calendar), end > start else { continue }
            if let last = result.last, start <= last.end {
                result[result.count - 1] = Window(start: last.start, end: max(last.end, end))
            } else { result.append(Window(start: start, end: end)) }
        }
        return result
    }
    public func currentWindow(at now: Date, calendar: Calendar = .current) -> Window? {
        guard enabled, isValid else { return nil }
        return windows(on: now, calendar: calendar).first { $0.start <= now && now < $0.end }
    }
    public func nextWindow(after now: Date, calendar: Calendar = .current) -> Window? {
        guard enabled, isValid else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            if let next = windows(on: day, calendar: calendar).first(where: { $0.start > now }) { return next }
        }
        return nil
    }
}
