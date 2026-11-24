import AppKit
import SwiftUI

// The menu bar panel, modeled on the system's own menu bar extras (Wi-Fi, Battery, Bluetooth):
// plain text rows, section headers, the system accent color, and no decoration that isn't information.

/// Percent of a limit used, as Claude's own usage panel shows it.
func used(_ w: Window?) -> Double? { w.map { min(100, max(0, $0.used)) } }

/// Bar color: the system accent, then orange and red as the limit gets close.
func meterColor(_ used: Double?) -> Color {
    guard let u = used else { return .secondary }
    return u < 75 ? .accentColor : u < 90 ? .orange : .red
}

/// "Resets at 8:40 PM" today, otherwise "Resets Mon 4:00 AM", matching Claude's wording.
func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    return Calendar.current.isDateInToday(d)
        ? "Resets at \(d.formatted(date: .omitted, time: .shortened))"
        : "Resets \(weekdayTime(d))"
}

func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
}

// MARK: - Building blocks

/// A full-width row that highlights on hover, like a menu item.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : hover && enabled ? 0.09 : 0))
                )
                .foregroundStyle(enabled ? .primary : .tertiary)
                .onHover { hover = $0 }
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The round icon used for items you can connect to in the Wi-Fi and Bluetooth menus:
/// filled with the accent color when it's the one in use.
struct ItemIcon: View {
    let symbol: String
    let on: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.7))
            .frame(width: 26, height: 26)
            .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

struct Meter: View {
    let used: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(meterColor(used))
                    .frame(width: max(used ?? 0 > 0 ? 4 : 0, g.size.width * CGFloat((used ?? 0) / 100)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Sections

struct UsageSection: View {
    @ObservedObject var store: Store
    var body: some View {
        let p = store.active, s = p?.snapshot
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.current).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = s?.plan { Text(plan).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let s, p?.signedIn == true, s.session != nil || s.weekly != nil {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    VStack(spacing: 10) {
                        limit("5-hour limit", s.session)
                        limit("Weekly limit", s.weekly)
                        if let opus = s.weeklyOpus { limit("Weekly Opus limit", opus) }
                    }
                }
            } else {
                Text(p?.error ?? (p?.signedIn == false ? "Sign in to Claude to see usage." : "Loading…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let e = p?.error, s != nil {
                Text(e).font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }

    func limit(_ title: String, _ w: Window?) -> some View {
        let u = used(w)
        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(u.map { "\(pct($0))%" } ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Meter(used: u)
            Text(resetText(w?.resetsAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountRow: View {
    let p: Profile
    let active: Bool
    let switching: Bool
    let onSwitch: () -> Void

    var body: some View {
        Button(action: { if !active { onSwitch() } }) {
            HStack(spacing: 9) {
                ItemIcon(symbol: "person.fill", on: active)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.name)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(p.error != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if switching {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if !active, let u = used(p.snapshot?.session) {
                    Text("\(pct(u))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .help(active ? "\(p.name) is in use" : "Switch Claude to \(p.name)")
        .contextMenu {
            Button("Switch to \(p.name)", action: onSwitch).disabled(active)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profileDir(p.name)]) }
        }
    }

    var detail: String {
        if let e = p.error { return e }
        if !p.signedIn { return "Not signed in" }
        return p.snapshot?.email ?? "—"
    }
}

struct AddAccountRow: View {
    let onAdd: (String) -> Void
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Account name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onAdd(name); cancel() }
                .onExitCommand(perform: cancel)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .onAppear { focused = true }
        } else {
            Button("Add Account…") { editing = true }.buttonStyle(MenuRowStyle())
        }
    }

    func cancel() { name = ""; editing = false }
}

struct TerminalRow: View {
    @ObservedObject var store: Store
    var body: some View {
        let inSync = store.cliProfile == store.current
        HStack(spacing: 9) {
            ItemIcon(symbol: "terminal", on: false)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Code CLI").font(.system(size: 13))
                Text(store.cliEmail == nil ? "Not logged in" : "Using \(store.cliProfile ?? "another account")")
                    .font(.system(size: 11))
                    .foregroundStyle(inSync ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
            Spacer(minLength: 8)
            if !inSync {
                Button("Switch") { Task { await store.moveTerminal(to: store.current) } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
                    .help("Log the claude CLI in to \(store.current)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .help(store.cliEmail ?? "Run claude /login in a terminal")
    }
}

struct Shortcut: View {
    let keys: String
    var body: some View { Text(keys).font(.system(size: 13)).foregroundStyle(.tertiary) }
}

// MARK: - Panel

struct Panel: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            UsageSection(store: store)

            if let b = store.banner {
                Button { store.banner = nil } label: {
                    Text(b).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Click to dismiss")
                .padding(.horizontal, 8).padding(.top, 10)
            }

            separator
            SectionHeader("Accounts")
            ForEach(store.profiles) { p in
                AccountRow(p: p, active: p.name == store.current, switching: store.switching == p.name) {
                    Task { await store.switchTo(p.name) }
                }
                .disabled(store.busy != nil && store.switching != p.name)
            }
            AddAccountRow { store.addProfile($0) }

            separator
            TerminalRow(store: store)

            separator
            Button("Copy Code Threads…") { CopyWindow.show(store) }.buttonStyle(MenuRowStyle())
            Button("Show Profiles in Finder") { NSWorkspace.shared.activateFileViewerSelecting([parkDir]) }
                .buttonStyle(MenuRowStyle())
            HStack {
                Text("Open at Login").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: Binding(get: { store.openAtLogin }, set: { _ in store.toggleOpenAtLogin() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)

            separator
            Button { Task { await store.refresh() } } label: {
                HStack {
                    Text(store.busy ?? "Refresh")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(store.busy == nil ? "Updated \(ago(store.lastRefresh))" : "")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(MenuRowStyle())
            .keyboardShortcut("r")
            .disabled(store.busy != nil)
            Button { NSApp.terminate(nil) } label: {
                HStack { Text("Quit Multi Claude"); Spacer(); Shortcut(keys: "⌘Q") }
            }
            .buttonStyle(MenuRowStyle())
            .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 300)
    }

    var separator: some View { Divider().padding(.horizontal, 8).padding(.vertical, 6) }
}
