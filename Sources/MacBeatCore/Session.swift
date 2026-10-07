import Foundation

public enum EndMode: String, CaseIterable, Codable {
    case duration, deadline, manual
    public var title: String {
        switch self {
        case .duration: return "按时长"
        case .deadline: return "到时间"
        case .manual: return "手动停止"
        }
    }
}

public struct SessionPlan: Codable, Equatable {
    public var mode: EndMode
    public var duration: TimeInterval
    public var deadline: Date
    public var powerOnly: Bool
    public var batteryThreshold: Int
    public var requestClamshell: Bool

    public init(mode: EndMode = .duration, duration: TimeInterval = 7200,
                deadline: Date = Date().addingTimeInterval(7200), powerOnly: Bool = true,
                batteryThreshold: Int = 20, requestClamshell: Bool = true) {
        self.mode = mode; self.duration = duration; self.deadline = deadline
        self.powerOnly = powerOnly; self.batteryThreshold = batteryThreshold
        self.requestClamshell = requestClamshell
    }

    public func endDate(now: Date) throws -> Date? {
        guard duration.isFinite, duration > 0, duration <= 7 * 86400,
              (5...50).contains(batteryThreshold) else { throw PlanError.invalid }
        switch mode {
        case .manual: return nil
        case .duration: return now.addingTimeInterval(duration)
        case .deadline:
            guard deadline > now else { throw PlanError.past }
            guard deadline.timeIntervalSince(now) <= 7 * 86400 else { throw PlanError.tooFar }
            return deadline
        }
    }
}

public enum PlanError: String, LocalizedError {
    case past = "结束时间需要晚于现在。"
    case tooFar = "单次运行最长支持 7 天，请选择更近的结束时间。"
    case invalid = "运行参数无效。"
    public var errorDescription: String? { rawValue }
}

public struct PowerSnapshot: Codable, Equatable {
    public var onAC: Bool?
    public var battery: Int?
    public var lidClosed: Bool?
    public var thermal: Int
    public init(onAC: Bool?, battery: Int?, lidClosed: Bool?, thermal: Int) {
        self.onAC = onAC; self.battery = battery; self.lidClosed = lidClosed; self.thermal = thermal
    }
}

public enum StopReason: String, Codable {
    case deadline = "已到结束时间"
    case disconnected = "电源已断开"
    case unknownPower = "无法确认电源状态"
    case lowBattery = "电量低于设定阈值"
    case thermal = "系统报告较高温度压力"
    case clientLost = "应用连接已断开"
    case requested = "已手动停止"
    case slept = "检测到系统休眠，本次保持运行已中断"
}

public enum SessionPolicy {
    public static func stopReason(plan: SessionPlan, end: Date?, now: Date,
                                  power: PowerSnapshot, heartbeatAge: TimeInterval,
                                  sleptSeconds: TimeInterval = 0) -> StopReason? {
        // Sleeping is a failed guarantee only when this session requested
        // clamshell control. Ordinary idle assertions allow lid/manual sleep.
        if plan.requestClamshell && sleptSeconds > 2 { return .slept }
        if heartbeatAge >= 10 { return .clientLost }
        if let end, now >= end { return .deadline }
        if power.thermal >= 2 { return .thermal }
        guard let onAC = power.onAC else { return .unknownPower }
        if plan.powerOnly && !onAC { return .disconnected }
        if !onAC && power.battery == nil { return .unknownPower }
        if power.onAC != true, let battery = power.battery, battery <= plan.batteryThreshold { return .lowBattery }
        return nil
    }
}

public struct AgentCommand: Codable {
    public var action: String
    public var plan: SessionPlan?
    public init(_ action: String, plan: SessionPlan? = nil) { self.action = action; self.plan = plan }
}

public struct AgentEvent: Codable {
    public var kind: String
    public var message: String
    public var end: Date?
    public var power: PowerSnapshot?
    public var clamshellRequested: Bool?
    public var keepAwake: KeepAwakeStatus?
    public var closedSeconds: Int?
    public init(_ kind: String, message: String = "", end: Date? = nil, power: PowerSnapshot? = nil,
                clamshellRequested: Bool? = nil, closedSeconds: Int? = nil, keepAwake: KeepAwakeStatus? = nil) {
        self.kind = kind; self.message = message; self.end = end; self.power = power
        self.clamshellRequested = clamshellRequested; self.closedSeconds = closedSeconds; self.keepAwake = keepAwake
    }
}
