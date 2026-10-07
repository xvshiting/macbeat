import Foundation
import Darwin
import MacBeatCore

/// User-local journal records only MacBeat's transient clamshell write.
/// No root privileges, login daemon, or system preferences are modified.
final class RecoveryStore {
    let directory: URL
    var journal: URL { directory.appendingPathComponent("clamshell-recovery.json") }
    private var descriptor: Int32 = -1
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBeat")) {
        self.directory = directory
    }
    func unlock() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    func lock() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        descriptor = open(directory.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            throw PowerError(message: "另一个 MacBeat 控制进程正在运行，请先结束该会话。")
        }
    }
    private var sessionFile: URL { directory.appendingPathComponent("agent-session.json") }
    private var stopFile: URL { directory.appendingPathComponent("stop-request.json") }
    private var token: String?
    struct Session: Codable { let token: String }
    static func agentActive(in directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("agent.lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
    var agentActive: Bool { Self.agentActive(in: directory) }
    func registerAgent() throws {
        let id = UUID().uuidString
        try JSONEncoder().encode(Session(token: id)).write(to: sessionFile, options: .atomic)
        token = id
    }
    var stopRequested: Bool {
        guard let token, let data = try? Data(contentsOf: stopFile),
              let request = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        return request.token == token
    }
    func requestStop() throws {
        guard agentActive else { return }
        guard let data = try? Data(contentsOf: sessionFile),
              let session = try? JSONDecoder().decode(Session.self, from: data) else {
            throw PowerError(message: "检测到旧版 MacBeat 控制进程，请先在原应用中停止，或等待连接超时后再恢复。")
        }
        try JSONEncoder().encode(session).write(to: stopFile, options: .atomic)
        // The owning agent handles the stop itself; never signal an unverified PID.
        for _ in 0..<60 {
            if !agentActive { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw PowerError(message: "已请求结束 MacBeat 会话，但尚未确认停止。请稍后重新检测。")
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
    deinit { unlock() }
}
