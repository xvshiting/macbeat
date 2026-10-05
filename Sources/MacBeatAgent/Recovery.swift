import Foundation
import Darwin

/// User-local journal records only MacBeat's transient clamshell write.
/// No root privileges, login daemon, or system preferences are modified.
final class RecoveryStore {
    let directory: URL
    var journal: URL { directory.appendingPathComponent("clamshell-recovery.json") }
    private var descriptor: Int32 = -1
    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacBeat")
    }
    func lock() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        descriptor = open(directory.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw PowerError(message: "另一个 MacBeat 控制进程正在运行，请先结束该会话。")
        }
    }
    var isArmed: Bool { FileManager.default.fileExists(atPath: journal.path) }
    func arm() throws {
        let record: [String: Any] = ["version": 1, "pid": getpid(), "created": Date().timeIntervalSince1970,
                                     "operation": "kPMSetClamshellSleepState", "restore": false]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    func disarm() throws {
        if isArmed { try FileManager.default.removeItem(at: journal) }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
