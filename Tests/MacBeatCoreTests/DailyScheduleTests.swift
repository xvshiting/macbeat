import XCTest
@testable import MacBeatCore

final class DailyScheduleTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testInclusiveStartExclusiveEndAndDisabledSchedule() {
        let schedule = DailySchedule(enabled: true)
        let start = date("2026-10-07T09:00:00+08:00")
        let end = date("2026-10-07T18:00:00+08:00")
        XCTAssertNil(schedule.currentWindow(at: start.addingTimeInterval(-1), calendar: calendar()))
        XCTAssertEqual(schedule.currentWindow(at: start, calendar: calendar())?.end, end)
        XCTAssertNotNil(schedule.currentWindow(at: end.addingTimeInterval(-1), calendar: calendar()))
        XCTAssertNil(schedule.currentWindow(at: end, calendar: calendar()))
        XCTAssertNil(DailySchedule().currentWindow(at: start, calendar: calendar()))
        XCTAssertNil(DailySchedule().nextWindow(after: start, calendar: calendar()))
    }
    func testOvernightWindowBelongsToPreviousDayAcrossYearBoundary() {
        let schedule = DailySchedule(enabled: true, startMinute: 22 * 60, endMinute: 2 * 60)
        let window = schedule.currentWindow(at: date("2027-01-01T01:30:00+08:00"), calendar: calendar())
        XCTAssertEqual(window?.start, date("2026-12-31T22:00:00+08:00"))
        XCTAssertEqual(window?.end, date("2027-01-01T02:00:00+08:00"))
    }
    func testWakeAfterEntireWindowDoesNotCatchUp() {
        let schedule = DailySchedule(enabled: true)
        let now = date("2026-10-07T20:00:00+08:00")
        XCTAssertNil(schedule.currentWindow(at: now, calendar: calendar()))
        XCTAssertEqual(schedule.nextWindow(after: now, calendar: calendar())?.start, date("2026-10-08T09:00:00+08:00"))
    }
    func testEqualTimesAndInvalidPersistedMinutesAreRejected() {
        for schedule in [DailySchedule(enabled: true, startMinute: 540, endMinute: 540),
                         DailySchedule(enabled: true, startMinute: -1),
                         DailySchedule(enabled: true, endMinute: 1440)] {
            XCTAssertFalse(schedule.isValid)
            XCTAssertNil(schedule.currentWindow(at: Date(), calendar: calendar()))
            XCTAssertNil(schedule.nextWindow(after: Date(), calendar: calendar()))
        }
    }
    func testSpringForwardUsesLocalCalendarRatherThan24Hours() {
        let schedule = DailySchedule(enabled: true, startMinute: 22 * 60, endMinute: 4 * 60)
        let window = schedule.currentWindow(at: date("2026-03-08T03:30:00-07:00"), calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(window?.start, date("2026-03-07T22:00:00-08:00"))
        XCTAssertEqual(window?.end, date("2026-03-08T04:00:00-07:00"))
        XCTAssertEqual(window?.end.timeIntervalSince(window!.start), 5 * 3600)
    }
    func testMissingStartTimeUsesNextValidTime() {
        let schedule = DailySchedule(enabled: true, startMinute: 150, endMinute: 240)
        let window = schedule.currentWindow(at: date("2026-03-08T03:10:00-07:00"), calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(window?.start, date("2026-03-08T03:00:00-07:00"))
    }
    func testFallBackRepeatedHourKeepsOneWindowIdentity() {
        let schedule = DailySchedule(enabled: true, startMinute: 90, endMinute: 180)
        let first = schedule.currentWindow(at: date("2026-11-01T01:45:00-07:00"), calendar: calendar("America/Los_Angeles"))
        let second = schedule.currentWindow(at: date("2026-11-01T01:45:00-08:00"), calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.start, date("2026-11-01T01:30:00-07:00"))
    }
    func testTimeZoneChangeUsesNewLocalHours() {
        let schedule = DailySchedule(enabled: true)
        let now = date("2026-10-07T09:30:00+08:00")
        XCTAssertNotNil(schedule.currentWindow(at: now, calendar: calendar()))
        XCTAssertNil(schedule.currentWindow(at: now, calendar: calendar("UTC")))
    }
}
