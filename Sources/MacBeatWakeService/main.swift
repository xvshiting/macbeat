import Foundation
import Security
import IOKit.pwr_mgt
import Darwin
import MacBeatCore

func failure(_ text: String) -> Error { WakeScheduleError(text) }
let files = FileManager.default

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
func requireRootDirectory(_ path: String) throws {
    if !files.fileExists(atPath: path) { try files.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
    let attributes = try files.attributesOfItem(atPath: path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
          ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
        throw failure("唤醒服务目录的权限不安全，未安装。")
    }
}
func rootWrite(_ data: Data, to path: String, permissions: Int) throws {
    // Atomic replacement in a root-owned directory; never follow a destination symlink.
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try files.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: permissions], ofItemAtPath: path)
}
func clientRequirement() throws -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "dev.macbeat.app" else {
        throw failure("请从正式 MacBeat 应用中安装唤醒服务。")
    }
    var code: SecStaticCode?, requirement: SecRequirement?, text: CFString?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess,
          SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
        throw failure("无法验证 MacBeat 签名，未安装唤醒服务。")
    }
    return text as String
}
func installationMatches() -> Bool {
    guard let expected = try? clientRequirement(),
          let data = files.contents(atPath: WakeService.clientRequirement),
          let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return false }
    return files.isExecutableFile(atPath: WakeService.executable) && value["requirement"] == expected && value["version"] == "1"
        && (try? run("/bin/launchctl", ["print", "system/" + WakeService.label])) == 0
}
func cancelOwnEvents() throws {
    for event in IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? [] {
        guard let owner = event[kIOPMPowerEventAppNameKey] as? String,
              owner.hasPrefix(WakeService.ownerPrefix), UInt32(owner.dropFirst(WakeService.ownerPrefix.count)) != nil,
              event[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake,
              let date = event[kIOPMPowerEventTimeKey] as? Date else { continue }
        try cancelWake(ScheduledWake(date: date, owner: owner))
    }
}
func install() throws {
    let requirement = try clientRequirement()
    try requireRootDirectory("/Library/PrivilegedHelperTools")
    try requireRootDirectory("/Library/LaunchDaemons")
    _ = try run("/bin/launchctl", ["bootout", "system/" + WakeService.label])
    guard try run("/bin/launchctl", ["print", "system/" + WakeService.label]) != 0 else { throw failure("旧的唤醒服务未能退出，请重试。") }
    try cancelOwnEvents()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try rootWrite(Data(contentsOf: source), to: WakeService.executable, permissions: 0o755)
    let configuration = ["requirement": requirement, "version": "1"]
    try rootWrite(PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0), to: WakeService.clientRequirement, permissions: 0o644)
    let plist: [String: Any] = ["Label": WakeService.label, "ProgramArguments": [WakeService.executable],
        "MachServices": [WakeService.label: true], "UserName": "root", "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10]
    try rootWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: WakeService.launchPlist, permissions: 0o644)
    guard try run("/bin/launchctl", ["bootstrap", "system", WakeService.launchPlist]) == 0 else {
        throw failure("唤醒服务安装后未能启动，请重试。")
    }
}
func uninstall() throws {
    // Cancel successfully before removing the service, so a retry remains possible.
    try cancelOwnEvents()
    _ = try run("/bin/launchctl", ["bootout", "system/" + WakeService.label])
    guard try run("/bin/launchctl", ["print", "system/" + WakeService.label]) != 0 else { throw failure("唤醒服务未能退出，暂未删除文件。") }
    try cancelOwnEvents()
    for path in [WakeService.launchPlist, WakeService.clientRequirement, WakeService.executable] {
        if files.fileExists(atPath: path) { try files.removeItem(atPath: path) }
    }
}

if CommandLine.arguments.contains("--check") {
    print(installationMatches() ? "installed" : "not-installed"); exit(0)
}
if CommandLine.arguments.contains("--validate-bundle") {
    do { _ = try clientRequirement(); print("bundle-signature-valid"); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
guard geteuid() == 0 else { fputs("唤醒服务需要由系统管理员授权安装。\n", stderr); exit(1) }
if CommandLine.arguments.contains("--install") || CommandLine.arguments.contains("--uninstall") {
    do {
        if CommandLine.arguments.contains("--install") { try install() } else { try uninstall() }
        print("ok"); exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}

let queue = DispatchQueue(label: "dev.macbeat.wake-service.control")
func addWake(_ event: ScheduledWake) throws {
    let exists = (IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []).contains {
        $0[kIOPMPowerEventTimeKey] as? Date == event.date && $0[kIOPMPowerEventAppNameKey] as? String == event.owner && $0[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake
    }
    if exists { return }
    let result = IOPMSchedulePowerEvent(event.date as CFDate, event.owner as CFString, kIOPMAutoWake as CFString)
    guard result == kIOReturnSuccess else { throw failure("登记唤醒时间失败（\(result)）。") }
}
func cancelWake(_ event: ScheduledWake) throws {
    let result = IOPMCancelScheduledPowerEvent(event.date as CFDate, event.owner as CFString, kIOPMAutoWake as CFString)
    if result != kIOReturnSuccess {
        let exists = (IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []).contains {
            $0[kIOPMPowerEventTimeKey] as? Date == event.date && $0[kIOPMPowerEventAppNameKey] as? String == event.owner && $0[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake
        }
        if exists { throw failure("撤销唤醒时间失败（\(result)）。") }
    }
}
let store = WakeScheduleStore(add: addWake, cancel: cancelWake)

final class ClientSession: NSObject, WakeServiceProtocol {
    let uid: UInt32, token = UUID()
    init(uid: UInt32) { self.uid = uid }
    func configure(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                guard data.count <= 16384 else { throw failure("唤醒计划过大。") }
                let plan = try JSONDecoder().decode(DailySchedule.self, from: data)
                let status = try store.configure(uid: self.uid, token: self.token, schedule: plan, now: Date())
                reply(try JSONEncoder().encode(status), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func disconnected() { queue.async { try? store.disconnect(uid: self.uid, token: self.token) } }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: SecRequirement
    init(requirement: SecRequirement) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Pin the exact approved app's designated requirement (ad-hoc builds
        // include a cdhash), not just a spoofable bundle ID. Upgrades reauthorize.
        guard connection.effectiveUserIdentifier >= 500 else { return false }
        var peer: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess, let peer,
              SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else { return false }
        let session = ClientSession(uid: connection.effectiveUserIdentifier)
        connection.exportedInterface = NSXPCInterface(with: WakeServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnected() }
        connection.interruptionHandler = { [weak connection] in session.disconnected(); connection?.invalidate() }
        connection.resume(); return true
    }
}

do {
    // A fresh daemon must clear bookings whose process/connection died with it.
    try cancelOwnEvents()
    let data = try Data(contentsOf: URL(fileURLWithPath: WakeService.clientRequirement))
    let configuration = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
    var requirement: SecRequirement?
    guard let text = configuration?["requirement"],
          SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
        throw failure("无法读取授权的 MacBeat 签名。")
    }
    let delegate = ListenerDelegate(requirement: requirement)
    let listener = NSXPCListener(machServiceName: WakeService.label)
    listener.delegate = delegate; listener.resume()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { store.refresh(now: Date()) }; timer.resume()
    var signals: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: queue)
        source.setEventHandler { store.cancelAll(); exit(0) }; source.resume(); signals.append(source)
    }
    withExtendedLifetime((delegate, listener, timer, signals)) { dispatchMain() }
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
