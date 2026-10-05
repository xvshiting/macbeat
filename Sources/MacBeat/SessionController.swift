import AppKit
import SwiftUI
import ServiceManagement
import MacBeatCore

@MainActor final class SessionController: ObservableObject {
    @Published var mode: EndMode = .duration
    @Published var duration: Double = 7200
    @Published var deadline = Date().addingTimeInterval(7200)
    @Published var powerOnly = UserDefaults.standard.object(forKey: "powerOnly") as? Bool ?? true
    @Published var batteryThreshold = UserDefaults.standard.object(forKey: "batteryThreshold") as? Int ?? 20
    @Published var clamshell = UserDefaults.standard.object(forKey: "clamshell") as? Bool ?? true
    @Published var phase = "idle"
    @Published var message = ""
    @Published var power: PowerSnapshot?
    @Published var end: Date?
    @Published var closedSeconds = 0
    @Published var requestedClamshell = false
    @Published var showSettings = false
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
    var statusText: String { running ? "运行中" : busy ? "处理中" : startFailed ? "开启失败" : phase == "error" ? "需要恢复" : "未开启" }
    var busy: Bool { phase == "starting" || phase == "stopping" || phase == "recovering" || updating }
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

    init(preview: Bool = false) {
        self.preview = preview
        if preview { power = PowerSnapshot(onAC: true, battery: 86, lidClosed: false, thermal: 0) }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if !preview {
            let journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBeat/clamshell-recovery.json")
            if FileManager.default.fileExists(atPath: journal.path) { recover() }
            else { inspect() }
        }
    }
    func tick() {
        now = Date()
        if active, now.timeIntervalSince(lastHeartbeat) >= 2 {
            lastHeartbeat = now
            if !preview { send(AgentCommand("heartbeat")) }
        }
        if preview, running, let end, now >= end { stop() }
        if !active, !preview, Int(now.timeIntervalSince1970) % 10 == 0 { inspect() }
        statusChanged?()
    }
    func start() {
        guard !active, process == nil else { return }
        guard validation == nil else { message = validation ?? ""; return }
        saveSettings()
        message = ""; phase = "starting"; receivedStop = false; closedSeconds = 0
        if preview {
            appliedPlan = plan; end = try? plan.endDate(now: now); phase = "running"
            requestedClamshell = clamshell; message = "界面预览，没有修改系统状态。"; return
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
                    if !self.receivedStop {
                        self.phase = "error"
                        self.message = "控制进程退出（\(task.terminationStatus)）；恢复监视进程会处理遗留状态，可点击恢复状态确认。"
                    }
                    self.statusChanged?()
                }
            }
            pendingPlan = plan
            send(AgentCommand("start", plan: plan))
        }
        catch { phase = "startFailed"; message = error.localizedDescription; input = nil; output = nil; process = nil; releaseActivity() }
    }
    func update() {
        guard running, validation == nil else { return }
        if preview { end = try? plan.endDate(now: now); appliedPlan = plan; return }
        pendingPlan = plan; updating = true
        send(AgentCommand("update", plan: plan))
        // Applied state is committed only after the agent acknowledges the update.
    }
    func stop() {
        guard active || phase == "error" else { safeToQuit?(); return }
        if preview { phase = "idle"; end = nil; message = "已结束预览会话"; safeToQuit?(); return }
        guard process?.isRunning == true else { recover(); return }
        phase = "stopping"; send(AgentCommand("stop"))
    }
    func recover() {
        guard process == nil else { stop(); return }
        phase = "recovering"
        runOneShot(arguments: ["--recover"]) { [weak self] events, code in
            guard let self else { return }
            if code == 0, events.contains(where: { $0.kind == "recovered" }) {
                self.phase = "idle"; self.message = "MacBeat 的恢复记录已处理。"; self.safeToQuit?()
            } else { self.phase = "error"; self.message = events.last?.message ?? "恢复失败，请重新打开应用后重试。" }
        }
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
                phase = "running"; end = event.end; appliedPlan = pendingPlan ?? appliedPlan
                pendingPlan = nil; updating = false
                requestedClamshell = event.clamshellRequested ?? false; message = ""
            case "status":
                end = event.end; closedSeconds = event.closedSeconds ?? 0
            case "notice": message = event.message
            case "error":
                if phase == "starting" { phase = "startFailed" }
                message = event.message; updating = false; pendingPlan = nil
            case "recoveryError": phase = "recovering"; message = event.message
            case "stopped":
                receivedStop = true
                if !startFailed { phase = "idle" }
                end = nil; updating = false; pendingPlan = nil
                if !startFailed { message = event.message }
                safeToQuit?()
            default: break
            }
            statusChanged?()
        }
    }
    func inspect() {
        guard !inspectInProgress else { return }; inspectInProgress = true
        runOneShot(arguments: ["--inspect"]) { [weak self] events, _ in
            self?.inspectInProgress = false
            if let snapshot = events.first?.power { self?.power = snapshot }
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
        UserDefaults.standard.set(powerOnly, forKey: "powerOnly")
        UserDefaults.standard.set(batteryThreshold, forKey: "batteryThreshold")
        UserDefaults.standard.set(clamshell, forKey: "clamshell")
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
