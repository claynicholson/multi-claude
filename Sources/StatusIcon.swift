import AppKit

/// The menu bar icon: the live account's initial inside a ring that fills as its 5-hour limit is
/// used. Drawn as a template image so macOS tints it for light/dark menu bars and the highlight.
func statusIcon(initial: String, used: Double?) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        let line: CGFloat = 1.75
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5

        // Track: a faint full circle so the ring reads as a gauge even when nearly empty.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor.black.withAlphaComponent(0.28).setStroke()
        track.stroke()

        // Progress: clockwise from 12 o'clock.
        if let u = used, u > 0 {
            let f = CGFloat(min(u, 100) / 100)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }

        // Initial, optically centered.
        let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let text = NSAttributedString(string: initial, attributes: [.font: font, .foregroundColor: NSColor.black])
        let ts = text.size()
        text.draw(at: NSPoint(x: center.x - ts.width / 2, y: center.y - ts.height / 2 + 0.25))
        return true
    }
    img.isTemplate = true
    return img
}
