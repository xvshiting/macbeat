import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import MacBeatCore

struct PowerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func rootProperty(_ key: String) -> Any? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func powerSnapshot() -> PowerSnapshot {
    var onAC: Bool?
    var percent: Int?
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onAC = type == kIOPSACPowerValue
        }
        if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                percent = max(0, min(100, current * 100 / maximum))
                break
            }
        }
    }
    return PowerSnapshot(onAC: onAC, battery: percent,
                         lidClosed: rootProperty("AppleClamshellState") as? Bool,
                         thermal: ProcessInfo.processInfo.thermalState.rawValue)
}

/// The private selector alters the shared powerd clamshell bit, not a preference.
/// Success is only API acknowledgement, never evidence of closed-lid operation.
/// We do not reapply it on power changes or claim per-process ownership.
final class PowerControl {
    let recovery = RecoveryStore()
    private var assertionIDs: [IOPMAssertionID] = []
    private var connection: io_connect_t = 0
    private(set) var changedClamshell = false
    private(set) var requestedClamshell = false

    func start(clamshell: Bool) throws {
        guard assertionIDs.isEmpty else { throw PowerError(message: "已有运行会话。") }
        do {
            if clamshell {
                guard rootProperty("AppleClamshellState") != nil else {
                    throw PowerError(message: "这台设备未提供笔记本合盖状态。")
                }
                // AppleClamshellCausesSleep is an aggregate policy result, not
                // ownership of the shared powerd bit. False is not a conflict.
                // Read the actual global preference before our own assertions.
                guard rootProperty("SleepDisabled") as? Bool != true else {
                    throw PowerError(message: "系统已全局禁用睡眠；MacBeat 无法在结束时恢复正常睡眠，请先恢复该设置。")
                }
            }
            try assertion("PreventUserIdleSystemSleep", required: true)
            try assertion("PreventSystemSleep", required: false)
            if clamshell {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
                guard service != 0 else { throw PowerError(message: "无法访问电源管理服务。") }
                let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
                IOObjectRelease(service)
                guard result == kIOReturnSuccess else { throw failure("打开合盖控制接口", result) }
                try recovery.arm()
                changedClamshell = true
                try setClamshell(true)
                requestedClamshell = true
            }
        } catch {
            let restore = stop()
            if let restore { throw PowerError(message: "\(error.localizedDescription)；\(restore)") }
            throw error
        }
    }

    func recoverExisting() throws {
        try recovery.lock()
        guard recovery.isArmed else { return }
        // A reboot or successful prior cleanup may already have restored the bit.
        if rootProperty("AppleClamshellCausesSleep") as? Bool == true {
            try recovery.disarm(); return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw PowerError(message: "恢复时无法访问电源管理服务。") }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { throw failure("打开恢复接口", result) }
        changedClamshell = true
        if let error = stop() { throw PowerError(message: error) }
    }

    func releaseShared() throws {
        try recovery.lock()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw PowerError(message: "无法访问合盖控制接口。") }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { throw failure("打开合盖控制接口", result) }
        defer { IOServiceClose(connection); connection = 0 }
        try setClamshell(false)
        try recovery.disarm()
    }
    private func assertion(_ type: String, required: Bool) throws {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "MacBeat active session" as CFString, &id)
        if result == kIOReturnSuccess { assertionIDs.append(id) }
        else if required { throw failure("申请保持运行", result) }
    }

    private func setClamshell(_ value: Bool) throws {
        let input: [UInt64] = [value ? 1 : 0]
        // Apple OSS IOPMLibDefs: kPMSetClamshellSleepState = 12.
        let result = IOConnectCallScalarMethod(connection, 12, input, 1, nil, nil)
        guard result == kIOReturnSuccess else { throw failure("调整合盖状态", result) }
    }

    @discardableResult func stop() -> String? {
        var errors: [String] = []
        if changedClamshell {
            do { try setClamshell(false); try recovery.disarm(); changedClamshell = false }
            catch { errors.append(error.localizedDescription) }
        }
        // Keep the connection alive for a retry if restoration fails.
        if !changedClamshell, connection != 0 { IOServiceClose(connection); connection = 0 }
        assertionIDs = assertionIDs.filter { id in
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess { errors.append(failure("释放唤醒状态", result).localizedDescription); return true }
            return false
        }
        if errors.isEmpty { requestedClamshell = false }
        return errors.isEmpty ? nil : "恢复失败：" + errors.joined(separator: "；")
    }

    private func failure(_ operation: String, _ code: IOReturn) -> PowerError {
        PowerError(message: "\(operation)失败（0x\(String(UInt32(bitPattern: code), radix: 16))）。系统可能不支持此接口。")
    }
}

func keepAwakeSnapshot() -> KeepAwakeStatus {
    let store = RecoveryStore()
    return KeepAwakeStatus(recoveryRecord: store.isArmed, agentActive: store.agentActive,
        clamshellBlocked: (rootProperty("AppleClamshellCausesSleep") as? Bool).map { !$0 },
        globalSleepDisabled: rootProperty("SleepDisabled") as? Bool)
}
