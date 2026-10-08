import AppKit
import SwiftUI
import ServiceManagement
import MacBeatCore

@MainActor final class SessionController: ObservableObject {
    @Published var mode: EndMode = .duration
    @Published var duration: Double = 7200
    @Published var deadline = Date().addingTimeInterval(7200)
    @Published var powerOnly: Bool
    @Published var batteryThreshold: Int
    @Published var clamshell: Bool
    @Published var dailySchedule: DailySchedule
    @Published private(set) var savedDailySchedule: DailySchedule
    @Published private(set) var scheduledSession = false
    @Published var scheduleNotice = ""
    private let defaults: UserDefaults
    private let persistSettings: Bool
    private var lastScheduledStart: Date?
    var schedulingPaused = false
    @Published var phase = "idle"
    @Published var message = ""
    @Published var power: PowerSnapshot?
    @Published var end: Date?
    @Published var closedSeconds = 0
    @Published var requestedClamshell = false
    @Published var showSettings = false
    @Published var keepAwake = KeepAwakeStatus()
    @Published var recoveryNotice = ""
    @Published var recoveryConfirmation: RecoveryAction?
    @Published var sleepRestoreReport: SleepRestoreReport?
    @Published private(set) var restoringNormalSleep = false
    enum RecoveryAction: String, Identifiable { case owned, normalSleep; var id: String { rawValue } }
    @Published var now = Date()
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNotice = ""
    private(set) var appliedPlan: SessionPlan?
    private var pendingPlan: SessionPlan?
    @Published var updating = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bytes = Data()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var lastHeartbeat = Date.distantPast
    private var inspectInProgress = false
    private var receivedStop = false
    var statusChanged: (() -> Void)?
    var safeToQuit: (() -> Void)?
    let preview: Bool

    var running: Bool { phase == "running" }
    var startFailed: Bool { phase == "startFailed" }
    var statusText: String { running ? "运行中" : busy ? "处理中" : startFailed ? "开启失败" : needsRecovery ? "需要恢复" : "未开启" }
    var busy: Bool { restoringNormalSleep || phase == "starting" || phase == "stopping" || phase == "recovering" || updating }
    var active: Bool { running || busy }
    var plan: SessionPlan {
        SessionPlan(mode: mode, duration: duration, deadline: deadline,
                    powerOnly: powerOnly, batteryThreshold: batteryThreshold, requestClamshell: clamshell)
    }
    var validation: String? {
        do { _ = try plan.endDate(now: now); return nil }
        catch { return error.localizedDescription }
    }
    var changed: Bool { appliedPlan != plan }
    var title: String {
        if running { return requestedClamshell && power?.lidClosed == true ? "正在合盖运行" : "正在保持运行" }
        if busy { return phase == "starting" ? "正在开启…" : "正在恢复…" }
        if startFailed { return "未能开启保持运行" }
        return "准备好继续运行"
    }
    var subtitle: String {
        if !clamshell { return "只防止空闲休眠，合盖仍会休眠。" }
        return running ? "开盖保持唤醒，合盖继续运行。" : "设定结束时间，合上盖子也能继续。"
    }
    var clamshellStatus: String {
        guard clamshell else { return "已关闭 · 合盖仍会休眠" }
        guard running else { return "随保持运行一起启用" }
        if closedSeconds >= 60 { return "已连续合盖运行 \(closedSeconds / 60) 分钟" }
        if power?.lidClosed == true { return "已合盖 · 工作继续" }
        return "已启用 · 可合盖"
    }
    var remaining: String {
        guard let end else { return "直到你手动停止" }
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "剩余 %02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    var powerText: String {
        let source = power?.onAC.map { $0 ? "已接通电源" : "正在使用电池" } ?? "正在读取电源"
        return source + (power?.battery.map { " · \($0)%" } ?? "")
    }
    var helperURL: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacBeatAgent")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("MacBeatAgent")
    }

    init(preview: Bool = false, defaults: UserDefaults? = nil, automaticTicks: Bool = true) {
        self.preview = preview
        self.persistSettings = !preview || defaults != nil
        let settings = defaults ?? (preview ? UserDefaults(suiteName: "MacBeat.preview.\(UUID().uuidString)")! : .standard)
        self.defaults = settings
        powerOnly = settings.object(forKey: "powerOnly") as? Bool ?? true
        batteryThreshold = settings.object(forKey: "batteryThreshold") as? Int ?? 20
        clamshell = settings.object(forKey: "clamshell") as? Bool ?? true
        let originalScheduleData = settings.data(forKey: "dailySchedule")
        let schedule = originalScheduleData.flatMap { try? JSONDecoder().decode(DailySchedule.self, from: $0) } ?? DailySchedule()
        dailySchedule = schedule
        savedDailySchedule = schedule
        if (!preview || defaults != nil), settings.data(forKey: "dailySchedule") != nil,
           let migrated = try? JSONEncoder().encode(schedule) { settings.set(migrated, forKey: "dailySchedule") }
        lastScheduledStart = settings.object(forKey: "lastScheduledStart") as? Date
        if let data = originalScheduleData, let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           legacy["periods"] == nil, let start = legacy["startMinute"] as? Int, let end = legacy["endMinute"] as? Int,
           end > 0, end < start, let consumed = lastScheduledStart,
           let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: consumed)) {
            lastScheduledStart = midnight
            if persistSettings { settings.set(midnight, forKey: "lastScheduledStart") }
        }
        if preview { power = PowerSnapshot(onAC: true, battery: 86, lidClosed: false, thermal: 0) }
        if automaticTicks {
            timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        // Inspection is read-only. Another live owner must only be stopped by
        // the user's explicit recovery action, never by opening this app.
        if !preview { inspect() }
    }
    func tick(at date: Date = Date()) {
        now = date
        if active, now.timeIntervalSince(lastHeartbeat) >= 2 {
            lastHeartbeat = now
            if !preview { send(AgentCommand("heartbeat")) }
        }
        if preview, running, let end, now >= end { stop(manual: false) }
        if !active, !preview, Int(now.timeIntervalSince1970) % 10 == 0 { inspect() }
        evaluateDailySchedule(at: now)
        statusChanged?()
    }
    func start() {
        startSession(plan, scheduled: false)
    }
    private func startSession(_ sessionPlan: SessionPlan, scheduled: Bool) {
        guard !active, !needsRecovery, process == nil else { return }
        do { _ = try sessionPlan.endDate(now: now) }
        catch { message = error.localizedDescription; return }
        saveSettings()
        scheduledSession = scheduled
        message = ""; phase = "starting"; receivedStop = false; closedSeconds = 0
        if preview {
            appliedPlan = sessionPlan; end = try? sessionPlan.endDate(now: now); phase = "running"
            requestedClamshell = sessionPlan.requestClamshell; message = "界面预览，没有修改系统状态。"; return
        }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "MacBeat session heartbeat")
        let task = Process()
        let incoming = Pipe(); let outgoing = Pipe()
        task.executableURL = helperURL; task.standardInput = incoming; task.standardOutput = outgoing
        task.standardError = FileHandle.nullDevice
        process = task; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading; bytes = Data()
        do {
            try task.run()
            let reader = outgoing.fileHandleForReading
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    DispatchQueue.main.async { self?.consume(chunk) }
                }
                task.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self, self.process === task else { return }
                    self.input = nil; self.output = nil; self.process = nil
                    self.releaseActivity()
                    if self.receivedStop { self.inspect() }
                    if !self.receivedStop {
                        self.phase = "error"
                        self.message = "控制进程退出（\(task.terminationStatus)）；恢复监视进程会处理遗留状态，可点击恢复状态确认。"
                    }
                    self.statusChanged?()
                }
            }
            pendingPlan = sessionPlan
            send(AgentCommand("start", plan: sessionPlan))
        }
        catch { phase = "startFailed"; message = error.localizedDescription; input = nil; output = nil; process = nil; releaseActivity() }
    }
    func update() {
        guard running, !scheduledSession, validation == nil else { return }
        if preview { end = try? plan.endDate(now: now); appliedPlan = plan; return }
        pendingPlan = plan; updating = true
        send(AgentCommand("update", plan: plan))
        // Applied state is committed only after the agent acknowledges the update.
    }
    func stop(manual: Bool = true) {
        guard active || phase == "error" else { safeToQuit?(); return }
        if manual, let window = savedDailySchedule.currentWindow(at: now),
           lastScheduledStart.map({ $0 < window.start }) ?? true {
            lastScheduledStart = window.start
            if persistSettings { defaults.set(window.start, forKey: "lastScheduledStart") }
        }
        if preview {
            if scheduledSession { scheduleNotice = manual ? "本次定时已手动停止。" : "本次定时已到结束时间。" }
            phase = "idle"; scheduledSession = false; end = nil; message = "已结束预览会话"; safeToQuit?(); return }
        guard process?.isRunning == true else { recover(); return }
        phase = "stopping"; send(AgentCommand("stop"))
    }
    func recover() { restore(.owned) }
    func restore(_ action: RecoveryAction) {
        if action == .normalSleep { restoreNormalSleep(); return }
        guard !busy else { return }
        if running || process != nil { stop(); return }
        suppressCurrentSchedule()
        if preview {
            keepAwake.recoveryRecord = false; keepAwake.agentActive = false
            keepAwake.clamshellBlocked = false; phase = "idle"
            recoveryNotice = "界面预览，未更改系统状态。"; return
        }
        phase = "recovering"
        runOneShot(arguments: ["--stop-existing"]) { [weak self] events, code in
            guard let self else { return }
            if code == 0, events.contains(where: { $0.kind == "recovered" }) {
                self.phase = "idle"; self.recoveryNotice = "MacBeat 会话与恢复记录已处理。"; self.message = ""; self.inspect(); self.safeToQuit?()
            } else { self.phase = "error"; self.message = events.last?.message ?? "恢复失败，请重新打开应用后重试。" }
        }
    }
    func restoreNormalSleep() {
        guard !busy else { return }
        let previouslyPaused = schedulingPaused
        schedulingPaused = true; restoringNormalSleep = true; sleepRestoreReport = nil
        if preview {
            phase = "idle"; end = nil; scheduledSession = false; requestedClamshell = false
            keepAwake.recoveryRecord = false; keepAwake.agentActive = false
            keepAwake.globalSleepDisabled = false; keepAwake.clamshellBlocked = false
            keepAwake.idleSleepDisabledProfiles = []; keepAwake.blockers = keepAwake.blockers ?? []
            finishSleepRestore(SleepRestoreReport(completed: ["界面预览，未修改系统状态。"], sharedHoldReleased: true), previouslyPaused: previouslyPaused)
            return
        }
        // The helper cooperatively stops the current agent after system
        // authorization; heartbeat delivery continues until it has stopped.
        runOneShot(arguments: ["--restore-sleep"]) { [weak self] events, _ in
            guard let self else { return }
            if let event = events.last(where: { $0.kind == "sleepRestored" }), let report = event.sleepRestore {
                if let status = event.keepAwake { self.keepAwake = status }
                if let power = event.power { self.power = power }
                self.finishSleepRestore(report, previouslyPaused: previouslyPaused)
            } else {
                self.finishSleepRestore(SleepRestoreReport(errors: [events.last?.message ?? "恢复进程未返回结果，请重新检测系统状态。"]), previouslyPaused: previouslyPaused)
            }
            self.inspect()
        }
    }
    var shouldOfferNormalSleepRestore: Bool {
        restoringNormalSleep || sleepRestoreReport?.shouldOfferRestore(status: keepAwake) != false
    }
    private func finishSleepRestore(_ report: SleepRestoreReport, previouslyPaused: Bool) {
        if !report.cancelled {
            suppressCurrentSchedule()
            dailySchedule.enabled = false; savedDailySchedule.enabled = false
            if persistSettings, let data = try? JSONEncoder().encode(savedDailySchedule) { defaults.set(data, forKey: "dailySchedule") }
            scheduleNotice = "恢复正常睡眠后，每日计划已关闭。"
        }
        sleepRestoreReport = report; restoringNormalSleep = false; schedulingPaused = previouslyPaused
        recoveryNotice = ""; message = ""
        if process == nil && !report.cancelled { phase = "idle"; end = nil; scheduledSession = false; releaseActivity() }
        statusChanged?()
        safeToQuit?()
    }
    private func releaseActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func send(_ command: AgentCommand) {
        do { let data = try JSONEncoder().encode(command); try input?.write(contentsOf: data + Data([10])) }
        catch { message = "与控制进程通信失败：\(error.localizedDescription)" }
    }
    func consume(_ data: Data) {
        bytes.append(data)
        while let newline = bytes.firstIndex(of: 10) {
            let line = bytes.prefix(upTo: newline); bytes.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(AgentEvent.self, from: line) else { continue }
            if let snapshot = event.power { power = snapshot }
            switch event.kind {
            case "running":
                if scheduledSession { scheduleNotice = "已按每日定时开启。" }
                phase = "running"; end = event.end; appliedPlan = pendingPlan ?? appliedPlan
                pendingPlan = nil; updating = false
                requestedClamshell = event.clamshellRequested ?? false; message = ""
            case "status":
                end = event.end; closedSeconds = event.closedSeconds ?? 0
            case "notice": message = event.message
            case "error":
                if phase == "starting" {
                    phase = "startFailed"
                    if scheduledSession { scheduleNotice = "本次定时开启失败，下一时段再尝试。" }
                }
                message = event.message; updating = false; pendingPlan = nil
            case "recoveryError": phase = "recovering"; message = event.message
            case "stopped":
                if event.message == StopReason.requested.rawValue { suppressCurrentSchedule() }
                if scheduledSession && !startFailed { scheduleNotice = "本次定时已结束：\(event.message)。" }
                receivedStop = true
                if !startFailed { phase = "idle" }
                end = nil; scheduledSession = false; updating = false; pendingPlan = nil
                if !startFailed { message = event.message }
                safeToQuit?()
            default: break
            }
            statusChanged?()
        }
    }
    func inspect() {
        guard !preview else { return }
        guard !inspectInProgress else { return }; inspectInProgress = true
        runOneShot(arguments: ["--inspect"]) { [weak self] events, _ in
            self?.inspectInProgress = false
            if let snapshot = events.first?.power { self?.power = snapshot }
            if let self, let state = events.first?.keepAwake {
                self.keepAwake = state
                if !self.active && (state.recoveryRecord || state.agentActive) {
                    self.recoveryNotice = "检测到已有 MacBeat 保持状态，可手动结束并恢复。"
                }
            }
        }
    }
    private func runOneShot(arguments: [String], completion: @escaping ([AgentEvent], Int32) -> Void) {
        let executable = helperURL
        DispatchQueue.global(qos: .utility).async {
            let task = Process(); let pipe = Pipe()
            task.executableURL = executable; task.arguments = arguments; task.standardOutput = pipe
            task.standardInput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                let events = data.split(separator: 10).compactMap { try? JSONDecoder().decode(AgentEvent.self, from: Data($0)) }
                Task { @MainActor in completion(events, task.terminationStatus) }
            } catch { Task { @MainActor in completion([AgentEvent("error", message: error.localizedDescription)], -1) } }
        }
    }
    func saveSettings() {
        guard persistSettings else { return }
        defaults.set(powerOnly, forKey: "powerOnly")
        defaults.set(batteryThreshold, forKey: "batteryThreshold")
        defaults.set(clamshell, forKey: "clamshell")
    }
    var scheduleValidation: String? {
        !dailySchedule.isValid ? "请使用当天 00:00–24:00 的有效时段，并合并重叠时段。" : nil
    }
    var scheduleChanged: Bool { dailySchedule != savedDailySchedule }
    var scheduleSummary: String {
        guard savedDailySchedule.enabled else { return "每日定时未开启" }
        guard savedDailySchedule.isValid else { return "每日定时无效，请重新设置" }
        return "每日计划 · \(savedDailySchedule.periods.filter(\.enabled).count) 个时段"
    }

    private static func clockText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
    var nextScheduleText: String {
        guard savedDailySchedule.enabled, savedDailySchedule.isValid else { return "" }
        if scheduledSession && active { return "本次由每日定时开启，到时自动结束。" }
        if let window = savedDailySchedule.nextWindow(after: now) {
            return "下次开启：" + window.start.formatted(.dateTime.month().day().hour().minute())
        }
        return ""
    }
    func saveDailySchedule(at date: Date = Date(), calendar: Calendar = .current) {
        guard !active, scheduleValidation == nil else { return }
        savedDailySchedule = dailySchedule
        if persistSettings, let data = try? JSONEncoder().encode(dailySchedule) {
            defaults.set(data, forKey: "dailySchedule")
        }
        saveSettings()
        scheduleNotice = dailySchedule.enabled ? "已保存每日定时。" : "已关闭每日定时。"
        now = date
        evaluateDailySchedule(at: date, calendar: calendar)
    }
    func evaluateDailySchedule(at date: Date, calendar: Calendar = .current) {
        // A scheduled session may be handing off at midnight or a boundary.
        // Do not consume the next window while the old agent is stopping.
        if scheduledSession && active, let end, date >= end { return }
        guard !schedulingPaused,
              let window = savedDailySchedule.currentWindow(at: date, calendar: calendar),
              lastScheduledStart.map({ $0 < window.start }) ?? true else { return }
        // Consume before launching. A stop, failure, crash, or relaunch must not
        // restart this window or bypass battery/thermal protections.
        lastScheduledStart = window.start
        if persistSettings { defaults.set(window.start, forKey: "lastScheduledStart") }
        guard !active, process == nil, !needsRecovery else {
            scheduleNotice = "本次定时已跳过：已有会话运行或状态尚未恢复。"
            return
        }
        now = date
        let scheduledPlan = SessionPlan(mode: .deadline, deadline: window.end,
                                        powerOnly: powerOnly, batteryThreshold: batteryThreshold,
                                        requestClamshell: clamshell)
        // Production uses the agent's fresh power reading, not the last idle
        // snapshot (which may predate sleep). Preview simulates that same policy.
        if preview, let power, let reason = SessionPolicy.stopReason(plan: scheduledPlan, end: window.end,
                                                           now: date, power: power, heartbeatAge: 0) {
            scheduleNotice = "本次定时未开启：\(reason.rawValue)。下次定时再尝试。"
            return
        }
        scheduleNotice = "正在按每日定时开启…"
        startSession(scheduledPlan, scheduled: true)
        if running { scheduleNotice = "已按每日定时开启。" }
        else if startFailed { scheduleNotice = "本次定时开启失败，下一时段再尝试。" }
    }
    var needsRecovery: Bool { !active && (keepAwake.recoveryRecord || keepAwake.agentActive || phase == "error") }
    private func suppressCurrentSchedule() {
        if let window = savedDailySchedule.currentWindow(at: now) {
            lastScheduledStart = max(lastScheduledStart ?? .distantPast, window.start)
            if persistSettings { defaults.set(lastScheduledStart, forKey: "lastScheduledStart") }
        }
    }
    func setLogin(_ enabled: Bool) {
        if preview { loginEnabled = enabled; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNotice = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许 MacBeat。" : ""
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { loginNotice = error.localizedDescription }
    }
}
