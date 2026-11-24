// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift            (run from the repo root)
//        swift tools/make-icon.swift preview.png  (also write the 1024px PNG there)
//
// The design echoes the menu bar icon: a usage ring, here in two arcs for two accounts,
// around a sparkle, on a dark squircle laid out on Apple's 1024px icon grid.

import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func drawIcon(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)   // draw in 1024-point grid coordinates
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Body: 824pt squircle with a soft drop shadow, per the macOS icon grid.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    rgb(0x1E1D1B).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: warm charcoal, lit from the top.
    NSGradient(colors: [rgb(0x3A3733), rgb(0x24221F), rgb(0x191816)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: squircle, angle: -90)

    let c = NSPoint(x: 512, y: 512)
    let r: CGFloat = 268, w: CGFloat = 64

    // Ring track.
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = w
    rgb(0xFFFFFF, 0.07).setStroke()
    track.stroke()

    // Two arcs, clockwise from 12 o'clock: the live account in terracotta, the other in cream.
    func arc(from: CGFloat, to: CGFloat, colors: [NSColor]) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: 90 - from, endAngle: 90 - to, clockwise: true)
        p.lineWidth = w
        p.lineCapStyle = .round
        let outline = NSBezierPath(cgPath: p.cgPath.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
        NSGradient(colors: colors)!.draw(in: outline, angle: -90)
    }
    let gap: CGFloat = 26   // degrees between arcs, wide enough to clear the round caps
    arc(from: gap / 2, to: 228 - gap / 2, colors: [rgb(0xF0A07E), rgb(0xD97757), rgb(0xB85A3B)])
    arc(from: 228 + gap / 2, to: 360 - gap / 2, colors: [rgb(0xF4EEE4), rgb(0xD9D0C3)])

    // Center: a four-point sparkle with concave sides.
    let s: CGFloat = 138, k: CGFloat = 0.27
    let star = NSBezierPath()
    star.move(to: NSPoint(x: c.x, y: c.y + s))
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2
        let tip = NSPoint(x: c.x + s * sin(a + .pi / 2), y: c.y + s * cos(a + .pi / 2))
        let ctrl = NSPoint(x: c.x + s * k * sin(a + .pi / 4), y: c.y + s * k * cos(a + .pi / 4))
        star.curve(to: tip, controlPoint1: ctrl, controlPoint2: ctrl)
    }
    star.close()
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE9E2D7)])!.draw(in: star, angle: -90)

    // Specular edge: a thin light rim along the top, fading out toward the bottom.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    rim.lineWidth = 3
    let rimOutline = NSBezierPath(cgPath: rim.cgPath.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10))
    NSGradient(colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.0)], atLocations: [0, 0.5], colorSpace: .sRGB)!
        .draw(in: rimOutline, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(drawIcon(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(drawIcon(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 1 {
    try! png(drawIcon(1024)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
