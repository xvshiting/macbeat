import Foundation

public enum WakeService {
    public static let label = "dev.macbeat.wake-service"
    public static let ownerPrefix = "dev.macbeat.scheduled-wake."
    public static let executable = "/Library/PrivilegedHelperTools/" + label
    public static let clientRequirement = "/Library/PrivilegedHelperTools/" + label + ".client.plist"
    public static let launchPlist = "/Library/LaunchDaemons/" + label + ".plist"
}

@objc public protocol WakeServiceProtocol {
    func configure(_ data: Data, reply: @escaping (Data?, String?) -> Void)
}

public struct WakeScheduleStatus: Codable, Equatable {
    public var nextWake: Date?
    public init(nextWake: Date? = nil) { self.nextWake = nextWake }
}

public struct ScheduledWake: Equatable, Hashable {
    public var date: Date
    public var owner: String
    public init(date: Date, owner: String) { self.date = date; self.owner = owner }
}

public struct WakeScheduleError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Connection-scoped RTC bookings. No repeat slot, power-on, sleep timer,
/// or another owner's event is ever modified. Backend calls must be serialized.
public final class WakeScheduleStore {
    private struct Lease { var token: UUID; var schedule: DailySchedule; var event: ScheduledWake?; var connected = true }
    private var leases: [UInt32: Lease] = [:]
    private var pendingCancellation = Set<ScheduledWake>()
    private let add: (ScheduledWake) throws -> Void
    private let cancel: (ScheduledWake) throws -> Void
    public init(add: @escaping (ScheduledWake) throws -> Void, cancel: @escaping (ScheduledWake) throws -> Void) {
        self.add = add; self.cancel = cancel
    }
    public func configure(uid: UInt32, token: UUID, schedule: DailySchedule, now: Date, calendar: Calendar = .current) throws -> WakeScheduleStatus {
        guard schedule.isValid, schedule.periods.count <= 48 else { throw WakeScheduleError("唤醒计划无效，最多支持 48 个当天时段。") }
        if let current = leases[uid], current.token != token { throw WakeScheduleError("另一个 MacBeat 实例正在管理唤醒计划，请先退出该实例。") }
        let old = leases[uid]?.event
        let date = schedule.enabled && schedule.wakeComputer ? schedule.nextWindow(after: now, calendar: calendar)?.start : nil
        let next = date.map { ScheduledWake(date: $0, owner: WakeService.ownerPrefix + String(uid)) }
        // The backend is idempotent and also repairs a booking removed outside
        // the app while the user still has wake scheduling enabled.
        if let next { try add(next) }
        if next != old {
            do { if let old, old.date > now { try cancel(old) } }
            catch {
                if let next {
                    do { try cancel(next) } catch { pendingCancellation.insert(next) }
                }
                throw error
            }
        }
        if let next { pendingCancellation.remove(next) }
        leases[uid] = Lease(token: token, schedule: schedule, event: next)
        return WakeScheduleStatus(nextWake: next?.date)
    }
    public func disconnect(uid: UInt32, token: UUID, now: Date = Date()) throws {
        guard let lease = leases[uid], lease.token == token else { return }
        leases[uid]?.connected = false
        if let event = lease.event, event.date > now { try cancel(event) }
        leases.removeValue(forKey: uid)
    }
    public func refresh(now: Date, calendar: Calendar = .current) {
        for event in pendingCancellation {
            do { if event.date > now { try cancel(event) }; pendingCancellation.remove(event) } catch { }
        }
        for (uid, lease) in leases {
            if lease.connected {
                _ = try? configure(uid: uid, token: lease.token, schedule: lease.schedule, now: now, calendar: calendar)
            } else { try? disconnect(uid: uid, token: lease.token, now: now) }
        }
    }
    public func cancelAll(now: Date = Date()) {
        for (uid, lease) in leases { try? disconnect(uid: uid, token: lease.token, now: now) }
        for event in pendingCancellation {
            do { if event.date > now { try cancel(event) }; pendingCancellation.remove(event) } catch { }
        }
    }
}
