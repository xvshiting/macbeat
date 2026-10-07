import Foundation

/// Local wall-clock minutes, rather than fixed UTC offsets or 24-hour intervals.
public struct DailySchedule: Codable, Equatable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int

    public init(enabled: Bool = false, startMinute: Int = 9 * 60, endMinute: Int = 18 * 60) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public var isValid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
    }
    public var crossesMidnight: Bool { endMinute < startMinute }

    public struct Window: Equatable {
        public let start: Date
        public let end: Date
    }

    private func window(on day: Date, calendar: Calendar) -> Window? {
        guard isValid,
              let endDay = calendar.date(byAdding: .day, value: crossesMidnight ? 1 : 0, to: day),
              let start = time(startMinute, on: day, calendar: calendar),
              let end = time(endMinute, on: endDay, calendar: calendar), end > start else { return nil }
        return Window(start: start, end: end)
    }

    private func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        // Missing spring-forward times move to the next valid time; repeated
        // fall-back times use their first occurrence, so a window only runs once.
        calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
                          matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                          matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }

    public func currentWindow(at now: Date, calendar: Calendar = .current) -> Window? {
        guard enabled, isValid else { return nil }
        for offset in [-1, 0] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let window = window(on: day, calendar: calendar) else { continue }
            if window.start <= now && now < window.end { return window }
        }
        return nil
    }

    public func nextWindow(after now: Date, calendar: Calendar = .current) -> Window? {
        guard enabled, isValid else { return nil }
        // Calendar days account for DST and date-line transitions.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let window = window(on: day, calendar: calendar), window.start > now else { continue }
            return window
        }
        return nil
    }
}
