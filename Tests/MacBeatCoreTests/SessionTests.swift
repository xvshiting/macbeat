import XCTest
@testable import MacBeatCore

final class SessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_120_000)
    let ac = PowerSnapshot(onAC: true, battery: 86, lidClosed: false, thermal: 0)
    func testAbsoluteDeadlineDoesNotRestartWhenReadAgain() throws {
        let target = now.addingTimeInterval(3600)
        let plan = SessionPlan(mode: .deadline, deadline: target)
        XCTAssertEqual(try plan.endDate(now: now), target)
        XCTAssertEqual(try plan.endDate(now: now.addingTimeInterval(600)), target)
    }
    func testPastAndCurrentDeadlineRejected() {
        for target in [now, now.addingTimeInterval(-1)] {
            XCTAssertThrowsError(try SessionPlan(mode: .deadline, deadline: target).endDate(now: now))
        }
    }
    func testCrossDayDeadline() throws {
        let target = now.addingTimeInterval(26 * 3600)
        XCTAssertEqual(try SessionPlan(mode: .deadline, deadline: target).endDate(now: now), target)
    }
    func testRelativeAndManualModes() throws {
        XCTAssertEqual(try SessionPlan(duration: 1800).endDate(now: now), now.addingTimeInterval(1800))
        XCTAssertNil(try SessionPlan(mode: .manual).endDate(now: now))
    }
    func testRejectUnsafeOrNonfiniteParameters() {
        XCTAssertThrowsError(try SessionPlan(duration: .infinity).endDate(now: now))
        XCTAssertThrowsError(try SessionPlan(duration: -1).endDate(now: now))
        XCTAssertThrowsError(try SessionPlan(mode: .deadline, deadline: now.addingTimeInterval(8 * 86400)).endDate(now: now))
        XCTAssertThrowsError(try SessionPlan(batteryThreshold: 0).endDate(now: now))
    }
    func testDeadlineBoundary() {
        let plan = SessionPlan()
        XCTAssertNil(SessionPolicy.stopReason(plan: plan, end: now.addingTimeInterval(1), now: now, power: ac, heartbeatAge: 0))
        XCTAssertEqual(SessionPolicy.stopReason(plan: plan, end: now, now: now, power: ac, heartbeatAge: 0), .deadline)
    }
    func testDisconnectAndUnknownPowerStopACOnlySessions() {
        let battery = PowerSnapshot(onAC: false, battery: 86, lidClosed: true, thermal: 0)
        let unknown = PowerSnapshot(onAC: nil, battery: nil, lidClosed: nil, thermal: 0)
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(), end: nil, now: now, power: battery, heartbeatAge: 0), .disconnected)
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(), end: nil, now: now, power: unknown, heartbeatAge: 0), .unknownPower)
        XCTAssertNil(SessionPolicy.stopReason(plan: SessionPlan(powerOnly: false), end: nil, now: now, power: battery, heartbeatAge: 0))
    }
    func testUnknownBatteryStopsBatteryAllowedSession() {
        let unknown = PowerSnapshot(onAC: false, battery: nil, lidClosed: false, thermal: 0)
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(powerOnly: false), end: nil, now: now, power: unknown, heartbeatAge: 0), .unknownPower)
    }
    func testLowBatteryAndThermalStop() {
        let low = PowerSnapshot(onAC: false, battery: 20, lidClosed: true, thermal: 0)
        let hot = PowerSnapshot(onAC: true, battery: 86, lidClosed: false, thermal: 2)
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(powerOnly: false), end: nil, now: now, power: low, heartbeatAge: 0), .lowBattery)
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(), end: nil, now: now, power: hot, heartbeatAge: 0), .thermal)
    }
    func testLostClientStopsEvenUnlimitedSession() {
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(mode: .manual), end: nil, now: now, power: ac, heartbeatAge: 10), .clientLost)
    }
    func testOrdinarySessionSurvivesTheReportedClamshellSleep() {
        // Replay the observed 23:12:19 -> 23:12:42 sleep/wake interval.
        // Awake uptime (and the heartbeat age) does not include that sleep.
        let plan = SessionPlan(mode: .manual, powerOnly: false, requestClamshell: false)
        let battery = PowerSnapshot(onAC: false, battery: 82, lidClosed: false, thermal: 0)
        XCTAssertNil(SessionPolicy.stopReason(plan: plan, end: nil, now: now, power: battery,
                                              heartbeatAge: 1, sleptSeconds: 23))
    }
    func testClamshellSessionReportsFailureIfMachineActuallySlept() {
        XCTAssertEqual(SessionPolicy.stopReason(plan: SessionPlan(), end: nil, now: now, power: ac,
                                                heartbeatAge: 1, sleptSeconds: 23), .slept)
    }
    func testWakingDoesNotBypassAnExpiredDeadline() {
        let plan = SessionPlan(mode: .deadline, requestClamshell: false)
        XCTAssertEqual(SessionPolicy.stopReason(plan: plan, end: now.addingTimeInterval(-1), now: now,
                                                power: ac, heartbeatAge: 1, sleptSeconds: 23), .deadline)
    }
    func testWireRoundTripKeepsDeadline() throws {
        let command = AgentCommand("update", plan: SessionPlan(mode: .deadline, deadline: now.addingTimeInterval(90)))
        let decoded = try JSONDecoder().decode(AgentCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.plan, command.plan)
    }
}
