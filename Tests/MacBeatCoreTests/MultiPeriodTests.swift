import XCTest
@testable import MacBeatCore

final class MultiPeriodTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testLegacyMigrationAndRoundTripPreserveAllWindows() throws {
        let legacy = Data(#"{"enabled":true,"startMinute":1320,"endMinute":120}"#.utf8)
        let schedule = try JSONDecoder().decode(DailySchedule.self, from: legacy)
        XCTAssertEqual(schedule.periods.map(\.startMinute), [0,1320])
        XCTAssertEqual(schedule.periods.map(\.endMinute), [120,1440])
        XCTAssertEqual(try JSONDecoder().decode(DailySchedule.self, from: JSONEncoder().encode(schedule)), schedule)
    }
    func testMultipleWindowsAndEndOfDayAreExclusive() {
        let p = [DailyPeriod(startMinute: 0, endMinute: 120), DailyPeriod(startMinute: 540, endMinute: 720), DailyPeriod(startMinute: 1320, endMinute: 1440)]
        let schedule = DailySchedule(enabled: true, periods: p)
        XCTAssertTrue(schedule.isValid)
        XCTAssertNil(schedule.currentWindow(at: date("2026-10-08T08:59:00+08:00"), calendar: calendar))
        XCTAssertEqual(schedule.nextWindow(after: date("2026-10-08T02:00:00+08:00"), calendar: calendar)?.start, date("2026-10-08T09:00:00+08:00"))
        XCTAssertEqual(schedule.currentWindow(at: date("2026-10-08T23:59:00+08:00"), calendar: calendar)?.end, date("2026-10-09T00:00:00+08:00"))
        XCTAssertEqual(schedule.currentWindow(at: date("2026-10-09T00:00:00+08:00"), calendar: calendar)?.end, date("2026-10-09T02:00:00+08:00"))
    }
    func testMergeJoinsOnlyOverlappingEnabledWindowsAndPreservesCandidateIdentity() {
        let a = DailyPeriod(startMinute: 540, endMinute: 720)
        let b = DailyPeriod(startMinute: 840, endMinute: 1080)
        let disabled = DailyPeriod(startMinute: 0, endMinute: 1440, enabled: false)
        var schedule = DailySchedule(enabled: true, periods: [a,b,disabled])
        var candidate = a; candidate.endMinute = 900
        let proposal = schedule.mergeProposal(for: candidate)!
        XCTAssertEqual(proposal.merged.startMinute, 540)
        XCTAssertEqual(proposal.merged.endMinute, 1080)
        XCTAssertEqual(schedule.periods, [a,b,disabled], "Asking to merge must not mutate the draft")
        schedule.apply(candidate, merging: true)
        XCTAssertEqual(schedule.periods.count, 2)
        XCTAssertEqual(schedule.periods.first(where: { $0.id == a.id })?.endMinute, 1080)
        XCTAssertTrue(schedule.isValid)
    }
    func testChainedMergeAndTouchingWindows() {
        let a = DailyPeriod(startMinute: 100, endMinute: 300), b = DailyPeriod(startMinute: 250, endMinute: 450)
        let schedule = DailySchedule(enabled: true, periods: [b,a])
        let proposal = schedule.mergeProposal(for: DailyPeriod(startMinute: 50, endMinute: 150))!
        XCTAssertEqual(proposal.overlapping.count, 2)
        XCTAssertEqual(proposal.merged.endMinute, 450)
        XCTAssertNil(DailySchedule(enabled: true, periods: [a]).mergeProposal(for: DailyPeriod(startMinute: 300, endMinute: 400)))
    }
    func testWholeArcMovementClampsAtDayEdgesWithoutShrinking() {
        let p = DailyPeriod(startMinute: 540, endMinute: 1080)
        let moved = PeriodDrag.move.applying(delta: 800, to: p)
        XCTAssertEqual(moved.endMinute, 1440); XCTAssertEqual(moved.minutes, p.minutes)
        let early = PeriodDrag.move.applying(delta: -900, to: p)
        XCTAssertEqual(early.startMinute, 0); XCTAssertEqual(early.minutes, p.minutes)
        XCTAssertTrue(PeriodDrag.start.applying(delta: 1000, to: p).isValid)
        XCTAssertTrue(PeriodDrag.end.applying(delta: -1000, to: p).isValid)
    }
    func testAdjacentWindowsHaveOneContinuousExecutionWindow() {
        let schedule = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 540, endMinute: 720), DailyPeriod(startMinute: 720, endMinute: 1080)])
        XCTAssertEqual(schedule.currentWindow(at: date("2026-10-08T13:00:00+08:00"), calendar: calendar)?.start, date("2026-10-08T09:00:00+08:00"))
    }
}
