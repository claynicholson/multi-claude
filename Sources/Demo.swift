import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// `MultiClaude --demo-gif out.gif` renders the README demo: a menu bar over a wallpaper, the panel
// opening as a Liquid Glass popover, and a switch from a nearly used-up account to a fresh one.
// Everything is fake demo data; no files, keychain or network are touched.

struct DemoHoverKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var demoHover: String? {
        get { self[DemoHoverKey.self] }
        set { self[DemoHoverKey.self] = newValue }
    }
}

/// Account row frames in the panel's coordinate space (y down), so the demo cursor can aim at them.
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private final class FrameBox { var frames: [String: CGRect] = [:] }

@MainActor private func renderPanel(_ store: Store, hover: String?) async -> (CGImage, [String: CGRect]) {
    let box = FrameBox()
    let host = NSHostingView(rootView: Panel(store: store)
        .environment(\.demoHover, hover)
        .onPreferenceChange(RowFramesKey.self) { box.frames = $0 })
    host.appearance = NSAppearance(named: .aqua)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.appearance = host.appearance
    w.contentView = host
    w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    w.orderFrontRegardless()
    try? await Task.sleep(nanoseconds: 500_000_000)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    w.orderOut(nil)
    return (rep.cgImage!, box.frames)
}

// MARK: - Scene

private let W: CGFloat = 620, H: CGFloat = 540   // scene size in points
private let menuH: CGFloat = 24

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// A soft abstract wallpaper, plus the blurred, saturated copy the glass shows through.
private func wallpapers(scale s: CGFloat) -> (CGImage, CGImage) {
    let pw = Int(W * s), ph = Int(H * s)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let base = CGGradient(colorsSpace: cs, colors: [rgb(0x4B9BE0), rgb(0x2A5BC4), rgb(0x16297A)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W * 0.3, y: H),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    func blob(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: UInt32, _ a: CGFloat) {
        let g = CGGradient(colorsSpace: cs, colors: [rgb(c, a), rgb(c, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x * W, y: y * H), startRadius: 0,
                               endCenter: CGPoint(x: x * W, y: y * H), endRadius: r * W, options: [])
    }
    blob(0.18, 0.30, 0.55, 0x8A6BFF, 0.85)
    blob(0.85, 0.20, 0.50, 0x18D1C9, 0.80)
    blob(0.50, 0.45, 0.36, 0xFF8FB8, 0.45)
    blob(0.95, 0.70, 0.40, 0x3F6FE8, 0.55)
    blob(0.30, 0.95, 0.45, 0x1F2F9E, 0.90)
    let raw = CIImage(cgImage: ctx.makeImage()!)
    let ci = CIContext()
    let smooth = raw.clampedToExtent().applyingGaussianBlur(sigma: 18 * s).cropped(to: raw.extent)
    let glass = smooth.clampedToExtent().applyingGaussianBlur(sigma: 22 * s)
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: 0.04])
        .cropped(to: raw.extent)
    // A fixed, fine grain: it dithers the gradients the same way in every frame, so the GIF needs
    // no per-frame dithering (which shimmers and bloats the file).
    func grained(_ i: CIImage) -> CGImage {
        let img = ci.createCGImage(i, from: raw.extent)!
        let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = c.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<(img.width * img.height) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = Int(seed >> 24) % 11 - 5   // -5…5
            for ch in 0..<3 { px[i * 4 + ch] = UInt8(max(0, min(255, Int(px[i * 4 + ch]) + n))) }
        }
        return c.makeImage()!
    }
    return (grained(smooth), grained(glass))
}

private func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: img.size, flipped: false) { r in
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
}

private func symbol(_ name: String, _ size: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    return tinted(NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!, .white)
}

private struct MenuBar {
    let itemRect: CGRect   // our status item, for the highlight, the cursor and the popover anchor

    static func layout(title: String) -> MenuBar {
        // Laid out right to left like the real menu bar: clock, Control Center, Wi-Fi, battery, us.
        var x = W - 14
        x -= clockWidth + 16
        x -= 18 + 14; x -= 18 + 14; x -= 26 + 14
        let tw = titleString(title).size().width
        let w = 18 + tw + 10
        return MenuBar(itemRect: CGRect(x: x - w, y: H - menuH + 1, width: w, height: menuH - 2))
    }

    static let clock = "Mon Nov 23  9:41 AM"
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static var clockWidth: CGFloat { NSAttributedString(string: clock, attributes: [.font: font]).size().width }
    static func titleString(_ t: String) -> NSAttributedString {
        NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
        ])
    }

    func draw(initial: String, used: Double, open: Bool) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let midY = H - menuH / 2

        if open {
            NSColor.white.withAlphaComponent(0.24).setFill()
            NSBezierPath(roundedRect: itemRect, xRadius: itemRect.height / 2, yRadius: itemRect.height / 2).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        var x = W - 14
        let clock = NSAttributedString(string: MenuBar.clock, attributes: [.font: MenuBar.font, .foregroundColor: NSColor.white])
        x -= clock.size().width
        clock.draw(at: NSPoint(x: x, y: midY - clock.size().height / 2))
        x -= 16
        for (name, w, size) in [("switch.2", 18.0, 14.0), ("wifi", 18.0, 14.5), ("battery.75percent", 26.0, 15.0)] {
            let img = symbol(name, size)
            x -= w
            img.draw(in: NSRect(x: x + (w - img.size.width) / 2, y: midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
            x -= 14
        }
        // Our item: the real status icon (template image, tinted white like the system does) and title.
        let icon = tinted(statusIcon(initial: initial, used: used), .white)
        icon.draw(in: NSRect(x: itemRect.minX + 5, y: midY - 9, width: 18, height: 18))
        let t = MenuBar.titleString(" \(pct(used))%")
        t.draw(at: NSPoint(x: itemRect.minX + 5 + 18, y: midY - t.size().height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Liquid Glass: the blurred wallpaper through a light tint, a soft inner edge, and a specular rim.
private func drawGlass(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, backdrop: CGImage, content: CGImage) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0x000000, 0.30))
    ctx.addPath(path); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(rgb(0xF7F7FA, 0.58)); ctx.fill(rect)
    // Inner edge: light gathering in the glass's thickness.
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(0xFFFFFF, 0.75))
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -20, dy: -20), cornerWidth: radius + 20, cornerHeight: radius + 20, transform: nil))
    ctx.setLineWidth(40); ctx.setStrokeColor(rgb(0xFFFFFF, 0.6)); ctx.strokePath()
    ctx.restoreGState()

    // Specular rim, brightest on the top-left and bottom-right edges.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
    ctx.setLineWidth(1.5); ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 1), rgb(0xFFFFFF, 0.2), rgb(0xFFFFFF, 0.15), rgb(0xFFFFFF, 0.8)] as CFArray,
                         locations: [0, 0.35, 0.65, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(rgb(0x000000, 0.10)); ctx.setLineWidth(0.5); ctx.strokePath()

    ctx.draw(content, in: rect)
}

// MARK: - Timeline

private struct Frame {
    var cursor: CGPoint
    var open: CGFloat = 0          // 0 closed … 1 fully open
    var panel = "A"                // which panel render to show
    var hoverable = true           // pick the hover render from the cursor position
    var account = "P"              // menu bar account
    var delay: Double = 0.04
}

@MainActor func makeDemoGIF(to url: URL) async {
    let s: CGFloat = 1.5   // output pixels per point
    let store = Store(demo: true)
    let now = Date()
    func snap(_ email: String, _ plan: String, _ sUsed: Double, _ sh: Double, _ w: Double, _ wh: Double) -> Snapshot {
        Snapshot(email: email, name: nil, plan: plan,
                 session: Window(used: sUsed, resetsAt: now.addingTimeInterval(sh * 3600)),
                 weekly: Window(used: w, resetsAt: now.addingTimeInterval(wh * 3600)),
                 weeklyOpus: nil, extraEnabled: false, fetchedAt: now)
    }
    store.profiles = [
        Profile(name: "Personal", snapshot: snap("ada@lovelace.dev", "Max 5x", 92, 2.1, 71, 50), signedIn: true),
        Profile(name: "Work", snapshot: snap("ada@analytical.co", "Team", 8, 4.6, 23, 98), signedIn: true),
    ]
    store.openAtLogin = true
    let usedP = 92.0, usedW = 8.0

    // Panel renders: before the switch (no hover / hovering each row), during, and after.
    var renders: [String: CGImage] = [:]
    let (a, frames) = await renderPanel(store, hover: nil)
    renders["A"] = a
    renders["A:Personal"] = await renderPanel(store, hover: "Personal").0
    renders["A:Work"] = await renderPanel(store, hover: "Work").0
    store.switching = "Work"; store.busy = "Switching to Work…"
    renders["S:Work"] = await renderPanel(store, hover: "Work").0
    store.switching = nil; store.busy = nil
    store.current = "Work"; store.cliProfile = "Work"; store.cliEmail = "ada@analytical.co"
    renders["B"] = await renderPanel(store, hover: nil).0
    renders["B:Work"] = await renderPanel(store, hover: "Work").0
    renders["B:Personal"] = await renderPanel(store, hover: "Personal").0

    let rs = CGFloat(a.width) / 300   // the panel render's own pixel scale
    let panelSize = CGSize(width: CGFloat(a.width) / rs, height: CGFloat(a.height) / rs)
    let barP = MenuBar.layout(title: " \(pct(usedP))%"), barW = MenuBar.layout(title: " \(pct(usedW))%")
    func panelRect(_ bar: MenuBar) -> CGRect {
        let x = min(max(8, bar.itemRect.midX - panelSize.width / 2), W - 8 - panelSize.width)
        return CGRect(x: x, y: H - menuH - 5 - panelSize.height, width: panelSize.width, height: panelSize.height)
    }
    let rectP = panelRect(barP)
    func rowCenter(_ name: String) -> CGPoint {
        let f = frames[name]!
        return CGPoint(x: rectP.minX + f.minX + 205, y: rectP.maxY - f.midY)
    }

    // Script.
    var tl: [Frame] = []
    func move(_ from: CGPoint, _ to: CGPoint, _ n: Int, _ f: (inout Frame) -> Void = { _ in }) {
        let d = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let ctrl = CGPoint(x: from.x + d.x / 2 - d.y * 0.15, y: from.y + d.y / 2 + d.x * 0.15)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), e = t * t * (3 - 2 * t)
            let p = CGPoint(x: (1 - e) * (1 - e) * from.x + 2 * (1 - e) * e * ctrl.x + e * e * to.x,
                            y: (1 - e) * (1 - e) * from.y + 2 * (1 - e) * e * ctrl.y + e * e * to.y)
            var fr = tl.last!; fr.cursor = p; fr.delay = 0.04; f(&fr); tl.append(fr)
        }
    }
    func hold(_ secs: Double, _ f: (inout Frame) -> Void = { _ in }) {
        var fr = tl.last!; f(&fr); fr.delay = secs; tl.append(fr)
    }

    let start = CGPoint(x: W * 0.38, y: H * 0.42)
    let icon = CGPoint(x: barP.itemRect.minX + 14, y: barP.itemRect.midY - 1)
    tl.append(Frame(cursor: start, delay: 0.9))
    move(start, icon, 16)
    hold(0.15)
    for i in 1...6 { var fr = tl.last!; fr.open = CGFloat(i) / 6; fr.delay = 0.03; tl.append(fr) }
    hold(1.3)
    move(icon, rowCenter("Work"), 14)
    hold(0.45)
    hold(1.0) { $0.panel = "S"; $0.hoverable = false; $0.cursor.y -= 0 }
    hold(2.4) { $0.panel = "B"; $0.hoverable = true; $0.account = "W" }
    let away = CGPoint(x: W * 0.2, y: H * 0.3)
    move(rowCenter("Work"), away, 14)
    hold(0.15)
    for i in 1...5 { var fr = tl.last!; fr.open = 1 - CGFloat(i) / 5; fr.delay = 0.03; tl.append(fr) }
    hold(1.4)

    // Render.
    let (wall, glass) = wallpapers(scale: s)
    let cursor = NSCursor.arrow
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    // Frames go to a temp folder as PNGs; ImageMagick builds the GIF with one shared, dithered palette
    // (ImageIO's per-frame quantizer bands the gradients badly).
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("multiclaude-demo")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var magickArgs: [String] = []

    for (n, fr) in tl.enumerated() {
        let ctx = CGContext(data: nil, width: Int(W * s), height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        ctx.draw(wall, in: CGRect(x: 0, y: 0, width: W, height: H))
        let onW = fr.account == "W"
        let bar = onW ? barW : barP
        bar.draw(initial: onW ? "W" : "P", used: onW ? usedW : usedP, open: fr.open > 0)

        if fr.open > 0 {
            let rect = panelRect(barP)
            var key = fr.panel
            if fr.hoverable {
                let px = fr.cursor.x - rect.minX, py = rect.maxY - fr.cursor.y
                if let hit = frames.first(where: { $0.value.contains(CGPoint(x: px, y: py)) })?.key,
                   renders["\(fr.panel):\(hit)"] != nil { key = "\(fr.panel):\(hit)" }
            } else if fr.panel == "S" { key = "S:Work" }
            let e = 1 - pow(1 - fr.open, 3)
            ctx.saveGState()
            ctx.setAlpha(e)
            let k = 0.94 + 0.06 * e
            ctx.translateBy(x: rect.midX, y: rect.maxY)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -rect.midX, y: -rect.maxY)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawGlass(ctx, rect, radius: 14, backdrop: glass, content: renders[key]!)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        let img = cursor.image, hot = cursor.hotSpot
        img.draw(in: NSRect(x: fr.cursor.x - hot.x, y: fr.cursor.y - (img.size.height - hot.y),
                            width: img.size.width, height: img.size.height))

        NSGraphicsContext.restoreGraphicsState()
        let file = dir.appendingPathComponent(String(format: "%03d.png", n))
        let d = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        magickArgs += ["-delay", "\(Int((fr.delay * 100).rounded()))", file.path]
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // One palette for the whole GIF, taken from the closed, open and switched states.
    let palette = dir.appendingPathComponent("palette.png").path
    func frame(_ i: Int) -> String { dir.appendingPathComponent(String(format: "%03d.png", i)).path }
    let openFrame = tl.firstIndex { $0.open == 1 }!, switched = tl.firstIndex { $0.account == "W" }!
    p.arguments = ["magick", frame(0), frame(openFrame), frame(switched), "-append",
                   "+dither", "-colors", "256", "-unique-colors", palette]
    try? p.run(); p.waitUntilExit()
    let q = Process()
    q.executableURL = p.executableURL
    q.arguments = ["magick", "-loop", "0"] + magickArgs + [
        "-layers", "OptimizeFrame", "+dither", "-remap", palette, url.path,
    ]
    try? q.run(); q.waitUntilExit()
}
