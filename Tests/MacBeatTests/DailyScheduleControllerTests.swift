import XCTest
import MacBeatCore
@testable import MacBeat

final class DailyScheduleControllerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    @MainActor private func model() -> SessionController { SessionController(preview: true, automaticTicks: false) }
    @MainActor private func enable(_ model: SessionController, at now: Date) {
        model.dailySchedule = DailySchedule(enabled: true)
        model.saveDailySchedule(at: now, calendar: calendar)
    }
    @MainActor func testAutomaticallyStartsAndStopsWithFixedDeadline() {
        // tick() follows the machine's local calendar. Keep it consistent with
        // the Shanghai calendar used to create this simulated session.
        let originalZone = NSTimeZone.default
        NSTimeZone.default = calendar.timeZone
        defer { NSTimeZone.default = originalZone }
        let model = model()
        enable(model, at: date("2026-10-07T08:59:00+08:00"))
        XCTAssertFalse(model.running)
        model.evaluateDailySchedule(at: date("2026-10-07T09:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.scheduledSession)
        XCTAssertEqual(model.end, date("2026-10-07T18:00:00+08:00"))
        XCTAssertEqual(model.appliedPlan?.mode, .deadline)
        model.tick(at: date("2026-10-07T18:00:00+08:00"))
        XCTAssertFalse(model.active)
    }
    @MainActor func testWakeWithinWindowUsesOriginalEnd() {
        let model = model()
        enable(model, at: date("2026-10-07T08:00:00+08:00"))
        model.evaluateDailySchedule(at: date("2026-10-07T16:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.end, date("2026-10-07T18:00:00+08:00"))
    }
    @MainActor func testManualStopSkipsRemainingWindowButNextDayRuns() {
        let model = model()
        enable(model, at: date("2026-10-07T10:00:00+08:00"))
        model.stop()
        model.evaluateDailySchedule(at: date("2026-10-07T11:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(model.running)
        model.evaluateDailySchedule(at: date("2026-10-08T09:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(model.running)
    }
    @MainActor func testManualSessionIsNotOverriddenOrStoppedBySchedule() {
        let model = model()
        enable(model, at: date("2026-10-07T08:00:00+08:00"))
        model.mode = .manual
        model.start()
        model.evaluateDailySchedule(at: date("2026-10-07T09:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(model.scheduledSession)
        XCTAssertNil(model.end)
        model.tick(at: date("2026-10-07T18:00:00+08:00"))
        XCTAssertTrue(model.running)
    }
    @MainActor func testPowerFailureIsNotRetriedWhenPowerReturns() {
        let model = model()
        model.power = PowerSnapshot(onAC: false, battery: 80, lidClosed: false, thermal: 0)
        enable(model, at: date("2026-10-07T09:00:00+08:00"))
        XCTAssertFalse(model.running)
        model.power = PowerSnapshot(onAC: true, battery: 80, lidClosed: false, thermal: 0)
        model.evaluateDailySchedule(at: date("2026-10-07T10:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(model.running)
    }
    @MainActor func testStopAndScheduleSurviveRelaunch() {
        let name = "MacBeat.schedule-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SessionController(preview: true, defaults: defaults, automaticTicks: false)
        enable(first, at: date("2026-10-07T09:00:00+08:00"))
        first.stop()
        let second = SessionController(preview: true, defaults: defaults, automaticTicks: false)
        XCTAssertTrue(second.savedDailySchedule.enabled)
        second.evaluateDailySchedule(at: date("2026-10-07T11:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(second.running)
    }
    @MainActor func testDraftDoesNotChangeScheduleUntilSaved() {
        let model = model()
        model.dailySchedule = DailySchedule(enabled: true)
        model.evaluateDailySchedule(at: date("2026-10-07T10:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.scheduleChanged)
        model.saveDailySchedule(at: date("2026-10-07T10:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(model.running)
    }
    @MainActor func testDisabledScheduleAndInvalidTimesDoNotStart() {
        let model = model()
        model.dailySchedule = DailySchedule(enabled: true, startMinute: 540, endMinute: 540)
        model.saveDailySchedule(at: date("2026-10-07T10:00:00+08:00"), calendar: calendar)
        XCTAssertNotNil(model.scheduleValidation)
        XCTAssertFalse(model.savedDailySchedule.enabled)
        XCTAssertFalse(model.running)
    }
    @MainActor func testScheduledSessionCannotBeExtendedByDraftUpdate() {
        let model = model()
        enable(model, at: date("2026-10-07T09:00:00+08:00"))
        model.mode = .manual
        model.update()
        XCTAssertEqual(model.end, date("2026-10-07T18:00:00+08:00"))
    }
    @MainActor func testQuitAndRecoveryErrorDoNotStartSession() {
        let model = model()
        model.schedulingPaused = true
        enable(model, at: date("2026-10-07T09:00:00+08:00"))
        XCTAssertFalse(model.running)
        model.schedulingPaused = false
        model.phase = "error"
        model.evaluateDailySchedule(at: date("2026-10-07T09:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(model.running)
    }
    @MainActor func testHelperFailureDoesNotRetryThisWindow() throws {
        let model = model()
        enable(model, at: date("2026-10-07T09:00:00+08:00"))
        model.phase = "starting"
        for event in [AgentEvent("error", message: "电量低于设定阈值"), AgentEvent("stopped")] {
            model.consume(try JSONEncoder().encode(event) + Data([10]))
        }
        model.evaluateDailySchedule(at: date("2026-10-07T10:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(model.startFailed)
        XCTAssertFalse(model.running)
    }
}

extension DailyScheduleControllerTests {
    @MainActor func testManualStopOnlySkipsThisWindowAndSecondWindowStillRuns() {
        let m = SessionController(preview: true, automaticTicks: false)
        m.dailySchedule = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 540, endMinute: 720), DailyPeriod(startMinute: 840, endMinute: 1080)])
        m.saveDailySchedule(at: date("2026-10-08T09:00:00+08:00"), calendar: calendar)
        m.stop()
        m.evaluateDailySchedule(at: date("2026-10-08T10:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(m.running)
        m.evaluateDailySchedule(at: date("2026-10-08T14:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(m.running)
        XCTAssertEqual(m.end, date("2026-10-08T18:00:00+08:00"))
    }
    @MainActor func testMidnightHandoffWaitsForOldAgentWithoutConsumingNextWindow() {
        let m = SessionController(preview: true, automaticTicks: false)
        m.dailySchedule = DailySchedule(enabled: true, periods: [DailyPeriod(startMinute: 0, endMinute: 120), DailyPeriod(startMinute: 1320, endMinute: 1440)])
        m.saveDailySchedule(at: date("2026-10-08T22:00:00+08:00"), calendar: calendar)
        m.evaluateDailySchedule(at: date("2026-10-09T00:00:01+08:00"), calendar: calendar)
        m.stop(manual: false)
        m.evaluateDailySchedule(at: date("2026-10-09T00:00:02+08:00"), calendar: calendar)
        XCTAssertTrue(m.running)
        XCTAssertEqual(m.end, date("2026-10-09T02:00:00+08:00"))
    }
    @MainActor func testPreviewRecoveryNeverCallsPowerHelperAndClearsOwnedRecord() {
        let m = SessionController(preview: true, automaticTicks: false)
        m.keepAwake = KeepAwakeStatus(recoveryRecord: true, agentActive: true, clamshellBlocked: true)
        XCTAssertTrue(m.needsRecovery)
        m.restore(.owned)
        XCTAssertFalse(m.needsRecovery)
        XCTAssertEqual(m.phase, "idle")
    }
}

extension DailyScheduleControllerTests {
    @MainActor func testLegacyOvernightManualStopSurvivesMigration() throws {
        let zone = NSTimeZone.default; NSTimeZone.default = calendar.timeZone
        defer { NSTimeZone.default = zone }
        let name = "MacBeat.migration-test.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        settings.set(Data(#"{"enabled":true,"startMinute":1320,"endMinute":120}"#.utf8), forKey: "dailySchedule")
        settings.set(date("2026-10-07T22:00:00+08:00"), forKey: "lastScheduledStart")
        let m = SessionController(preview: true, defaults: settings, automaticTicks: false)
        XCTAssertEqual(m.dailySchedule.periods.count, 2)
        m.evaluateDailySchedule(at: date("2026-10-08T01:00:00+08:00"), calendar: calendar)
        XCTAssertFalse(m.running)
        m.evaluateDailySchedule(at: date("2026-10-08T22:00:00+08:00"), calendar: calendar)
        XCTAssertTrue(m.running)
    }
    @MainActor func testRecoveryOfRunningPreviewUsesNormalStop() {
        let m = SessionController(preview: true, automaticTicks: false)
        m.start(); XCTAssertTrue(m.running)
        m.restore(.owned)
        XCTAssertFalse(m.active); XCTAssertNil(m.end)
    }
}
