import XCTest
import MacBeatCore
@testable import MacBeat

final class SessionControllerTests: XCTestCase {
    @MainActor func testLockSettingPersistsAndAppliesToSessionWithoutEndingOnLockFailure() throws {
        let name = "MacBeat.test.lock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SessionController(preview: true, defaults: defaults, automaticTicks: false)
        XCTAssertFalse(model.lockOnLidClose)
        model.lockOnLidClose = true; model.saveSettings(); model.start()
        XCTAssertEqual(model.appliedPlan?.lockOnLidClose, true)
        let reloaded = SessionController(preview: true, defaults: defaults, automaticTicks: false)
        XCTAssertTrue(reloaded.lockOnLidClose)
        model.consume(try JSONEncoder().encode(AgentEvent("lockState", message: "未能确认锁屏")) + Data([10]))
        XCTAssertTrue(model.running); XCTAssertEqual(model.lockNotice, "未能确认锁屏")
    }
    @MainActor func testRejectedStartRemainsVisibleAfterCleanup() throws {
        let model = SessionController(preview: true)
        model.phase = "starting"
        let error = AgentEvent("error", message: "合盖接口不受支持。")
        let stopped = AgentEvent("stopped", message: "已手动停止")
        // The real agent sends both messages when startup fails.
        for event in [error, stopped] {
            model.consume(try JSONEncoder().encode(event) + Data([10]))
        }
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.phase, "startFailed")
        XCTAssertEqual(model.title, "未能开启保持运行")
        XCTAssertEqual(model.message, error.message)
        model.start()
        XCTAssertTrue(model.running, "A cleaned-up startup failure must allow retry.")
    }

    @MainActor func testUpdateErrorDoesNotEndRunningSession() throws {
        let model = SessionController(preview: true)
        model.start()
        model.consume(try JSONEncoder().encode(AgentEvent("error", message: "结束时间需要晚于现在。")) + Data([10]))
        XCTAssertTrue(model.running)
        model.consume(try JSONEncoder().encode(AgentEvent("stopped", message: "已手动停止")) + Data([10]))
        XCTAssertEqual(model.phase, "idle")
    }

    @MainActor func testWakeNoticeKeepsSessionActiveUntilAnActualStop() throws {
        let model = SessionController(preview: true)
        model.clamshell = false
        model.start()
        let notice = "系统曾休眠，现已继续防止空闲休眠。"
        for event in [AgentEvent("notice", message: notice), AgentEvent("status", closedSeconds: 0)] {
            model.consume(try JSONEncoder().encode(event) + Data([10]))
        }
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.message, notice)
        model.consume(try JSONEncoder().encode(AgentEvent("stopped", message: "已到结束时间")) + Data([10]))
        XCTAssertEqual(model.phase, "idle")
        XCTAssertEqual(model.message, "已到结束时间")
    }
}
