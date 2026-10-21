import XCTest
import MacBeatCore
@testable import MacBeat

@MainActor final class WakeScheduleControllerTests: XCTestCase {
    final class Client: WakeScheduling {
        var requests: [DailySchedule] = []
        var completion: ((Result<WakeScheduleStatus, Error>) -> Void)?
        var disconnected = false
        func configure(_ schedule: DailySchedule, authorize: Bool, completion: @escaping (Result<WakeScheduleStatus, Error>) -> Void) {
            requests.append(schedule); self.completion = completion
        }
        func disconnect() { disconnected = true }
        func remove(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    }
    func testCancelledAuthorizationKeepsSavedPlanAndDoesNotStartSession() {
        let client = Client()
        let controller = SessionController(preview: true, automaticTicks: false, wakeScheduler: client)
        let previous = controller.savedDailySchedule
        controller.dailySchedule.enabled = true; controller.dailySchedule.wakeComputer = true
        controller.saveDailySchedule()
        XCTAssertTrue(controller.savingSchedule); XCTAssertEqual(controller.savedDailySchedule, previous)
        client.completion?(.failure(WakeScheduleError("已取消授权")))
        XCTAssertFalse(controller.savingSchedule); XCTAssertFalse(controller.running)
        XCTAssertEqual(controller.savedDailySchedule, previous)
        XCTAssertTrue(controller.scheduleChanged); XCTAssertEqual(controller.wakeNotice, "已取消授权")
    }
    func testSuccessfulBookingCommitsDraftAndDisablingCancelsBooking() {
        let client = Client()
        let controller = SessionController(preview: true, automaticTicks: false, wakeScheduler: client)
        controller.dailySchedule.enabled = true; controller.dailySchedule.wakeComputer = true
        let now = ISO8601DateFormatter().date(from: "2026-10-21T08:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        controller.saveDailySchedule(at: now, calendar: calendar)
        let next = Date().addingTimeInterval(3600)
        client.completion?(.success(WakeScheduleStatus(nextWake: next)))
        XCTAssertTrue(controller.savedDailySchedule.wakeComputer); XCTAssertEqual(controller.nextWake, next)
        controller.dailySchedule.wakeComputer = false; controller.saveDailySchedule(at: now, calendar: calendar)
        XCTAssertFalse(client.requests.last!.wakeComputer)
        client.completion?(.success(WakeScheduleStatus()))
        XCTAssertFalse(controller.savedDailySchedule.wakeComputer); XCTAssertNil(controller.nextWake)
        controller.disconnectWakeScheduler(); XCTAssertTrue(client.disconnected)
    }
    func testSavingAtWindowBoundaryDoesNotConsumeTheExistingWindow() {
        let client = Client()
        let start = ISO8601DateFormatter().date(from: "2026-10-21T09:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let model = SessionController(preview: true, automaticTicks: false, wakeScheduler: client)
        model.dailySchedule = DailySchedule(enabled: true)
        model.saveDailySchedule(at: start.addingTimeInterval(-60), calendar: calendar)
        client.completion?(.success(WakeScheduleStatus()))
        model.dailySchedule.wakeComputer = true
        model.saveDailySchedule(at: start, calendar: calendar)
        model.evaluateDailySchedule(at: start, calendar: calendar)
        XCTAssertFalse(model.running)
        client.completion?(.failure(WakeScheduleError("取消")))
        model.evaluateDailySchedule(at: start.addingTimeInterval(1), calendar: calendar)
        XCTAssertTrue(model.running)
    }
}
