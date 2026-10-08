import Foundation
import Darwin
import MacBeatCore

let engine = PowerControl()
let screenLock = ScreenLockControl(displayError: { message in
    DispatchQueue.main.async { emit(AgentEvent("lockState", message: message)) }
})
let lidLock = LidLockMonitor(control: screenLock)
var plan: SessionPlan?
var end: Date?
var monotonicEnd: TimeInterval?
var watcher: Process?
var watcherInput: FileHandle?
var lastHeartbeat = ProcessInfo.processInfo.systemUptime
var closedSince: TimeInterval?
var sleepOffset: Double?
var shuttingDown = false
var restoreAttempts = 0
var pendingStop: StopReason = .requested
let output = FileHandle.standardOutput

// A pipe disappearing must trigger restoration, not terminate on SIGPIPE.
signal(SIGPIPE, SIG_IGN)
func emit(_ event: AgentEvent) {
    guard let data = try? JSONEncoder().encode(event) else { return }
    try? output.write(contentsOf: data + Data([10]))
}
func sleepClockOffset() -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return (Double(mach_continuous_time()) - Double(mach_absolute_time())) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}
func finish(_ reason: StopReason) {
    shuttingDown = true
    pendingStop = reason
    if let error = engine.stop() {
        restoreAttempts += 1
        emit(AgentEvent("recoveryError", message: error + "，正在重试。"))
        // Remain alive to retry; a failed restore must not be reported as stopped.
        return
    }
    emit(AgentEvent("stopped", message: reason.rawValue, power: powerSnapshot()))
    exit(0)
}
func handle(_ command: AgentCommand) {
    if command.action == "stop" { finish(.requested); return }
    if shuttingDown { return }
    if command.action == "heartbeat" { lastHeartbeat = ProcessInfo.processInfo.systemUptime; return }
    guard let proposed = command.plan else { emit(AgentEvent("error", message: "缺少运行参数。")); return }
    do {
        let now = Date()
        let target = try proposed.endDate(now: now)
        let power = powerSnapshot()
        if let reason = SessionPolicy.stopReason(plan: proposed, end: target, now: now, power: power, heartbeatAge: 0) {
            throw PowerError(message: reason.rawValue)
        }
        if command.action == "start", plan == nil {
            if proposed.lockOnLidClose && proposed.requestClamshell && !screenLock.available {
                throw PowerError(message: "此系统无法自动锁屏，请关闭合盖时自动锁屏后重试。")
            }
            try engine.start(clamshell: proposed.requestClamshell)
            sleepOffset = sleepClockOffset()
        } else if command.action == "update", let current = plan {
            guard current.requestClamshell == proposed.requestClamshell,
                  current.lockOnLidClose == proposed.lockOnLidClose else {
                throw PowerError(message: "请停止后再改变合盖控制方式。")
            }
        } else { throw PowerError(message: "当前状态不接受此请求。") }
        plan = proposed; end = target; lastHeartbeat = ProcessInfo.processInfo.systemUptime
        monotonicEnd = proposed.mode == .duration ? lastHeartbeat + proposed.duration : nil
        emit(AgentEvent("running", end: end, power: power, clamshellRequested: engine.requestedClamshell))
    } catch {
        emit(AgentEvent("error", message: error.localizedDescription))
        if plan == nil { finish(.requested) }
    }
}

if CommandLine.arguments.contains("--watch") {
    // A separate process outlives a killed agent. EOF closes this watch automatically.
    while readLine() != nil { }
    for attempt in 0..<40 {
        do { try engine.recoverExisting(); exit(0) }
        catch { if attempt == 39 { exit(1) }; Thread.sleep(forTimeInterval: 0.05) }
    }
    exit(1)
}

if CommandLine.arguments.contains("--inspect") {
    emit(AgentEvent("snapshot", power: powerSnapshot(), keepAwake: keepAwakeSnapshot()))
    exit(0)
}

if CommandLine.arguments.contains("--restore-sleep") {
    let restorer = NormalSleepRestorer(stopOwned: {
        try engine.recovery.requestStop()
        var failure: Error?
        for attempt in 0..<20 {
            do { try engine.recoverExisting(); failure = nil; break }
            catch { failure = error; if attempt < 19 { Thread.sleep(forTimeInterval: 0.1) } }
        }
        if let failure { throw failure }
    }, releaseClamshell: {
        // Desktops have no lid and therefore no clamshell state to reset.
        if rootProperty("AppleClamshellState") != nil { try engine.releaseShared() }
    })
    let report = restorer.restore()
    // Let powerd publish policy changes before verifying the result.
    if !report.cancelled { Thread.sleep(forTimeInterval: 0.5) }
    engine.recovery.unlock()
    emit(AgentEvent("sleepRestored", power: powerSnapshot(), keepAwake: keepAwakeSnapshot(), sleepRestore: report))
    exit(report.errors.isEmpty ? 0 : 1)
}

if CommandLine.arguments.contains("--release-shared") {
    do {
        try engine.releaseShared()
        emit(AgentEvent("recovered", message: "已请求解除共享合盖保持。", power: powerSnapshot()))
        exit(0)
    } catch { emit(AgentEvent("error", message: error.localizedDescription)); exit(1) }
}
if CommandLine.arguments.contains("--stop-existing") {
    do { try engine.recovery.requestStop() }
    catch { emit(AgentEvent("error", message: error.localizedDescription)); exit(1) }
}

do {
    // The exiting owner's watcher can briefly hold the recovery lock.
    var lastError: Error?
    let attempts = CommandLine.arguments.contains("--stop-existing") ? 20 : 1
    for attempt in 0..<attempts {
        do { try engine.recoverExisting(); lastError = nil; break }
        catch { lastError = error; if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.1) } }
    }
    if let lastError { throw lastError }
    if CommandLine.arguments.contains("--recover") || CommandLine.arguments.contains("--stop-existing") {
        emit(AgentEvent("recovered", message: "恢复记录已处理。", power: powerSnapshot()))
        exit(0)
    }
} catch {
    emit(AgentEvent("error", message: error.localizedDescription))
    exit(1)
}

do { try engine.recovery.registerAgent() }
catch { emit(AgentEvent("error", message: "无法记录控制会话：" + error.localizedDescription)); exit(1) }

// Start the crash restorer before accepting commands. No power state is changed here.
let monitor = Process()
let monitorPipe = Pipe()
monitor.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
monitor.arguments = ["--watch"]
monitor.standardInput = monitorPipe
monitor.standardOutput = FileHandle.nullDevice
monitor.standardError = FileHandle.nullDevice
do {
    try monitor.run()
    watcher = monitor; watcherInput = monitorPipe.fileHandleForWriting
} catch {
    emit(AgentEvent("error", message: "无法启动恢复监视进程：" + error.localizedDescription))
    exit(1)
}

// No auto-start: the parent supplies a validated plan through stdin.
DispatchQueue.global(qos: .utility).async {
    while let line = readLine() {
        guard line.utf8.count <= 8192, let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(AgentCommand.self, from: data) else {
            DispatchQueue.main.async { emit(AgentEvent("error", message: "控制消息无效。")) }
            continue
        }
        DispatchQueue.main.async { handle(command) }
    }
    DispatchQueue.main.async { finish(.clientLost) }
}
var signalSources: [DispatchSourceSignal] = []
for value in [SIGTERM, SIGINT, SIGHUP] {
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler { finish(.requested) }
    source.resume(); signalSources.append(source)
}
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    if shuttingDown { finish(pendingStop); return }
    if engine.recovery.stopRequested { finish(.requested); return }
    let age = ProcessInfo.processInfo.systemUptime - lastHeartbeat
    guard let plan else { if age >= 10 { finish(.clientLost) }; return }
    let power = powerSnapshot()
    if let target = monotonicEnd { end = Date().addingTimeInterval(target - ProcessInfo.processInfo.systemUptime) }
    let currentSleepOffset = sleepClockOffset()
    let sleptSeconds = sleepOffset.map { max(0, currentSleepOffset - $0) } ?? 0
    if let reason = SessionPolicy.stopReason(plan: plan, end: end, now: Date(), power: power,
                                           heartbeatAge: age, sleptSeconds: sleptSeconds) {
        finish(reason); return
    }
    if sleptSeconds > 2 {
        sleepOffset = currentSleepOffset
        closedSince = nil
        emit(AgentEvent("notice", message: "系统曾休眠，现已继续防止空闲休眠。此模式不会阻止合盖休眠。", power: power))
    }
    let uptime = ProcessInfo.processInfo.systemUptime
    if let state = lidLock.tick(lidClosed: power.lidClosed,
                               enabled: plan.requestClamshell && plan.lockOnLidClose, uptime: uptime) {
        emit(AgentEvent("lockState", message: state))
    }
    if power.lidClosed == true { if closedSince == nil { closedSince = uptime } }
    else { closedSince = nil }
    emit(AgentEvent("status", end: end, power: power, clamshellRequested: engine.requestedClamshell,
                    closedSeconds: closedSince.map { Int(uptime - $0) } ?? 0))
}
timer.resume()
emit(AgentEvent("ready", power: powerSnapshot()))
dispatchMain()
