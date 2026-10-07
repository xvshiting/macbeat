import SwiftUI
import AppKit
import MacBeatCore

struct PopoverView: View {
    @ObservedObject var model: SessionController
    @State private var page: Page = CommandLine.arguments.contains("--preview-plan") ? .plan : .session
    @State private var dateOpen = false
    @State private var endEditorOpen = false
    private enum Page { case session, plan, health }
    private var contentHeight: CGFloat {
        let desired: CGFloat = model.showSettings ? 570 : page == .plan ? 610 : page == .health ? 510 : 535
        return min(desired, (NSScreen.main?.visibleFrame.height ?? 900) - 210)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.showSettings {
                HStack(spacing: 3) {
                    tab("保持运行", .session); tab("每日计划", .plan); tab("系统状态", .health)
                }.padding(3).background(BeatStyle.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20)
            }
            ScrollView {
                Group {
                    if model.showSettings { settings }
                    else if page == .plan { DailyPlanView(model: model) }
                    else if page == .health { health }
                    else { session }
                }.padding(.horizontal, 20).padding(.vertical, 18)
            }.frame(height: max(220, contentHeight))
            footer
        }.frame(width: 354).foregroundStyle(BeatStyle.ink)
            .background(LinearGradient(colors: [Color(red: 0.98, green: 0.99, blue: 1), Color(red: 0.95, green: 0.97, blue: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "zh_CN"))
            .onChange(of: page) { if $0 == .health { model.inspect() } }
            .onChange(of: model.running) { running in
                if running { page = .session; model.showSettings = false }
                else { endEditorOpen = false }
            }
            .sheet(item: $model.recoveryConfirmation) { action in recoveryDialog(action) }
            .sheet(isPresented: $endEditorOpen) {
                VStack(spacing: 16) {
                    HStack { Text("调整结束时间").font(.system(size: 17, weight: .semibold)); Spacer(); Button("取消") { endEditorOpen = false }.buttonStyle(.plain) }
                    endEditor
                    BeatPrimary(title: "更新结束时间", disabled: model.validation != nil || model.busy) {
                        model.update(); endEditorOpen = false
                    }
                }.padding(20).frame(width: 314).background(BeatStyle.surface)
            }
    }
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 20)).foregroundStyle(BeatStyle.blue)
            Text("MacBeat").font(.system(size: 15, weight: .semibold)); Spacer()
            Circle().fill(model.running ? Color.green : model.needsRecovery ? Color.orange : BeatStyle.muted.opacity(0.6)).frame(width: 5, height: 5)
            Text(model.statusText).font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
        }.padding(.horizontal, 22).padding(.top, 21).padding(.bottom, 16)
    }
    private func tab(_ text: String, _ target: Page) -> some View {
        Button { page = target } label: {
            Text(text).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(page == target ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(page == target ? BeatStyle.ink : BeatStyle.muted)
        }.buttonStyle(.plain)
    }
    private var session: some View {
        VStack(spacing: 16) {
            if model.running || model.phase == "stopping" || model.keepAwake.agentActive {
                runningCard
                if model.running && !model.scheduledSession {
                    Button("调整结束时间") {
                        if let applied = model.appliedPlan {
                            model.mode = applied.mode; model.duration = applied.duration; model.deadline = applied.deadline
                        }
                        endEditorOpen = true
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(BeatStyle.blue).disabled(model.busy)
                }
            } else {
                endEditor
            }
            Divider().overlay(BeatStyle.line)
            VStack(spacing: 13) {
                detail("laptopcomputer", "合盖保持运行", model.clamshellStatus)
                detail("powerplug", "电源状态", model.powerText)
            }
            BeatPrimary(title: model.busy ? "请稍候…" : model.running ? "停止保持运行" : model.needsRecovery ? "查看恢复状态" : "开启保持运行", disabled: model.busy || (!model.running && !model.needsRecovery && model.validation != nil)) {
                if model.running { model.stop() }
                else if model.needsRecovery { page = .health; model.inspect() }
                else { model.start() }
            }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 10)).foregroundStyle(model.startFailed || model.phase == "error" ? Color.orange : BeatStyle.muted).fixedSize(horizontal: false, vertical: true) }
            if model.preview { Text("界面预览 · 不改变系统状态").font(.system(size: 9)).foregroundStyle(BeatStyle.muted) }
        }
    }
    private var runningCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.green.opacity(0.05)).frame(width: 112, height: 112)
                Circle().fill(Color.green.opacity(0.09)).frame(width: 84, height: 84)
                Image(systemName: "waveform.path.ecg").font(.system(size: 38, weight: .light)).foregroundStyle(.green)
            }.accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(model.phase == "stopping" ? "正在结束保持" : model.running ? model.title : "发现已有保持运行").font(.system(size: 22, weight: .semibold))
                Text(model.scheduledSession ? "每日计划" : model.running ? "本次保持" : "MacBeat 控制会话").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            }
            if model.running || model.phase == "stopping" {
                if let end = model.end {
                    Text(end.formatted(.dateTime.hour().minute())).font(.system(size: 37, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("\(end.formatted(.dateTime.month().day()))结束 · \(model.remaining)").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                } else {
                    Label("直到手动停止", systemImage: "infinity").font(.system(size: 13)).foregroundStyle(BeatStyle.muted)
                }
            } else {
                Text("可在系统状态中手动结束。").font(.system(size: 11)).foregroundStyle(BeatStyle.muted)
            }
        }.frame(maxWidth: .infinity, minHeight: 300).beatCard()
    }
    private var endEditor: some View {
        VStack(spacing: 16) {
                HStack(spacing: 20) {
                    ForEach(EndMode.allCases, id: \.self) { mode in
                        Button { model.mode = mode } label: {
                            Text(mode.title).font(.system(size: 11, weight: model.mode == mode ? .semibold : .regular))
                                .foregroundStyle(model.mode == mode ? BeatStyle.blue : BeatStyle.muted).padding(.bottom, 11)
                                .overlay(alignment: .bottom) { if model.mode == mode { Rectangle().fill(BeatStyle.blue).frame(height: 2) } }
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }.overlay(alignment: .bottom) { Rectangle().fill(BeatStyle.line).frame(height: 0.5) }.disabled(model.busy)
                Group {
                    switch model.mode {
                    case .duration: DurationDial(seconds: $model.duration)
                    case .deadline: deadlinePicker
                    case .manual: unlimited
                    }
                }.disabled(model.busy)
                if let validation = model.validation { Text(validation).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
    private var deadlineMinutes: Binding<Int> {
        Binding(get: { let c = Calendar.current.dateComponents([.hour, .minute], from: model.deadline); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }, set: { minute in
            if let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: model.deadline) { model.deadline = date }
        })
    }
    private var deadlinePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                dayButton("今天", offset: 0); dayButton("明天", offset: 1); Spacer()
                Button { dateOpen.toggle() } label: { Label(model.deadline.formatted(.dateTime.month().day()), systemImage: "calendar") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                    .popover(isPresented: $dateOpen) {
                        DatePicker("结束日期", selection: $model.deadline, in: model.now...model.now.addingTimeInterval(7 * 86400), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden().padding(16)
                    }
            }
            Divider().overlay(BeatStyle.line)
            Spacer(minLength: 6)
            Text("结束于").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            HStack { TimeDigits(value: deadlineMinutes, size: 40, label: "结束"); Spacer(); Text("本地时间").font(.system(size: 9)).foregroundStyle(BeatStyle.muted) }
            Spacer(minLength: 6)
            HStack(spacing: 7) {
                ForEach([15,30,60], id: \.self) { minute in
                    Button(minute == 60 ? "＋1 小时" : "＋\(minute) 分钟") { model.deadline = model.deadline.addingTimeInterval(Double(minute) * 60) }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(BeatStyle.muted).padding(6).background(BeatStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.frame(minHeight: 268).beatCard()
    }
    private func dayButton(_ title: String, offset: Int) -> some View {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: model.now) ?? model.now
        return Button(title) {
            let c = Calendar.current.dateComponents([.hour, .minute], from: model.deadline)
            model.deadline = Calendar.current.date(bySettingHour: c.hour ?? 18, minute: c.minute ?? 0, second: 0, of: day) ?? day
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Calendar.current.isDate(day, inSameDayAs: model.deadline) ? BeatStyle.blue : BeatStyle.muted)
            .padding(7).background(Calendar.current.isDate(day, inSameDayAs: model.deadline) ? BeatStyle.blue.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private var unlimited: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AT YOUR OWN PACE").font(.system(size: 8)).tracking(1.2).foregroundStyle(BeatStyle.muted)
            Spacer(minLength: 12)
            HStack { Text("不限时").font(.system(size: 29, weight: .medium)); Spacer(); Image(systemName: "infinity").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(BeatStyle.blue.opacity(0.25)).accessibilityHidden(true) }
            Text("结束的时刻，由你决定。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            Spacer(minLength: 12)
            HStack(spacing: 6) { Circle().fill(BeatStyle.blue.opacity(0.5)).frame(width: 5, height: 5); Rectangle().fill(LinearGradient(colors: [BeatStyle.blue.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1); Text("···").foregroundStyle(BeatStyle.muted) }.padding(.top, 7)
            HStack { Text("开启后持续运行"); Spacer(); Text("随时手动停止") }.font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
        }.frame(minHeight: 260).padding(20).background(LinearGradient(colors: [.white, BeatStyle.blue.opacity(0.07)], startPoint: .bottomLeading, endPoint: .topTrailing), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(BeatStyle.line, lineWidth: 0.7))
    }
    private func detail(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) { Image(systemName: symbol).frame(width: 15).foregroundStyle(BeatStyle.muted); Text(label); Spacer(minLength: 6); Text(value).font(.system(size: 9)).foregroundStyle(BeatStyle.muted).multilineTextAlignment(.trailing) }.font(.system(size: 11))
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(BeatStyle.line)
            HStack(spacing: 8) {
                Button { model.showSettings.toggle() } label: { Image(systemName: model.showSettings ? "chevron.left" : "gearshape") }.buttonStyle(.plain).accessibilityLabel(model.showSettings ? "返回" : "设置")
                Text(model.powerOnly ? "仅接通电源时运行" : "允许使用电池运行").font(.system(size: 9))
                Spacer(minLength: 4)
            }.foregroundStyle(BeatStyle.muted).padding(.horizontal, 20).padding(.vertical, 13)
        }
    }
    private var health: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("系统状态").font(.system(size: 19, weight: .semibold)); Spacer(); Button { model.inspect() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).accessibilityLabel("重新检测") }
            Text("检查当前系统状态，处理未结束的保持。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            VStack(spacing: 14) {
                detail("powerplug", "电源状态", model.powerText)
                detail("laptopcomputer", "屏幕盖", model.power?.lidClosed.map { $0 ? "已合盖" : "已开盖" } ?? "读取中")
                detail("thermometer.medium", "温度压力", model.power.map { ["正常", "轻度", "较高", "严重"][max(0, min(3, $0.thermal))] } ?? "读取中")
                detail("moon", "全局禁用睡眠", model.keepAwake.globalSleepDisabled.map { $0 ? "已开启" : "未开启" } ?? "未知")
            }.beatCard()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: model.needsRecovery ? "arrow.counterclockwise" : model.running ? "waveform.path.ecg" : "checkmark.shield").foregroundStyle(model.needsRecovery ? Color.orange : BeatStyle.blue)
                Text(model.running ? "MacBeat 正在运行" : model.keepAwake.agentActive ? "发现 MacBeat 控制会话" : model.keepAwake.recoveryRecord ? "发现 MacBeat 恢复记录" : "MacBeat 状态正常").font(.system(size: 13, weight: .semibold))
                Text(model.needsRecovery ? "可结束现有 MacBeat 会话并处理遗留记录，不会强制电脑立即休眠。" : model.running ? model.remaining : "未发现待处理的会话或恢复记录。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                if model.needsRecovery || model.running {
                    Button(model.running ? "结束本次保持" : "结束遗留保持") { model.recoveryConfirmation = .owned }.buttonStyle(.bordered).disabled(model.busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).beatCard()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("系统共享合盖状态").font(.system(size: 13, weight: .semibold)); Spacer(); Text(model.keepAwake.clamshellBlocked.map { $0 ? "保持中" : "未阻止" } ?? "未知").font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
                Text("系统的合盖结果无法确定来源，也可能受其他应用或外接显示器影响。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                if model.keepAwake.globalSleepDisabled == true {
                    Text("系统另有全局禁用睡眠设置；此处解除不会修改该设置。").font(.system(size: 10)).foregroundStyle(.orange)
                }
                if model.keepAwake.clamshellBlocked == true {
                    Button("手动解除共享保持") { model.recoveryConfirmation = .shared }.buttonStyle(.bordered).disabled(model.active || model.keepAwake.agentActive)
                    if model.active || model.keepAwake.agentActive { Text("请先结束 MacBeat 控制会话。").font(.system(size: 9)).foregroundStyle(BeatStyle.muted) }
                }
            }.beatCard()
            if !model.recoveryNotice.isEmpty { Text(model.recoveryNotice).font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
    private func recoveryDialog(_ action: SessionController.RecoveryAction) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action == .owned ? "结束 MacBeat 的保持运行？" : "解除系统共享合盖状态？").font(.system(size: 18, weight: .semibold))
            Text(action == .owned ? "结束 MacBeat 控制会话并处理遗留记录，不会强制电脑立即休眠。本次每日计划时段将不再自动重启。" : "无法确认该状态来自哪个程序。解除可能影响其他合盖工具；不会修改全局睡眠设置，实际休眠仍受系统和其他应用影响。").font(.system(size: 12)).foregroundStyle(BeatStyle.muted)
            HStack { Button("取消") { model.recoveryConfirmation = nil }.keyboardShortcut(.cancelAction); Spacer(); Button(action == .owned ? "结束并恢复" : "确认解除") { model.recoveryConfirmation = nil; model.restore(action) }.buttonStyle(.borderedProminent).tint(BeatStyle.blue).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 330).background(BeatStyle.surface)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("设置").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { model.saveSettings(); model.showSettings = false }.buttonStyle(.plain).foregroundStyle(BeatStyle.blue) }
            VStack(alignment: .leading, spacing: 17) {
                Toggle("仅接通电源时运行", isOn: $model.powerOnly)
                HStack { Text("低电量停止阈值"); Spacer(); Picker("低电量阈值", selection: $model.batteryThreshold) { ForEach([10,15,20,30], id: \.self) { Text("\($0)%").tag($0) } }.labelsHidden().frame(width: 80) }
                Toggle("合盖时保持运行", isOn: $model.clamshell)
                Text("关闭后只阻止空闲休眠，合盖仍会休眠。屏幕可以正常熄灭。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            }.disabled(model.active).onChange(of: model.powerOnly) { _ in model.saveSettings() }.onChange(of: model.clamshell) { _ in model.saveSettings() }.onChange(of: model.batteryThreshold) { _ in model.saveSettings() }
            if model.active { Text("停止当前运行后可修改运行条件。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
            Divider()
            Toggle("登录时启动 MacBeat", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            if !model.loginNotice.isEmpty { Text(model.loginNotice).font(.system(size: 10)).foregroundStyle(.orange) }
            Text("每日计划需要 MacBeat 在运行，不会唤醒已休眠或关机的电脑。在时段内唤醒后会运行至该时段结束。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            Text("手动停止或保护停止后，本时段不会重启；已有手动会话时跳过该时段。").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            Divider()
            HStack { Text("MacBeat \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")").foregroundStyle(BeatStyle.muted); Spacer(); Button("退出") { NSApplication.shared.terminate(nil) } }.font(.system(size: 10))
        }.font(.system(size: 12)).toggleStyle(.switch)
    }
}
