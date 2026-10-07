import XCTest
import IOKit.pwr_mgt
import MacBeatCore
@testable import MacBeatAgent

final class NormalSleepRestorerTests: XCTestCase {
    func testOnlyDisabledProfilesReceiveANewIdleTimer() throws {
        let prefs = try SleepPreferences(output: "Battery Power:\n sleep 0\nAC Power:\n sleep 25\nUPS Power:\n sleep 0\nUnknown:\n sleep 0")
        XCTAssertEqual(prefs.disabledProfiles, ["Battery Power", "UPS Power"])
        XCTAssertEqual(prefs.command, "/usr/bin/pmset -a disablesleep 0 && /usr/bin/pmset -b sleep 10 && /usr/bin/pmset -u sleep 10")
    }
    func testUnreadablePreferencesCannotEnterPrivilegedReset() {
        XCTAssertThrowsError(try SleepPreferences(output: "unexpected output"))
        XCTAssertThrowsError(try SleepPreferences(output: "AC Power:\n sleep -1"))
    }
    func testCancelledAuthorizationLeavesSessionsAndClamshellUntouched() {
        var calls: [String] = []
        let restorer = NormalSleepRestorer(preferences: { try SleepPreferences(output: "AC Power:\n sleep 10") }, authorize: { _ in false }, stopOwned: { calls.append("stop") }, releaseClamshell: { calls.append("lid") })
        let report = restorer.restore()
        XCTAssertTrue(report.cancelled); XCTAssertTrue(report.completed.isEmpty); XCTAssertTrue(calls.isEmpty)
    }
    func testAuthorizationFailureDoesNotStopAnExistingSession() {
        var stopped = false
        let restorer = NormalSleepRestorer(preferences: { try SleepPreferences(output: "AC Power:\n sleep 10") }, authorize: { _ in throw PowerError(message: "permission denied") }, stopOwned: { stopped = true }, releaseClamshell: {})
        XCTAssertEqual(restorer.restore().errors, ["permission denied"]); XCTAssertFalse(stopped)
    }
    func testLiveOwnerFailureDoesNotClearItsClamshellBit() {
        var released = false
        let restorer = NormalSleepRestorer(preferences: { try SleepPreferences(output: "AC Power:\n sleep 10") }, authorize: { _ in true }, stopOwned: { throw PowerError(message: "still active") }, releaseClamshell: { released = true })
        let report = restorer.restore()
        XCTAssertEqual(report.errors, ["still active"]); XCTAssertFalse(released); XCTAssertEqual(report.completed.count, 1)
    }
    func testClamshellFailureRetainsThePartialResult() {
        var calls: [String] = []
        let restorer = NormalSleepRestorer(preferences: { try SleepPreferences(output: "AC Power:\n sleep 0") }, authorize: { _ in calls.append("authorize"); return true }, stopOwned: { calls.append("stop") }, releaseClamshell: { calls.append("lid"); throw PowerError(message: "unsupported") })
        let report = restorer.restore()
        XCTAssertEqual(calls, ["authorize", "stop", "lid"]); XCTAssertEqual(report.errors, ["unsupported"]); XCTAssertEqual(report.completed.count, 3)
    }
    func testRealInspectionFindsOwnedAssertionAndItsRelease() {
        var id: IOPMAssertionID = 0
        XCTAssertEqual(IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacBeat restore inspection test" as CFString, &id), kIOReturnSuccess)
        defer { if id != 0 { IOPMAssertionRelease(id) } }
        XCTAssertTrue(sleepBlockers()?.contains { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.reason == "MacBeat restore inspection test" } == true)
        XCTAssertEqual(IOPMAssertionRelease(id), kIOReturnSuccess)
        id = 0
        XCTAssertFalse(sleepBlockers()?.contains { $0.reason == "MacBeat restore inspection test" } == true)
    }
}
