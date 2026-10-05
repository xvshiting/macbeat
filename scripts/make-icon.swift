import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let rect = NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s*0.2, yRadius: s*0.2)
    NSGradient(starting: NSColor(red:0.32,green:0.64,blue:1,alpha:1), ending: NSColor(red:0.08,green:0.31,blue:0.82,alpha:1))!.draw(in: path, angle: -70)
    let pulse = NSBezierPath()
    let points: [(CGFloat,CGFloat)] = [(0.19,0.49),(0.34,0.49),(0.43,0.70),(0.55,0.29),(0.65,0.51),(0.81,0.51)]
    for (i,p) in points.enumerated() {
        let point = NSPoint(x:p.0*s,y:p.1*s)
        if i == 0 { pulse.move(to:point) } else { pulse.line(to:point) }
    }
    pulse.lineWidth = s * 0.043; pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round
    NSColor.white.setStroke(); pulse.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to:root.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to:root.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
