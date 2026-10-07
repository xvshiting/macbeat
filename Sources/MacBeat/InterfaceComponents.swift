import SwiftUI
import MacBeatCore

enum BeatStyle {
    static let blue = Color(red: 0.21, green: 0.47, blue: 0.95)
    static let ink = Color(red: 0.15, green: 0.21, blue: 0.30)
    static let muted = Color(red: 0.49, green: 0.57, blue: 0.68)
    static let line = Color(red: 0.88, green: 0.92, blue: 0.97)
    static let surface = Color(red: 0.97, green: 0.98, blue: 1)
}
extension View {
    func beatCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(BeatStyle.line, lineWidth: 0.7))
    }
}
func clockLabel(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
func minutesLabel(_ minute: Int) -> String {
    [minute / 60 > 0 ? "\(minute / 60) 小时" : "", minute % 60 > 0 ? "\(minute % 60) 分钟" : ""].filter { !$0.isEmpty }.joined(separator: " ")
}
struct BeatPrimary: View {
    var title: String
    var symbol = "power"
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 12).foregroundStyle(.white)
            .background(BeatStyle.blue, in: RoundedRectangle(cornerRadius: 11)) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}
struct TimeDigits: View {
    @Binding var value: Int
    var maximum = 1439
    var units = false
    var size: CGFloat = 30
    var label = "时间"
    private var hours: Binding<Int> { Binding(get: { value / 60 }, set: { value = min(maximum, max(0, $0) * 60 + ( $0 == 24 ? 0 : value % 60)) }) }
    private var minutes: Binding<Int> { Binding(get: { value % 60 }, set: { value = min(maximum, value / 60 * 60 + $0) }) }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            DigitField(value: hours, maximum: maximum / 60, size: size, label: label + "小时", padded: !units)
            Text(units ? "时" : ":").font(.system(size: units ? 10 : size * 0.7)).foregroundStyle(BeatStyle.muted)
            DigitField(value: minutes, maximum: 59, size: size, label: label + "分钟", padded: true)
            if units { Text("分").font(.system(size: 10)).foregroundStyle(BeatStyle.muted) }
        }.fixedSize()
    }
}
private struct DigitField: View {
    @Binding var value: Int
    var maximum: Int
    var size: CGFloat
    var label: String
    var padded: Bool
    @State private var text = ""
    @FocusState private var focused: Bool
    private var formatted: String { padded ? String(format: "%02d", value) : String(value) }
    var body: some View {
        TextField(label, text: $text).textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(.system(size: size, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(BeatStyle.ink).frame(width: size * 1.35)
            .background(focused ? BeatStyle.blue.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .focused($focused).accessibilityLabel(label)
            .onAppear { text = formatted }
            .onChange(of: value) { updated in text = padded ? String(format: "%02d", updated) : String(updated) }
            .onChange(of: focused) { if !$0 { commit() } }
            .onSubmit { commit(); focused = false }
    }
    private func commit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)), (0...maximum).contains(number) { value = number }
        text = formatted
    }
}
struct DialArc: Shape {
    var start: Double = 0
    var end: Double = 1440
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                 startAngle: .degrees(135 + start / 1440 * 270), endAngle: .degrees(135 + end / 1440 * 270), clockwise: false)
        return p
    }
}
enum DialGeometry {
    static let center = CGPoint(x: 126, y: 120)
    static func point(_ minute: Int, radius: Double = 88) -> CGPoint {
        let a = (135 + Double(minute) / 1440 * 270) * .pi / 180
        return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }
    static func minute(_ point: CGPoint, step: Int = 15) -> Int {
        var angle = (atan2(point.y - center.y, point.x - center.x) * 180 / .pi - 135 + 360).truncatingRemainder(dividingBy: 360)
        if angle > 270 { angle = angle < 315 ? 270 : 0 }
        return max(0, min(1440, Int((angle / 270 * 1440 / Double(step)).rounded()) * step))
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
}
struct DialFace: View {
    var body: some View {
        ZStack {
            DialArc().stroke(BeatStyle.line, style: StrokeStyle(lineWidth: 7, lineCap: .round)).frame(width: 176, height: 176).position(DialGeometry.center)
            ForEach(0..<49, id: \.self) { i in
                Path { p in p.move(to: DialGeometry.point(i * 30, radius: 100)); p.addLine(to: DialGeometry.point(i * 30, radius: i % 4 == 0 ? 106 : 103)) }
                    .stroke(BeatStyle.line, lineWidth: i % 4 == 0 ? 1.5 : 1)
            }
            ForEach([0,360,720,1080,1440], id: \.self) { m in
                Text(String(format: "%02d", m / 60)).font(.system(size: 9)).foregroundStyle(BeatStyle.muted.opacity(0.8)).position(DialGeometry.point(m, radius: 117))
            }
        }.frame(width: 252, height: 240).accessibilityHidden(true)
    }
}
struct DurationDial: View {
    @Binding var seconds: Double
    private var minutes: Binding<Int> { Binding(get: { Int(seconds / 60) }, set: { seconds = Double(max(1, min(1440, $0))) * 60 }) }
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                HStack { Label("拨一点时间", systemImage: "clock"); Spacer(); Text("24 小时 · 拖动调节") }.font(.system(size: 9)).foregroundStyle(BeatStyle.muted)
                ZStack {
                    DialFace()
                    DialArc(end: Double(minutes.wrappedValue)).stroke(BeatStyle.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round)).frame(width: 176, height: 176).position(DialGeometry.center)
                    Circle().fill(.white).overlay(Circle().stroke(BeatStyle.blue, lineWidth: 3)).frame(width: 11, height: 11).position(DialGeometry.point(minutes.wrappedValue))
                    Color.clear.contentShape(DialRingHitArea()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        minutes.wrappedValue = max(1, DialGeometry.minute(value.location, step: 5))
                    }).accessibilityElement().accessibilityLabel("保持运行时长").accessibilityValue(minutesLabel(minutes.wrappedValue))
                        .accessibilityAdjustableAction { direction in minutes.wrappedValue += direction == .increment ? 1 : -1 }
                    VStack(spacing: 5) {
                        Text("保持运行").font(.system(size: 10)).foregroundStyle(BeatStyle.muted)
                        TimeDigits(value: minutes, maximum: 1440, units: true, size: 36, label: "运行")
                    }.position(x: 126, y: 123)
                    Text("点击数字，精确到分钟").font(.system(size: 9)).foregroundStyle(BeatStyle.muted).position(x: 126, y: 228)
                }.frame(width: 252, height: 240)
                Divider().overlay(BeatStyle.line).padding(.vertical, 9)
                HStack {
                    Button { minutes.wrappedValue -= 1 } label: { Image(systemName: "minus") }.accessibilityLabel("减少一分钟")
                    Spacer(); Text("微调 · 每次 1 分钟").font(.system(size: 9)).foregroundStyle(BeatStyle.muted); Spacer()
                    Button { minutes.wrappedValue += 1 } label: { Image(systemName: "plus") }.accessibilityLabel("增加一分钟")
                }.buttonStyle(.bordered).controlSize(.mini)
            }.beatCard(padding: 13)
            HStack(spacing: 7) {
                preset("专注 25 分", 25); preset("小憩 90 分", 90); preset("整晚 8 时", 480)
            }
        }
    }
    private func preset(_ text: String, _ value: Int) -> some View {
        Button(text) { minutes.wrappedValue = value }.font(.system(size: 10)).buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 6).background(BeatStyle.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(BeatStyle.muted)
    }
}
struct DialRingHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.addArc(center: DialGeometry.center, radius: 100, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
            p.addArc(center: DialGeometry.center, radius: 75, startAngle: .degrees(405), endAngle: .degrees(135), clockwise: true)
            p.closeSubpath()
        }
    }
}
