import SwiftUI
import MacBeatCore

struct PopoverView: View {
    @ObservedObject var model: SessionController
    private let blue = Color(red: 0.16, green: 0.46, blue: 0.92)
    private let ink = Color(red: 0.12, green: 0.17, blue: 0.24)
    var body: some View {
        VStack(spacing: 0) {
            if model.showSettings { settings } else { main }
        }
        .frame(width: 354)
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(red: 0.96, green: 0.97, blue: 0.99), Color(red: 0.91, green: 0.93, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 20)).foregroundStyle(blue)
                Text("MacBeat").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(model.running ? Color.green : model.startFailed ? Color.orange : Color.gray).frame(width: 6, height: 6)
                Text(model.statusText).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 19)
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill((model.running ? Color.green : blue).opacity(0.035)).frame(width: 94, height: 94)
                    Circle().fill((model.running ? Color.green : blue).opacity(0.07)).frame(width: 78, height: 78)
                    Circle().fill((model.running ? Color.green : blue).opacity(0.09)).frame(width: 64, height: 64)
                    Image(systemName: model.running ? "waveform.path.ecg" : "moon").font(.system(size: 30, weight: .light)).foregroundStyle(model.running ? Color.green : blue)
                }
                Text(model.title).font(.system(size: 22, weight: .semibold))
                Text(model.subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 13).padding(.bottom, 22)
            VStack(spacing: 12) {
                HStack {
                    Text("何时结束")
                    Spacer()
                    Text(model.running ? "修改后点击更新" : "到时恢复系统睡眠策略").foregroundStyle(.tertiary)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("结束方式", selection: $model.mode) {
                    ForEach(EndMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
                if model.mode == .duration {
                    HStack(spacing: 7) {
                        ForEach([1800.0, 3600, 7200], id: \.self) { seconds in
                            Button { model.duration = seconds } label: {
                                Text(seconds == 1800 ? "30 分钟" : "\(Int(seconds / 3600)) 小时")
                                    .font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(model.duration == seconds ? blue.opacity(0.12) : Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(model.duration == seconds ? blue : .secondary)
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                } else if model.mode == .deadline {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("结束时间", systemImage: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                        DatePicker("结束日期和时间", selection: $model.deadline, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.field).labelsHidden().font(.system(size: 15)).disabled(model.busy)
                            .accessibilityLabel("结束日期和时间")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 8) {
                        dateShortcut("今天", offset: 0); dateShortcut("明天", offset: 1)
                        Spacer(); Text("本机当地时间").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("保持运行，直到你手动停止。").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                if let error = model.validation {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                } else if model.mode != .manual, let date = try? model.plan.endDate(now: model.now) {
                    Text(date.formatted(.dateTime.month().day().hour().minute()) + " 结束保持运行")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.running {
                    Button("更新结束时间") { model.update() }
                        .buttonStyle(.bordered).tint(blue).controlSize(.small).frame(maxWidth: .infinity)
                        .disabled(!model.changed || model.validation != nil)
                }
                VStack(spacing: 0) {
                    detail("laptopcomputer", title: "合盖保持运行", value: model.clamshellStatus)
                    Divider().padding(.horizontal, 12)
                    detail("powerplug", title: "电源状态", value: model.powerText)
                }.background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    if model.running { model.stop() }
                    else if model.phase == "error" { model.recover() }
                    else { model.start() }
                } label: {
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.running ? "停止保持运行" : model.phase == "error" ? "恢复状态" : model.busy ? "请稍候…" : model.startFailed ? "重新尝试开启" : model.clamshell ? "开启保持运行" : "开启防空闲休眠").font(.system(size: 12, weight: .medium))
                    }.frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(model.running ? ink : .white)
                        .background(model.running ? Color.white : blue, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(model.busy || (!model.running && model.phase != "error" && model.validation != nil))
                if model.running { Text(model.remaining).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                if !model.message.isEmpty { Text(model.message).font(.system(size: 10)).foregroundStyle(model.phase == "error" || model.startFailed ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true) }
                if model.preview { Text("界面预览 · 不改变系统状态").font(.system(size: 9)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.bottom, 16)
            Divider()
            HStack {
                Text(model.powerOnly ? "仅接通电源时运行" : "允许使用电池运行").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button { model.showSettings = true } label: { Label("设置…", systemImage: "gearshape").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
    private func detail(_ icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            Text(title); Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).font(.system(size: 9)).multilineTextAlignment(.trailing)
        }.font(.system(size: 11)).padding(12)
    }
    private func dateShortcut(_ label: String, offset: Int) -> some View {
        Button(label) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: model.deadline)
            let day = Calendar.current.date(byAdding: .day, value: offset, to: model.now)!
            model.deadline = Calendar.current.date(bySettingHour: parts.hour ?? 18, minute: parts.minute ?? 0, second: 0, of: day)!
        }.buttonStyle(.bordered).controlSize(.mini).disabled(model.busy)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Button { model.showSettings = false; model.saveSettings() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text("设置").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Text("运行条件").font(.system(size: 10)).foregroundStyle(.secondary)
            Toggle("仅接通电源时运行", isOn: $model.powerOnly)
            HStack {
                Text("电量低于以下值时停止"); Spacer()
                Picker("低电量阈值", selection: $model.batteryThreshold) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }.labelsHidden().frame(width: 73)
            }
            Divider()
            Toggle("合盖时保持运行", isOn: $model.clamshell)
            Text("开启后，开盖和合盖都保持系统唤醒。屏幕可以正常熄灭；到时或手动停止后恢复系统睡眠策略。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("关闭此项后，合盖仍会休眠；开盖后继续防止空闲休眠。若需要合盖运行，请开启此项。").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("请勿同时开启其他合盖工具。更新 macOS 或改变外接设备后，建议重新确认合盖运行效果。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("登录时启动 MacBeat", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            if !model.loginNotice.isEmpty { Text(model.loginNotice).font(.system(size: 10)).foregroundStyle(.orange) }
            Text("登录后在菜单栏待命，不自动开启保持运行。").font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("MacBeat \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")").foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }.font(.system(size: 10))
            if model.active { Text("运行条件将在停止后允许修改。").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.font(.system(size: 12)).toggleStyle(.switch).padding(20)
            .disabled(model.active)
            .overlay(alignment: .topLeading) {
                if model.active { Button { model.showSettings = false } label: { Image(systemName: "chevron.left").padding(20) }.buttonStyle(.plain) }
            }
    }
}
