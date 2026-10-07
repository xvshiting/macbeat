import XCTest
import MacBeatCore
@testable import MacBeat

final class NormalSleepControllerTests: XCTestCase {
    @MainActor func testPreviewRestoreEndsSessionAndDisablesFutureSchedule() {
        let model = SessionController(preview: true, automaticTicks: false)
        model.dailySchedule = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 0, endMinute: 1440)])
        model.saveDailySchedule()
        XCTAssertTrue(model.running)
        var completed = false
        model.safeToQuit = { completed = true }
        model.keepAwake = KeepAwakeStatus(recoveryRecord: true, agentActive: true, clamshellBlocked: true, globalSleepDisabled: true)
        model.restore(.normalSleep)
        XCTAssertFalse(model.running); XCTAssertNil(model.end)
        XCTAssertFalse(model.savedDailySchedule.enabled)
        XCTAssertEqual(model.keepAwake.globalSleepDisabled, false)
        model.tick()
        XCTAssertFalse(model.running); XCTAssertNotNil(model.sleepRestoreReport)
        XCTAssertTrue(completed)
    }
    @MainActor func testPreviewRestoreDoesNotEraseOtherApplicationsBlockers() {
        let model = SessionController(preview: true, automaticTicks: false)
        model.keepAwake.blockers = [SleepBlocker(pid: 1, processName: "Other App", reason: "working", type: "PreventSystemSleep")]
        model.restore(.normalSleep)
        XCTAssertEqual(model.keepAwake.blockers?.count, 1)
        XCTAssertEqual(model.sleepRestoreReport?.summary(status: model.keepAwake), "已执行恢复，仍有阻止休眠的状态。")
    }
}
