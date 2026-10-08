import XCTest
@testable import MacBeatAgent

final class LidLockMonitorTests: XCTestCase {
    final class Control: ScreenLocking {
        var available = true
        var locked: Bool? = false
        var requests = 0
        var displayRequests = 0
        func requestLock() { requests += 1 }
        func isLocked() -> Bool? { locked }
        func turnOffDisplay() { displayRequests += 1 }
    }
    func testLocksOnlyAfterCloseAndSleepsDisplayOnlyAfterConfirmation() {
        let control = Control(); let monitor = LidLockMonitor(control: control)
        XCTAssertNil(monitor.tick(lidClosed: false, enabled: true, uptime: 0))
        XCTAssertEqual(control.requests, 0)
        XCTAssertNil(monitor.tick(lidClosed: true, enabled: true, uptime: 1))
        XCTAssertEqual(control.requests, 1)
        XCTAssertEqual(control.displayRequests, 0)
        control.locked = true
        XCTAssertEqual(monitor.tick(lidClosed: true, enabled: true, uptime: 2), "已确认锁屏 · 已请求熄屏")
        for time in 3...10 { XCTAssertNil(monitor.tick(lidClosed: true, enabled: true, uptime: Double(time))) }
        XCTAssertEqual(control.requests, 1); XCTAssertEqual(control.displayRequests, 1)
    }
    func testOpeningRearmsAndUnknownReadDoesNot() {
        let control = Control(); let monitor = LidLockMonitor(control: control)
        _ = monitor.tick(lidClosed: true, enabled: true, uptime: 0)
        _ = monitor.tick(lidClosed: nil, enabled: true, uptime: 1)
        _ = monitor.tick(lidClosed: true, enabled: true, uptime: 2)
        XCTAssertEqual(control.requests, 1)
        _ = monitor.tick(lidClosed: false, enabled: true, uptime: 3)
        _ = monitor.tick(lidClosed: true, enabled: true, uptime: 4)
        XCTAssertEqual(control.requests, 2)
    }
    func testFailureDoesNotPretendDisplayOffIsLockingOrRetryForever() {
        let control = Control(); let monitor = LidLockMonitor(control: control)
        _ = monitor.tick(lidClosed: true, enabled: true, uptime: 0)
        control.locked = nil
        XCTAssertTrue(monitor.tick(lidClosed: true, enabled: true, uptime: 4)?.contains("未能确认锁屏") == true)
        XCTAssertNil(monitor.tick(lidClosed: true, enabled: true, uptime: 5))
        XCTAssertEqual(control.requests, 1); XCTAssertEqual(control.displayRequests, 0)
    }
    func testDisabledAndUnavailableNeverRequestLock() {
        let control = Control(); let monitor = LidLockMonitor(control: control)
        _ = monitor.tick(lidClosed: true, enabled: false, uptime: 0)
        control.available = false
        XCTAssertTrue(monitor.tick(lidClosed: true, enabled: true, uptime: 1)?.contains("无法自动锁屏") == true)
        XCTAssertEqual(control.requests, 0); XCTAssertEqual(control.displayRequests, 0)
    }
    func testAlreadyLockedSessionOnlyRequestsDisplaySleep() {
        let control = Control(); control.locked = true
        let monitor = LidLockMonitor(control: control)
        XCTAssertNotNil(monitor.tick(lidClosed: true, enabled: true, uptime: 0))
        XCTAssertEqual(control.requests, 0); XCTAssertEqual(control.displayRequests, 1)
    }
    func testNativeInterfaceCanBeProbedWithoutLocking() {
        // No requestLock/turnOffDisplay call: this must not disrupt test runners.
        let control = ScreenLockControl()
        XCTAssertNotNil(control.isLocked())
    }
}
