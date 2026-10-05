import AppKit

enum StatusItemIcon {
    enum State { case idle, running, attention }

    static func make(_ state: State) -> NSImage {
        let background: NSColor
        switch state {
        case .idle: background = NSColor(srgbRed: 0.16, green: 0.44, blue: 0.94, alpha: 1)
        case .running: background = NSColor(srgbRed: 0.07, green: 0.58, blue: 0.37, alpha: 1)
        case .attention: background = NSColor(srgbRed: 0.72, green: 0.38, blue: 0.04, alpha: 1)
        }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 20, height: 20), xRadius: 5, yRadius: 5)
            background.setFill()
            tile.fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            tile.lineWidth = 0.6
            tile.stroke()

            let pulse = NSBezierPath()
            pulse.move(to: NSPoint(x: 4, y: 10.5))
            for point in [NSPoint(x: 7, y: 10.5), NSPoint(x: 9, y: 16),
                          NSPoint(x: 12, y: 6), NSPoint(x: 14, y: 11.5), NSPoint(x: 18, y: 11.5)] {
                pulse.line(to: point)
            }
            pulse.lineWidth = 1.7
            pulse.lineCapStyle = .round
            pulse.lineJoinStyle = .round
            NSColor.white.setStroke()
            pulse.stroke()
            return true
        }
        // Keep the opaque badge and white pulse in both menu-bar appearances.
        image.isTemplate = false
        image.accessibilityDescription = "MacBeat"
        return image
    }
}
