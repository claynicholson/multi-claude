import AppKit
import SwiftUI
import ServiceManagement

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var store: Store!

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            store = Store()
            store.onChange = { [weak self] in self?.updateTitle() }
            popover.behavior = .transient
            popover.animates = true
            let host = NSHostingController(rootView: Panel(store: store))
            // Let the popover track the SwiftUI size; otherwise it's positioned at its initial
            // (too small) size and the grown content spills up past the menu bar.
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            item.button?.target = self
            item.button?.action = #selector(toggle)
            updateTitle()
        }
    }

    @MainActor func updateTitle() {
        guard let b = item.button else { return }
        let sl = used(store.active?.snapshot?.session)
        let initial = String(initials(store.current).prefix(1))
        // The icon already names the account; the title is just the number.
        b.attributedTitle = NSAttributedString(string: sl.map { " \(pct($0))%" } ?? "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .baselineOffset: 0.5,
        ])
        let img = statusIcon(initial: initial, used: sl)
        img.accessibilityDescription = "Multi Claude, \(store.current)"
        b.image = img
        b.imagePosition = .imageLeading
        b.toolTip = sl.map { "Claude · \(store.current) · \(pct($0))% of 5-hour limit used" } ?? "Claude · \(store.current)"
    }

    @objc func toggle() {
        MainActor.assumeIsolated {
            if popover.isShown { popover.performClose(nil); return }
            guard let b = item.button else { return }
            Task { await store.refresh() }
            if let v = popover.contentViewController?.view {
                v.layoutSubtreeIfNeeded()
                popover.contentSize = v.fittingSize
            }
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Renders a view to a PNG through AppKit, so real controls (switches, tables, pickers) show up.
@MainActor func snapshot<V: View>(_ view: V, to url: URL, dark: Bool) async {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.appearance = appearance
    w.contentView = host
    w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    w.orderFrontRegardless()
    try? await Task.sleep(nanoseconds: 600_000_000)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

let app = NSApplication.shared
let args = CommandLine.arguments

// `MultiClaude --snapshot out.png [--demo] [--copy] [--dark]` renders the panel to a PNG and exits.
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let out = URL(fileURLWithPath: args[i + 1])
    MainActor.assumeIsolated {
        let demo = args.contains("--demo")
        let store = demo ? Store(demo: true) : Store()
        Task { @MainActor in
            if !demo { await store.refresh() }
            if args.contains("--copy") {
                await snapshot(CopyThreadsView(store: store).frame(width: 720, height: 480), to: out, dark: args.contains("--dark"))
            } else {
                await snapshot(Panel(store: store).padding(.vertical, 4), to: out, dark: args.contains("--dark"))
            }
            exit(0)
        }
    }
    app.setActivationPolicy(.accessory)
    app.run()
}
// `MultiClaude --register-login` adds the app to Login Items and exits (used by `build.sh install`).
if args.contains("--register-login") {
    do { try SMAppService.mainApp.register(); exit(0) } catch { print("register failed: \(error)"); exit(1) }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
