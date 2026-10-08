import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var popover = NSPopover()
    var model: SessionController!
    var previewWindow: NSWindow?
    var quitting = false
    private var iconState: StatusItemIcon.State?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier?.hasPrefix("dev.macbeat.preview") == true
        model = SessionController(preview: preview)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "MacBeat · 未开启"
        updateStatus()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.statusChanged = { [weak self] in self?.updateStatus() }
        model.safeToQuit = { [weak self] in
            guard let self, self.quitting, !self.model.restoringNormalSleep else { return }
            if self.model.active { self.model.stop(); return }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        if preview || CommandLine.arguments.contains("--show-window") || Bundle.main.object(forInfoDictionaryKey: "MacBeatShowWindow") as? Bool == true {
            let controller = NSHostingController(rootView: PopoverView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = preview ? "MacBeat · 界面预览" : "MacBeat"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else { togglePopover() }
    }
    @objc func togglePopover() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开 MacBeat", action: #selector(openPopover), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 MacBeat", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }
    @objc func openPopover() {
        guard let button = item.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func updateStatus() {
        item.button?.toolTip = model.running ? "MacBeat · \(model.remaining)" : "MacBeat · \(model.statusText)"
        let state: StatusItemIcon.State = model.running ? .running : (model.startFailed || model.needsRecovery || model.phase == "recovering") ? .attention : .idle
        if iconState != state {
            item.button?.image = StatusItemIcon.make(state)
            iconState = state
        }
        item.button?.contentTintColor = nil
        item.button?.title = ""
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPopover()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.preview { return .terminateNow }
        guard model.active || model.phase == "error" else { return .terminateNow }
        quitting = true
        model.schedulingPaused = true
        if model.restoringNormalSleep { return .terminateLater }
        model.stop()
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct MacBeatMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
