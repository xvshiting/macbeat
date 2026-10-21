import Foundation
import MacBeatCore

@MainActor protocol WakeScheduling: AnyObject {
    func configure(_ schedule: DailySchedule, authorize: Bool, completion: @escaping (Result<WakeScheduleStatus, Error>) -> Void)
    func disconnect()
    func remove(completion: @escaping (Result<Void, Error>) -> Void)
}

@MainActor final class WakeSchedulerClient: WakeScheduling {
    private var connection: NSXPCConnection?
    private var pending: [UUID: (Result<WakeScheduleStatus, Error>) -> Void] = [:]
    private var revision = 0
    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacBeatWakeService") }

    nonisolated private static func tool(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    nonisolated private static func privileged(_ helper: URL, action: String) throws {
        // action is fixed by the app. Escape both shell and AppleScript layers.
        let command = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + action
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let result = try tool("/usr/bin/osascript", ["-e", "do shell script \"\(literal)\" with administrator privileges"])
        if result.0 != 0 {
            throw WakeScheduleError(result.1.contains("(-128)") ? "已取消授权，未保存此次计划。" : "设置唤醒服务失败：" + String(result.1.prefix(400)))
        }
    }
    func configure(_ schedule: DailySchedule, authorize: Bool, completion: @escaping (Result<WakeScheduleStatus, Error>) -> Void) {
        revision += 1
        let requestedRevision = revision
        failPending(WakeScheduleError("已使用较新的计划请求。"))
        let needsWake = schedule.enabled && schedule.wakeComputer
        if !needsWake, connection == nil { completion(.success(WakeScheduleStatus())); return }
        let executable = helper
        DispatchQueue.global(qos: .utility).async {
            do {
                if needsWake {
                    let result = try Self.tool(executable.path, ["--check"])
                    if result.0 != 0 || result.1.trimmingCharacters(in: .whitespacesAndNewlines) != "installed" {
                        guard authorize else { throw WakeScheduleError("唤醒服务尚未授权或应用已更新，请重新保存计划以授权。") }
                        try Self.privileged(executable, action: "--install")
                    }
                }
                Task { @MainActor in
                    guard self.revision == requestedRevision else {
                        completion(.failure(WakeScheduleError("已使用较新的计划请求。"))); return
                    }
                    self.send(schedule, completion: completion)
                }
            } catch { Task { @MainActor in completion(.failure(error)) } }
        }
    }
    private func send(_ schedule: DailySchedule, completion: @escaping (Result<WakeScheduleStatus, Error>) -> Void) {
        let connection: NSXPCConnection
        if let current = self.connection { connection = current }
        else {
            connection = NSXPCConnection(machServiceName: WakeService.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: WakeServiceProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    self.connection = nil
                    self.failPending(WakeScheduleError("唤醒服务连接已断开，预约状态尚未确认。"))
                }
            }
            connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
            self.connection = connection; connection.resume()
        }
        let id = UUID(); pending[id] = completion
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.finish(id, .failure(error)) }
        } as? WakeServiceProtocol
        guard let proxy, let data = try? JSONEncoder().encode(schedule) else {
            finish(id, .failure(WakeScheduleError("无法发送唤醒计划。"))); return
        }
        proxy.configure(data) { [weak self] data, error in
            Task { @MainActor in
                if let error { self?.finish(id, .failure(WakeScheduleError(error))) }
                else if let data, let status = try? JSONDecoder().decode(WakeScheduleStatus.self, from: data) {
                    self?.finish(id, .success(status))
                } else { self?.finish(id, .failure(WakeScheduleError("唤醒服务没有返回有效结果。"))) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.finish(id, .failure(WakeScheduleError("确认唤醒预约超时，请重试保存计划。")))
            self.disconnect()
        }
    }
    private func finish(_ id: UUID, _ result: Result<WakeScheduleStatus, Error>) { pending.removeValue(forKey: id)?(result) }
    private func failPending(_ error: Error) {
        let callbacks = pending.values; pending.removeAll()
        for callback in callbacks { callback(.failure(error)) }
    }
    func disconnect() {
        revision += 1
        let old = connection; connection = nil; old?.invalidate()
        failPending(WakeScheduleError("唤醒连接已关闭。"))
    }
    func remove(completion: @escaping (Result<Void, Error>) -> Void) {
        let executable = helper
        DispatchQueue.global(qos: .utility).async {
            do {
                try Self.privileged(executable, action: "--uninstall")
                Task { @MainActor in self.disconnect(); completion(.success(())) }
            } catch { Task { @MainActor in completion(.failure(error)) } }
        }
    }
}
