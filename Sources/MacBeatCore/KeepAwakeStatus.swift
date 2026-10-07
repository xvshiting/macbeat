import Foundation

/// Aggregate clamshell policy cannot identify which application set the shared bit.
public struct KeepAwakeStatus: Codable, Equatable {
    public var recoveryRecord: Bool
    public var agentActive: Bool
    public var clamshellBlocked: Bool?
    public var globalSleepDisabled: Bool?
    public init(recoveryRecord: Bool = false, agentActive: Bool = false,
                clamshellBlocked: Bool? = nil, globalSleepDisabled: Bool? = nil) {
        self.recoveryRecord = recoveryRecord; self.agentActive = agentActive
        self.clamshellBlocked = clamshellBlocked; self.globalSleepDisabled = globalSleepDisabled
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
