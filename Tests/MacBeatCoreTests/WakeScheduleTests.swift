import XCTest
@testable import MacBeatCore

final class WakeScheduleTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    var morning: Date { date("2026-10-21T08:00:00+08:00") }
    func plan() -> DailySchedule { DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 540, endMinute: 720), DailyPeriod(startMinute: 840, endMinute: 1080)], wakeComputer: true) }
    final class Backend {
        var events = Set<ScheduledWake>()
        var adds = 0
        var failAdd = false
        var failCancel = false
        lazy var store = WakeScheduleStore(add: { [unowned self] event in
            if self.failAdd { throw WakeScheduleError("add failure") }; self.adds += 1; self.events.insert(event)
        }, cancel: { [unowned self] event in
            if self.failCancel { throw WakeScheduleError("cancel failure") }; self.events.remove(event)
        })
    }
    func testRollsThroughMultipleWindowsAndFollowingDayWithoutRepeatSlot() throws {
        let backend = Backend(), token = UUID()
        let first = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        XCTAssertEqual(first.nextWake, date("2026-10-21T09:00:00+08:00"))
        backend.events.removeAll() // firmware consumed the event
        backend.store.refresh(now: date("2026-10-21T09:00:01+08:00"), calendar: calendar)
        XCTAssertEqual(backend.events.first?.date, date("2026-10-21T14:00:00+08:00"))
        backend.events.removeAll()
        backend.store.refresh(now: date("2026-10-21T14:00:01+08:00"), calendar: calendar)
        XCTAssertEqual(backend.events.first?.date, date("2026-10-22T09:00:00+08:00"))
        XCTAssertEqual(backend.events.count, 1)
    }
    func testDisabledPlanOrWakeOptionCancelsOnlyThisOwnersBooking() throws {
        let backend = Backend(), first = UUID(), second = UUID()
        _ = try backend.store.configure(uid: 501, token: first, schedule: plan(), now: morning, calendar: calendar)
        _ = try backend.store.configure(uid: 502, token: second, schedule: plan(), now: morning, calendar: calendar)
        let unrelated = ScheduledWake(date: morning.addingTimeInterval(100), owner: "other.app")
        backend.events.insert(unrelated)
        var off = plan(); off.enabled = false
        XCTAssertNil(try backend.store.configure(uid: 501, token: first, schedule: off, now: morning, calendar: calendar).nextWake)
        XCTAssertTrue(backend.events.contains(unrelated))
        XCTAssertEqual(backend.events.filter { $0.owner == WakeService.ownerPrefix + "502" }.count, 1)
    }
    func testAddFailurePreservesOldBooking() throws {
        let backend = Backend(), token = UUID()
        _ = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        let old = backend.events; backend.failAdd = true
        let changed = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 600, endMinute: 720)], wakeComputer: true)
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: token, schedule: changed, now: morning, calendar: calendar))
        XCTAssertEqual(backend.events, old)
    }
    func testFailedDisconnectDoesNotRearmAfterClientHasGone() throws {
        let backend = Backend(), token = UUID()
        _ = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        backend.failCancel = true
        XCTAssertThrowsError(try backend.store.disconnect(uid: 501, token: token, now: morning))
        backend.events.removeAll()
        backend.store.refresh(now: date("2026-10-22T08:00:00+08:00"), calendar: calendar)
        XCTAssertEqual(backend.adds, 1); XCTAssertTrue(backend.events.isEmpty)
    }
    func testCancellationRollbackIsRetriedAndPreviousPlanIsKept() throws {
        let backend = Backend(), token = UUID()
        _ = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        backend.failCancel = true
        let changed = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 600, endMinute: 720)], wakeComputer: true)
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: token, schedule: changed, now: morning, calendar: calendar))
        XCTAssertEqual(backend.events.count, 2)
        backend.failCancel = false; backend.store.refresh(now: morning, calendar: calendar)
        XCTAssertEqual(backend.events.count, 1)
        XCTAssertEqual(backend.events.first?.date, date("2026-10-21T09:00:00+08:00"))
    }
    func testCompetingConnectionCannotReplaceOrCancelActiveOwnersPlan() throws {
        let backend = Backend(), token = UUID(), stranger = UUID()
        _ = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: stranger, schedule: plan(), now: morning, calendar: calendar))
        try backend.store.disconnect(uid: 501, token: stranger, now: morning)
        XCTAssertEqual(backend.events.count, 1)
        try backend.store.disconnect(uid: 501, token: token, now: morning)
        XCTAssertTrue(backend.events.isEmpty)
    }
    func testNewlyAcceptedPlanIsNotCancelledByAnEarlierRollbackRetry() throws {
        let backend = Backend(), token = UUID()
        _ = try backend.store.configure(uid: 501, token: token, schedule: plan(), now: morning, calendar: calendar)
        let changed = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 600, endMinute: 720)], wakeComputer: true)
        backend.failCancel = true
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: token, schedule: changed, now: morning, calendar: calendar))
        backend.failCancel = false
        _ = try backend.store.configure(uid: 501, token: token, schedule: changed, now: morning, calendar: calendar)
        backend.store.refresh(now: morning, calendar: calendar)
        XCTAssertEqual(backend.events.count, 1)
        XCTAssertEqual(backend.events.first?.date, date("2026-10-21T10:00:00+08:00"))
    }
    func testLegacyScheduleDoesNotSilentlyInstallWakeService() throws {
        let data = Data("{\"enabled\":true,\"startMinute\":540,\"endMinute\":1080}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(DailySchedule.self, from: data).wakeComputer)
        let value = plan()
        XCTAssertEqual(try JSONDecoder().decode(DailySchedule.self, from: JSONEncoder().encode(value)), value)
    }
    func testInvalidOrExcessiveSchedulesNeverReachBackend() {
        let backend = Backend()
        let invalid = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 600, endMinute: 500)], wakeComputer: true)
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: UUID(), schedule: invalid, now: morning))
        let excessive = DailySchedule(enabled: true, periods: (0..<49).map { DailyPeriod(startMinute: $0 * 2, endMinute: $0 * 2 + 1) }, wakeComputer: true)
        XCTAssertThrowsError(try backend.store.configure(uid: 501, token: UUID(), schedule: excessive, now: morning))
        XCTAssertEqual(backend.adds, 0)
    }
}
