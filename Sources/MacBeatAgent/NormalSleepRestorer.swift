import Foundation
import MacBeatCore

/// Only fixed pmset operations may enter the privileged shell. No executable,
/// PID, assertion name, or user-provided text is interpolated into this command.
struct SleepPreferences {
    var disabledProfiles: [String]
    static let profiles = ["Battery Power": "-b", "AC Power": "-c", "UPS Power": "-u"]
    init(output: String) throws {
        var profile: String?
        var seen = Set<String>()
        var disabled: [String] = []
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                let title = String(text.dropLast())
                profile = Self.profiles[title] != nil ? title : nil; continue
            }
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "sleep", fields.count >= 2, let profile, let value = Int(fields[1]), value >= 0 {
                seen.insert(profile)
                if value == 0 { disabled.append(profile) }
            }
        }
        guard !seen.isEmpty else { throw PowerError(message: "无法读取系统自动睡眠时间，未更改全局设置。") }
        disabledProfiles = Array(Set(disabled)).sorted()
    }
    var command: String {
        (["/usr/bin/pmset -a disablesleep 0"] + disabledProfiles.compactMap { profile in
            Self.profiles[profile].map { "/usr/bin/pmset \($0) sleep 10" }
        }).joined(separator: " && ")
    }
    static func read() throws -> SleepPreferences {
        let result = try runTool("/usr/bin/pmset", ["-g", "custom"])
        guard result.code == 0 else { throw PowerError(message: "读取系统睡眠设置失败。") }
        return try SleepPreferences(output: result.output)
    }
}

struct ToolResult { var code: Int32; var output: String }
func runTool(_ executable: String, _ arguments: [String]) throws -> ToolResult {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return ToolResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

struct NormalSleepRestorer {
    var preferences: () throws -> SleepPreferences = { try SleepPreferences.read() }
    var authorize: (SleepPreferences) throws -> Bool = { preferences in
        // macOS presents its own administrator authorization dialog. Passwords
        // are never handled by MacBeat. Cancellation is a separate outcome.
        let script = "do shell script \"\(preferences.command)\" with administrator privileges"
        let result = try runTool("/usr/bin/osascript", ["-e", script])
        if result.code == 0 { return true }
        if result.output.contains("(-128)") { return false }
        throw PowerError(message: "修改全局睡眠设置失败：" + String(result.output.prefix(500)))
    }
    var stopOwned: () throws -> Void
    var releaseClamshell: () throws -> Void

    func restore() -> SleepRestoreReport {
        var report = SleepRestoreReport()
        do {
            let prefs = try preferences()
            guard try authorize(prefs) else { report.cancelled = true; return report }
            report.completed.append("已请求关闭全局禁用睡眠。")
            if !prefs.disabledProfiles.isEmpty { report.completed.append("原先关闭的自动睡眠已设为闲置 10 分钟。") }
        } catch {
            // Authorization failure must not stop other sessions or alter the
            // shared clamshell bit. Report a possible partial pmset failure.
            report.errors.append(error.localizedDescription); return report
        }
        do { try stopOwned(); report.completed.append("MacBeat 会话与恢复记录已处理。") }
        catch { report.errors.append(error.localizedDescription); return report }
        do { try releaseClamshell(); report.sharedHoldReleased = true; report.completed.append("已请求解除合盖保持。") }
        catch { report.errors.append(error.localizedDescription) }
        return report
    }
}
