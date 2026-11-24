import AppKit
import SwiftUI

// A standard document-style window for copying Claude Code threads from one account to another.

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}

struct CopyThreadsView: View {
    @ObservedObject var store: Store
    @State private var from = ""
    @State private var to = ""
    @State private var threads: [ThreadInfo] = []
    @State private var picked = Set<String>()
    @State private var query = ""
    @State private var showArchived = false
    @State private var status: (text: String, ok: Bool)?

    var names: [String] { store.profiles.map(\.name) }
    var visible: [ThreadInfo] {
        threads.filter {
            (showArchived || !$0.archived)
                && (query.isEmpty || "\($0.title) \($0.cwd)".localizedCaseInsensitiveContains(query))
        }
    }
    var allPicked: Bool { !visible.isEmpty && visible.allSatisfy { picked.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            table
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            to = store.current
            from = names.filter { $0 != to }.max { listThreads($0).count < listThreads($1).count } ?? to
            load()
        }
        .onChange(of: from) { _ in load() }
    }

    var topBar: some View {
        HStack(spacing: 10) {
            accountPicker("From", $from)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            accountPicker("To", $to)
            Spacer(minLength: 12)
            SearchField(text: $query, prompt: "Search threads")
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 240)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    var table: some View {
        Table(visible) {
            TableColumn("") { t in
                Toggle("", isOn: Binding(
                    get: { picked.contains(t.id) },
                    set: { on in if on { picked.insert(t.id) } else { picked.remove(t.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            .width(20)
            TableColumn("Thread") { t in
                HStack(spacing: 6) {
                    if t.archived {
                        Image(systemName: "archivebox").foregroundStyle(.secondary).help("Archived")
                    }
                    Text(t.title).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Project") { t in
                Text(t.project).foregroundStyle(.secondary).lineLimit(1)
                    .help(t.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            .width(min: 80, ideal: 140)
            TableColumn("Last Active") { t in
                Text(t.lastActivity, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if visible.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No Threads" : "No Results").font(.system(size: 15, weight: .semibold))
                    Text(query.isEmpty ? "\(from) has no Claude Code threads to copy." : "Nothing matches “\(query)”.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    var bottomBar: some View {
        HStack(spacing: 12) {
            Button(allPicked ? "Deselect All" : "Select All") {
                if allPicked { visible.forEach { picked.remove($0.id) } } else { visible.forEach { picked.insert($0.id) } }
            }
            .disabled(visible.isEmpty)
            Toggle("Show archived", isOn: $showArchived).toggleStyle(.checkbox)

            Spacer(minLength: 12)

            Group {
                if let b = store.busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(b) }
                } else if let s = status {
                    Label(s.text, systemImage: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.ok ? Color.green : Color.orange)
                } else if to == store.current && store.claudeRunning && !picked.isEmpty {
                    Text("Claude will restart to load them.")
                } else {
                    Text("\(picked.count) of \(visible.count) selected").monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Button(picked.count == 1 ? "Copy Thread" : picked.isEmpty ? "Copy Threads" : "Copy \(picked.count) Threads") {
                let sel = threads.filter { picked.contains($0.id) }
                Task {
                    let text = await store.copyThreads(sel, to: to)
                    let ok = text.hasPrefix("Copied")
                    status = (text, ok)
                    if ok { picked.removeAll() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty || from == to || store.busy != nil)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func load() { threads = listThreads(from); picked.removeAll(); status = nil }

    func accountPicker(_ label: String, _ sel: Binding<String>) -> some View {
        Picker(label, selection: sel) {
            ForEach(names, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

enum CopyWindow {
    static var window: NSWindow?

    @MainActor static func show(_ store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Copy Threads"
            w.subtitle = "Claude Code"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 640, height: 460)
            w.contentViewController = NSHostingController(rootView: CopyThreadsView(store: store))
            w.setFrameAutosaveName("CopyThreadsWindow")
            if !w.setFrameUsingName("CopyThreadsWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
