import Foundation

/// Aggregate clamshell policy cannot identify which application set the shared bit.
public struct KeepAwakeStatus: Codable, Equatable {
    public var recoveryRecord: Bool
    public var agentActive: Bool
    public var clamshellBlocked: Bool?
    public var globalSleepDisabled: Bool?
    public var blockers: [SleepBlocker]?
    public var idleSleepDisabledProfiles: [String]?
    public init(recoveryRecord: Bool = false, agentActive: Bool = false,
                clamshellBlocked: Bool? = nil, globalSleepDisabled: Bool? = nil,
                blockers: [SleepBlocker]? = nil, idleSleepDisabledProfiles: [String]? = nil) {
        self.recoveryRecord = recoveryRecord; self.agentActive = agentActive
        self.clamshellBlocked = clamshellBlocked; self.globalSleepDisabled = globalSleepDisabled
        self.blockers = blockers; self.idleSleepDisabledProfiles = idleSleepDisabledProfiles
    }
}

public struct SleepBlocker: Codable, Equatable, Identifiable {
    public var pid: Int32
    public var processName: String
    public var reason: String
    public var type: String
    public var id: String { "\(pid):\(type):\(reason)" }
    public var waitsForDisplayOff: Bool { processName == "powerd" && reason == "Powerd - Prevent sleep while display is on" }
    public init(pid: Int32, processName: String, reason: String, type: String) {
        self.pid = pid; self.processName = processName; self.reason = reason; self.type = type
    }
    public static func preventsSleep(type: String, level: Int) -> Bool {
        level > 0 && ["PreventSystemSleep", "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "NetworkClientActive", "ExternalMedia"].contains(type)
    }
}

public struct SleepRestoreReport: Codable, Equatable {
    public var completed: [String]
    public var errors: [String]
    public var cancelled: Bool
    public init(completed: [String] = [], errors: [String] = [], cancelled: Bool = false) {
        self.completed = completed; self.errors = errors; self.cancelled = cancelled
    }
    public func summary(status: KeepAwakeStatus) -> String {
        if cancelled { return "已取消系统授权，未执行恢复。" }
        if !errors.isEmpty { return "恢复尚未完成，请查看下方结果。" }
        if status.agentActive || status.recoveryRecord || status.globalSleepDisabled == true || status.idleSleepDisabledProfiles?.isEmpty == false || status.clamshellBlocked == true || status.blockers?.contains(where: { !$0.waitsForDisplayOff }) == true {
            return "已执行恢复，仍有阻止休眠的状态。"
        }
        if status.globalSleepDisabled == nil || status.clamshellBlocked == nil || status.blockers == nil || status.idleSleepDisabledProfiles == nil {
            return "已执行恢复，部分系统状态尚无法确认。"
        }
        if status.blockers?.contains(where: \.waitsForDisplayOff) == true { return "已恢复睡眠设置，系统正在等待屏幕熄灭。" }
        return "已恢复睡眠设置，未检测到持续防休眠请求。"
    }
}

public enum PeriodDrag {
    case start, end, move
    public func applying(delta: Int, to original: DailyPeriod) -> DailyPeriod {
        var result = original
        switch self {
        case .start: result.startMinute = max(0, min(original.endMinute - 1, original.startMinute + delta))
        case .end: result.endMinute = max(original.startMinute + 1, min(1440, original.endMinute + delta))
        case .move:
            let shift = max(-original.startMinute, min(1440 - original.endMinute, delta))
            result.startMinute += shift; result.endMinute += shift
        }
        return result
    }
}
