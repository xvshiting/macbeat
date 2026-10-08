import XCTest
@testable import MacBeatCore

final class SleepRestoreReportTests: XCTestCase {
    private var clear: KeepAwakeStatus { KeepAwakeStatus(clamshellBlocked: false, globalSleepDisabled: false, blockers: [], idleSleepDisabledProfiles: []) }
    func testScreenOnSystemPolicyAfterResetIsNotReportedAsUnfinishedRestore() {
        let status = KeepAwakeStatus(clamshellBlocked: true, globalSleepDisabled: false,
            blockers: [SleepBlocker(pid: 552, processName: "powerd", reason: "Powerd - Prevent sleep while display is on", type: "PreventUserIdleSystemSleep")], idleSleepDisabledProfiles: [])
        let report = SleepRestoreReport(completed: ["已请求关闭全局禁用睡眠。", "MacBeat 会话与恢复记录已处理。", "已请求解除合盖保持。"], sharedHoldReleased: true)
        XCTAssertEqual(report.summary(status: status), "睡眠设置已恢复，合盖行为仍取决于系统当前条件。")
        XCTAssertFalse(report.shouldOfferRestore(status: status))
    }
    func testRepeatRestoreOnlyReturnsForResettableState() {
        let report = SleepRestoreReport(sharedHoldReleased: true)
        var status = clear
        status.blockers = [SleepBlocker(pid: 123, processName: "Other App", reason: "active", type: "PreventSystemSleep")]
        XCTAssertFalse(report.shouldOfferRestore(status: status))
        XCTAssertEqual(report.summary(status: status), "已执行恢复，仍有阻止休眠的状态。")
        status.globalSleepDisabled = true
        XCTAssertTrue(report.shouldOfferRestore(status: status))
        status.globalSleepDisabled = false; status.agentActive = true
        XCTAssertTrue(report.shouldOfferRestore(status: status))
        status.agentActive = false; status.idleSleepDisabledProfiles = ["AC Power"]
        XCTAssertTrue(report.shouldOfferRestore(status: status))
        XCTAssertTrue(SleepRestoreReport(cancelled: true).shouldOfferRestore(status: clear))
        XCTAssertTrue(SleepRestoreReport(errors: ["failed"]).shouldOfferRestore(status: clear))
    }
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
