import SwiftUI
import MacBeatCore

struct DailyPlanView: View {
    @ObservedObject var model: SessionController
    @State private var selected: UUID?
    @State private var merge: DailySchedule.MergeProposal?
    @State private var error = ""
    @State private var drag: ArcDrag?
    private struct ArcDrag {
        var original: DailyPeriod
        var kind: PeriodDrag?
        var anchor: Int
        var candidate: DailyPeriod
        var moved: Bool
    }
    private var selection: DailyPeriod? { model.dailySchedule.periods.first { $0.id == selected } ?? model.dailySchedule.periods.first }
    private var displayed: [DailyPeriod] {
        var values = model.dailySchedule.periods
        if let drag {
            if let i = values.firstIndex(where: { $0.id == drag.original.id }) { values[i] = drag.candidate }
            else if drag.candidate.isValid { values.append(drag.candidate) }
        }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("每天，按你的节奏。").font(.system(size: 19, weight: .semibold))
                Spacer(); Toggle("启用每日计划", isOn: $model.dailySchedule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.active)
            }
            Text(model.dailySchedule.enabled ? "每天重复，让运行与休息各有时刻。" : "计划已暂停，时段会为你保留。")
                .font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            circle
            if let period = selection { editor(period).id(period.id) }
            HStack { Text("全部时段"); Spacer(); Text("\(model.dailySchedule.periods.filter(\.enabled).count) 段已启用") }.font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            VStack(spacing: 2) { ForEach(model.dailySchedule.periods) { period in row(period) } }
            Button { add() } label: { Label("添加一个时段", systemImage: "plus") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(BeatStyle.blue).disabled(model.active)
            if !error.isEmpty { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            if let validation = model.scheduleValidation { Text(validation).font(.system(size: 10)).foregroundStyle(.orange) }
            Text(model.active ? "停止当前运行后可编辑计划。" : "仅在所选时段保持运行。请保持 MacBeat 开启，计划才会执行。")
                .font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
            BeatPrimary(title: model.scheduleChanged ? "保存每日计划" : "计划已保存", symbol: "checkmark", disabled: model.active || !model.scheduleChanged || model.scheduleValidation != nil) { model.saveDailySchedule() }
            if !model.scheduleNotice.isEmpty { Text(model.scheduleNotice).font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
            if !model.nextScheduleText.isEmpty { Text(model.nextScheduleText).font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
        }
        .sheet(item: $merge) { proposal in
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(BeatStyle.blue)
                Text("时段重叠，要合并吗？").font(.system(size: 18, weight: .semibold))
                Text("这 \(proposal.overlapping.count + 1) 个时段有重叠，可以合成一段连续运行时间。").font(.system(size: 12)).foregroundStyle(BeatStyle.muted)
                Text(([proposal.candidate] + proposal.overlapping).sorted { $0.startMinute < $1.startMinute }.map { clockLabel($0.startMinute) + "–" + clockLabel($0.endMinute) }.joined(separator: "  ·  ")).font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                VStack(alignment: .leading, spacing: 9) {
                    Text("合并后 · 每天重复").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                    Text(clockLabel(proposal.merged.startMinute) + " → " + clockLabel(proposal.merged.endMinute)).font(.system(size: 25, weight: .medium)).foregroundStyle(BeatStyle.blue).monospacedDigit()
                    Text("共 " + minutesLabel(proposal.merged.minutes)).font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).beatCard()
                HStack {
                    Button("取消") { merge = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("合并时段") {
                        model.dailySchedule.apply(proposal.candidate, merging: true)
                        selected = proposal.candidate.id; merge = nil
                    }.buttonStyle(.borderedProminent).tint(BeatStyle.blue).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 340).background(BeatStyle.surface)
        }
    }
    private var circle: some View {
        VStack(spacing: 0) {
            HStack { Text("一天的运行节奏"); Spacer(); Text("24 小时圆盘") }.font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
            ZStack {
                DialFace()
                ForEach(displayed) { period in
                    if period.isValid {
                        DialArc(start: Double(period.startMinute), end: Double(period.endMinute))
                            .stroke(period.enabled ? (selection?.id == period.id ? BeatStyle.blue : BeatStyle.blue.opacity(0.40)) : BeatStyle.muted.opacity(0.2), style: StrokeStyle(lineWidth: selection?.id == period.id ? 10 : 7, lineCap: .round))
                            .frame(width: 176, height: 176).position(DialGeometry.center)
                    }
                }
                if let period = drag?.candidate ?? selection, period.isValid {
                    ForEach([period.startMinute, period.endMinute], id: \.self) { minute in
                        Circle().fill(.white).overlay(Circle().stroke(BeatStyle.blue, lineWidth: 2))
                            .frame(width: 9, height: 9).position(DialGeometry.point(minute))
                    }
                }
                center.allowsHitTesting(false).position(x: 126, y: 121)
                Color.clear.contentShape(DialRingHitArea()).gesture(DragGesture(minimumDistance: 0).onChanged(updateDrag).onEnded(finishDrag)).disabled(model.active)
                    .accessibilityLabel("每日计划圆盘").accessibilityHint("可通过下方时段列表选择并编辑时间")
            }.frame(width: 252, height: 240).padding(.top, 6)
            Text("拖两端改时间 · 拖中间平移\n空白处拖动新增，点击弧段精调").font(.system(size: 9)).foregroundStyle(BeatStyle.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).beatCard(padding: 14)
    }
    @ViewBuilder private var center: some View {
        VStack(spacing: 6) {
            if let drag, drag.moved {
                Text(drag.kind == nil ? "新增时段" : "调整时段").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                Text(clockLabel(drag.candidate.startMinute) + "–" + clockLabel(drag.candidate.endMinute)).font(.system(size: 19, weight: .medium)).foregroundStyle(BeatStyle.blue).monospacedDigit()
                Text(model.dailySchedule.mergeProposal(for: drag.candidate) == nil ? "松开完成" : "松开后可合并").font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
            } else {
                Text(model.dailySchedule.enabled ? "每日运行" : "计划暂停").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(model.dailySchedule.totalMinutes / 60)").font(.system(size: 37, weight: .medium, design: .rounded))
                    Text("小时").font(.system(size: 10))
                    if model.dailySchedule.totalMinutes % 60 > 0 { Text("\(model.dailySchedule.totalMinutes % 60) 分").font(.system(size: 12)) }
                }.foregroundStyle(BeatStyle.ink)
                Text("\(model.dailySchedule.periods.filter(\.enabled).count) 个时段 · 每天重复").font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
            }
        }
    }
    private func editor(_ period: DailyPeriod) -> some View {
        VStack(spacing: 14) {
            HStack { Label("正在编辑", systemImage: "circle.fill"); Spacer(); Text("点击数字修改") }.font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    TimeDigits(value: timeBinding(period, start: true), size: 29, label: "开始")
                    Text("开始运行").font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
                }
                Spacer(); Image(systemName: "arrow.right").foregroundStyle(BeatStyle.line); Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    TimeDigits(value: timeBinding(period, start: false), maximum: 1440, size: 29, label: "结束")
                    Text("结束运行").font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
                }
            }.disabled(model.active)
            Divider().overlay(BeatStyle.line)
            HStack { Text("每天重复 · 本地时间"); Spacer(); Text(minutesLabel(period.minutes)) }.font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
        }.beatCard()
    }
    private func timeBinding(_ period: DailyPeriod, start: Bool) -> Binding<Int> {
        Binding(get: { start ? period.startMinute : period.endMinute }, set: { value in
            var candidate = period
            if start { candidate.startMinute = value } else { candidate.endMinute = value }
            propose(candidate)
        })
    }
    private func row(_ period: DailyPeriod) -> some View {
        HStack(spacing: 10) {
            Button { selected = period.id } label: {
                Text(clockLabel(period.startMinute) + "  —  " + clockLabel(period.endMinute)).font(.system(size: 11)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).foregroundStyle(selection?.id == period.id ? BeatStyle.blue : BeatStyle.muted)
            Toggle("启用 \(clockLabel(period.startMinute)) 时段", isOn: Binding(get: { period.enabled }, set: { value in var p = period; p.enabled = value; propose(p) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.active)
            Button { model.dailySchedule.periods.removeAll { $0.id == period.id } } label: { Image(systemName: "trash").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(BeatStyle.muted).accessibilityLabel("删除 \(clockLabel(period.startMinute)) 时段").disabled(model.active)
        }.padding(8).background(selection?.id == period.id ? BeatStyle.blue.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private func propose(_ candidate: DailyPeriod) {
        guard !model.active else { return }
        guard candidate.isValid else { error = "结束时间需晚于开始时间；每天可选 00:00–24:00。"; return }
        error = ""
        if let proposal = model.dailySchedule.mergeProposal(for: candidate) { merge = proposal }
        else { model.dailySchedule.apply(candidate); selected = candidate.id }
    }
    private func add() {
        let busy = model.dailySchedule.periods.filter(\.enabled)
        guard let start = (0..<1440).first(where: { m in !busy.contains { $0.startMinute <= m && m < $0.endMinute } }) else { error = "全天已安排运行，可以直接调整已有时段。"; return }
        let next = busy.filter { $0.startMinute > start }.map(\.startMinute).min() ?? 1440
        propose(DailyPeriod(startMinute: start, endMinute: min(start + 60, next)))
    }
    private func updateDrag(_ value: DragGesture.Value) {
        guard !model.active else { return }
        if drag == nil {
            let minute = DialGeometry.minute(value.startLocation)
            if let period = model.dailySchedule.periods.first(where: { $0.startMinute <= minute && minute <= $0.endMinute }) {
                let ds = DialGeometry.distance(value.startLocation, DialGeometry.point(period.startMinute))
                let de = DialGeometry.distance(value.startLocation, DialGeometry.point(period.endMinute))
                let kind: PeriodDrag = min(ds, de) <= 12 ? (ds < de ? .start : .end) : .move
                selected = period.id; drag = ArcDrag(original: period, kind: kind, anchor: minute, candidate: period, moved: false)
            } else {
                let period = DailyPeriod(startMinute: minute, endMinute: minute)
                drag = ArcDrag(original: period, kind: nil, anchor: minute, candidate: period, moved: false)
            }
        }
        guard var current = drag, DialGeometry.distance(value.startLocation, value.location) >= 3 else { return }
        let minute = DialGeometry.minute(value.location)
        if let kind = current.kind { current.candidate = kind.applying(delta: minute - current.anchor, to: current.original) }
        else { current.candidate.startMinute = min(current.anchor, minute); current.candidate.endMinute = max(current.anchor, minute) }
        current.moved = true; drag = current
    }
    private func finishDrag(_ value: DragGesture.Value) {
        updateDrag(value)
        let finished = drag; drag = nil
        if let finished, finished.moved, finished.candidate.isValid { propose(finished.candidate) }
    }
}
