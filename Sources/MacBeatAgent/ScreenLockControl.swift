import Foundation
import CoreGraphics
import Darwin

protocol ScreenLocking {
    var available: Bool { get }
    func requestLock()
    func isLocked() -> Bool?
    func turnOffDisplay()
}

/// Resolve the private login API at runtime. Never fall back to display-off as
/// proof of locking, and never change the user's password-delay preference.
final class ScreenLockControl: ScreenLocking {
    private typealias LockFunction = @convention(c) () -> Void
    private let library: UnsafeMutableRawPointer?
    private let lockFunction: LockFunction?
    private let displayError: (String) -> Void
    var available: Bool { lockFunction != nil }

    init(displayError: @escaping (String) -> Void = { _ in }) {
        self.displayError = displayError
        let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL)
        library = handle
        lockFunction = handle.flatMap { dlsym($0, "SACLockScreenImmediate") }
            .map { unsafeBitCast($0, to: LockFunction.self) }
    }
    deinit { if let library { dlclose(library) } }
    func requestLock() { lockFunction?() }
    func isLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        // The key is omitted for an unlocked session on some macOS releases.
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    func turnOffDisplay() {
        let reportError = displayError
        // Display sleep must not block the agent's heartbeat or stop policy.
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["displaysleepnow"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run(); task.waitUntilExit()
                if task.terminationStatus != 0 { reportError("已锁屏，但未能主动熄屏；屏幕仍可按系统设置熄灭。") }
            } catch { reportError("已锁屏，但未能主动熄屏；屏幕仍可按系统设置熄灭。") }
        }
    }
}

/// One request per observed close. Unknown lid readings must not rearm it.
/// Lock acknowledgement is checked on subsequent ticks, without waiting on
/// the control queue. A failure never stops an otherwise healthy awake session.
final class LidLockMonitor {
    private let control: ScreenLocking
    private var handledClose = false
    private var requestedAt: TimeInterval?
    init(control: ScreenLocking) { self.control = control }

    func tick(lidClosed: Bool?, enabled: Bool, uptime: TimeInterval) -> String? {
        guard enabled else { handledClose = false; requestedAt = nil; return nil }
        if lidClosed == false {
            let hadClose = handledClose
            handledClose = false; requestedAt = nil
            return hadClose ? "已开盖 · 等待下次合盖" : nil
        }
        guard lidClosed == true else { return nil }
        if !handledClose {
            handledClose = true
            guard control.available else { return "此系统无法自动锁屏，请手动锁屏。" }
            if control.isLocked() != true { control.requestLock() }
            requestedAt = uptime
        }
        guard let requestedAt else { return nil }
        if control.isLocked() == true {
            self.requestedAt = nil
            control.turnOffDisplay()
            return "已确认锁屏 · 已请求熄屏"
        }
        if uptime - requestedAt >= 4 {
            self.requestedAt = nil
            return "未能确认锁屏，请手动锁屏；保持运行继续。"
        }
        return nil
    }
}
