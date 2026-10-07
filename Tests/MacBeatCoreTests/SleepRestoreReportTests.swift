import XCTest
@testable import MacBeatCore

final class SleepRestoreReportTests: XCTestCase {
    private var clear: KeepAwakeStatus { KeepAwakeStatus(clamshellBlocked: false, globalSleepDisabled: false, blockers: [], idleSleepDisabledProfiles: []) }
    func testSuccessfulCommandsDoNotHideRemainingBlockers() {
        var status = clear
        status.blockers = [SleepBlocker(pid: 123, processName: "Other App", reason: "working", type: "PreventSystemSleep")]
        XCTAssertEqual(SleepRestoreReport().summary(status: status), "已执行恢复，仍有阻止休眠的状态。")
        status.blockers = []; status.globalSleepDisabled = true
        XCTAssertEqual(SleepRestoreReport().summary(status: status), "已执行恢复，仍有阻止休眠的状态。")
    }
    func testUnknownAndFailedInspectionCannotReportSuccess() {
        XCTAssertEqual(SleepRestoreReport().summary(status: KeepAwakeStatus()), "已执行恢复，部分系统状态尚无法确认。")
        XCTAssertEqual(SleepRestoreReport(errors: ["failed"]).summary(status: clear), "恢复尚未完成，请查看下方结果。")
        XCTAssertEqual(SleepRestoreReport().summary(status: clear), "已恢复睡眠设置，未检测到持续防休眠请求。")
        XCTAssertFalse(SleepBlocker.preventsSleep(type: "UserIsActive", level: 255))
        XCTAssertFalse(SleepBlocker.preventsSleep(type: "PreventSystemSleep", level: 0))
        var displayOnly = clear
        displayOnly.blockers = [SleepBlocker(pid: 1, processName: "powerd", reason: "Powerd - Prevent sleep while display is on", type: "PreventUserIdleSystemSleep")]
        XCTAssertEqual(SleepRestoreReport().summary(status: displayOnly), "已恢复睡眠设置，系统正在等待屏幕熄灭。")
    }
    func testExistingAgentStatusStillDecodesWithoutNewFields() throws {
        let data = Data("{\"recoveryRecord\":false,\"agentActive\":false}".utf8)
        let status = try JSONDecoder().decode(KeepAwakeStatus.self, from: data)
        XCTAssertNil(status.blockers); XCTAssertNil(status.idleSleepDisabledProfiles)
    }
}
