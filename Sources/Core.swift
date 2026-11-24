import AppKit
import CommonCrypto
import ServiceManagement

// Multi Claude — menu bar app that swaps Claude Desktop's data folder between accounts
// and shows live plan usage for each one.
//
// Active profile lives at ~/Library/Application Support/Claude (a real dir).
// Inactive profiles are parked at ~/Library/Application Support/Claude-Profiles/<name>.
// Switching = quit Claude, rename dirs (instant, same volume), relaunch.
// Usage comes from each profile's own OAuth token (decrypted from its config.json).

let bundleID = "com.anthropic.claudefordesktop"
let fm = FileManager.default
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let liveDir = support.appendingPathComponent("Claude")
let parkDir = support.appendingPathComponent("Claude-Profiles")
let currentFile = parkDir.appendingPathComponent(".current")
let cacheDir = parkDir.appendingPathComponent(".cache")
let defaultProfiles = ["Personal", "Business"]

// MARK: - Data

struct Window: Codable { var used: Double; var resetsAt: Date? }

struct Snapshot: Codable {
    var email: String?
    var name: String?
    var plan: String?
    var session: Window?
    var weekly: Window?
    var weeklyOpus: Window?
    var extraEnabled: Bool?
    var fetchedAt: Date
}

struct Profile: Identifiable {
    var id: String { name }
    let name: String
    var snapshot: Snapshot?
    var signedIn: Bool
    var error: String?
    var live: Bool { error == nil && snapshot.map { Date().timeIntervalSince($0.fetchedAt) < 600 } == true }
}

func currentProfile() -> String {
    (try? String(contentsOf: currentFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultProfiles[0]
}

func profileDir(_ name: String) -> URL {
    name == currentProfile() ? liveDir : parkDir.appendingPathComponent(name)
}

func allProfileNames() -> [String] {
    let cur = currentProfile()
    let parked = ((try? fm.contentsOfDirectory(atPath: parkDir.path)) ?? [])
        .filter { !$0.hasPrefix(".") }
    var names = [cur] + parked.filter { $0 != cur }
    // stable order: defaults first, then alphabetical
    names.sort { a, b in
        let ia = defaultProfiles.firstIndex(of: a) ?? 99, ib = defaultProfiles.firstIndex(of: b) ?? 99
        return ia != ib ? ia < ib : a < b
    }
    return names
}

// MARK: - Token decryption (Electron safeStorage: "v10" + AES-128-CBC, PBKDF2-SHA1 "saltysalt")

var cachedSafeKey: Data?

func safeStorageKey() throws -> Data {
    if let k = cachedSafeKey { return k }
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "Claude Safe Storage",
                            kSecReturnData as String: true]
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    guard st == errSecSuccess, let pw = out as? Data else {
        throw err("Keychain access denied (\(st)). Allow access to \"Claude Safe Storage\".")
    }
    var key = Data(count: 16)
    let salt = Array("saltysalt".utf8)
    let rc = key.withUnsafeMutableBytes { kp in
        pw.withUnsafeBytes { pp in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp.baseAddress!.assumingMemoryBound(to: Int8.self), pw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 kp.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
        }
    }
    guard rc == kCCSuccess else { throw err("Key derivation failed") }
    cachedSafeKey = key
    return key
}

func decrypt(_ b64: String) throws -> Data {
    guard let raw = Data(base64Encoded: b64), raw.prefix(3) == Data("v10".utf8) else { throw err("Unknown token format") }
    let body = raw.dropFirst(3)
    let key = try safeStorageKey()
    let iv = [UInt8](repeating: 0x20, count: 16)
    var out = Data(count: body.count + 16)
    var moved = 0
    let outCap = out.count
    let rc = out.withUnsafeMutableBytes { op in
        body.withUnsafeBytes { bp in
            key.withUnsafeBytes { kp in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kp.baseAddress, 16, iv, bp.baseAddress, body.count, op.baseAddress, outCap, &moved)
            }
        }
    }
    guard rc == kCCSuccess else { throw err("Token decrypt failed") }
    return out.prefix(moved)
}

func err(_ s: String) -> NSError { NSError(domain: "switcher", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

/// Best non-expired token with user:profile scope from a profile's config.json, or nil if signed out.
func token(for dir: URL) throws -> String? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
          let cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let enc = cfg["oauth:tokenCacheV2"] as? String else { return nil }
    let dict = try JSONSerialization.jsonObject(with: try decrypt(enc)) as? [String: [String: Any]] ?? [:]
    let now = Date().timeIntervalSince1970 * 1000
    return dict.filter { $0.key.contains("user:profile") }
        .compactMap { _, v -> (String, Double)? in
            guard let t = v["token"] as? String, let e = v["expiresAt"] as? Double, e > now else { return nil }
            return (t, e)
        }
        .max { $0.1 < $1.1 }?.0
}

func parseDate(_ s: Any?) -> Date? {
    guard var s = s as? String else { return nil }
    if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
        s.removeSubrange(dot..<tz)
    }
    return ISO8601DateFormatter().date(from: s)
}

func window(_ o: Any?) -> Window? {
    guard let d = o as? [String: Any], let u = d["utilization"] as? Double else { return nil }
    return Window(used: u, resetsAt: parseDate(d["resets_at"]))
}

func getJSON(_ path: String, _ tok: String) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
    r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    r.setValue("multi-claude/2.0", forHTTPHeaderField: "User-Agent")
    r.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw err(code == 401 ? "Session expired — switch to it to re-auth" : "API error \(code)") }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func planName(_ org: [String: Any]?) -> String? {
    let tier = (org?["rate_limit_tier"] as? String ?? "").lowercased()
    let type = (org?["organization_type"] as? String ?? "").lowercased()
    if tier.contains("20x") { return "Max 20x" }
    if tier.contains("5x") { return "Max 5x" }
    if type.contains("enterprise") { return "Enterprise" }
    if type.contains("team") { return "Team" }
    if type.contains("max") { return "Max" }
    if type.contains("pro") { return "Pro" }
    return type.isEmpty ? nil : type.capitalized
}

func fetchSnapshot(_ tok: String) async throws -> Snapshot {
    async let u = getJSON("usage", tok)
    async let p = getJSON("profile", tok)
    let (usage, prof) = try await (u, p)
    let acct = prof["account"] as? [String: Any]
    let org = prof["organization"] as? [String: Any]
    return Snapshot(email: acct?["email"] as? String,
                    name: org?["name"] as? String,
                    plan: planName(org),
                    session: window(usage["five_hour"]),
                    weekly: window(usage["seven_day"]),
                    weeklyOpus: window(usage["seven_day_opus"]),
                    extraEnabled: (usage["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool,
                    fetchedAt: Date())
}

func loadCache(_ name: String) -> Snapshot? {
    guard let d = try? Data(contentsOf: cacheDir.appendingPathComponent("\(name).json")) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(Snapshot.self, from: d)
}

func saveCache(_ name: String, _ s: Snapshot) {
    try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try? enc.encode(s).write(to: cacheDir.appendingPathComponent("\(name).json"))
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var current = currentProfile()
    @Published var claudeRunning = false
    @Published var busy: String?
    @Published var switching: String?      // profile a switch is in progress to
    @Published var lastRefresh: Date?
    @Published var banner: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var cliProfile: String?     // profile the terminal `claude` is logged in as
    @Published var cliEmail: String?
    var onChange: (() -> Void)?

    /// Fake accounts for README screenshots — touches no files, keychain or network.
    init(demo: Bool) {
        let now = Date()
        func snap(_ email: String, _ plan: String, _ s: Double, _ sh: Double, _ w: Double, _ wh: Double) -> Snapshot {
            Snapshot(email: email, name: nil, plan: plan,
                     session: Window(used: s, resetsAt: now.addingTimeInterval(sh * 3600)),
                     weekly: Window(used: w, resetsAt: now.addingTimeInterval(wh * 3600)),
                     weeklyOpus: nil, extraEnabled: false, fetchedAt: now)
        }
        current = "Personal"
        cliProfile = "Personal"
        cliEmail = "ada@lovelace.dev"
        claudeRunning = true
        lastRefresh = now
        profiles = [
            Profile(name: "Personal", snapshot: snap("ada@lovelace.dev", "Max 5x", 28, 3.3, 61, 50), signedIn: true),
            Profile(name: "Business", snapshot: snap("ada@analytical.co", "Team", 86, 1.2, 74, 98), signedIn: true),
            Profile(name: "Side Project", snapshot: nil, signedIn: false),
        ]
    }

    func toggleOpenAtLogin() {
        do {
            if openAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { banner = "Open at login failed: \(error.localizedDescription)" }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    init() {
        try? fm.createDirectory(at: parkDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentFile.path) {
            try? defaultProfiles[0].write(to: currentFile, atomically: true, encoding: .utf8)
        }
        for p in defaultProfiles where p != currentProfile() {
            try? fm.createDirectory(at: parkDir.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        reloadList()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in await self.refresh() } }
        Task { await refresh() }
    }

    var active: Profile? { profiles.first { $0.name == current } }

    func reloadList() {
        current = currentProfile()
        claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        profiles = allProfileNames().map { n in
            profiles.first { $0.name == n } ?? Profile(name: n, snapshot: loadCache(n), signedIn: true)
        }
        onChange?()
    }

    func refresh() async {
        reloadList()
        banner = nil
        await withTaskGroup(of: (String, Result<Snapshot, Error>?).self) { g in
            for p in profiles {
                let dir = profileDir(p.name)
                g.addTask {
                    do {
                        guard let tok = try token(for: dir) else { return (p.name, nil) }
                        return (p.name, .success(try await fetchSnapshot(tok)))
                    } catch { return (p.name, .failure(error)) }
                }
            }
            for await (name, res) in g {
                guard let i = profiles.firstIndex(where: { $0.name == name }) else { continue }
                switch res {
                case nil: profiles[i].signedIn = false; profiles[i].error = nil
                case .success(let s)?: profiles[i].snapshot = s; profiles[i].signedIn = true; profiles[i].error = nil; saveCache(name, s)
                case .failure(let e)?:
                    profiles[i].error = e.localizedDescription
                    if e.localizedDescription.contains("Keychain") { banner = e.localizedDescription }
                }
            }
        }
        refreshCLI()
        lastRefresh = Date()
        onChange?()
    }

    func addProfile(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix("."), !profiles.contains(where: { $0.name == name }) else { return }
        try? fm.createDirectory(at: parkDir.appendingPathComponent(name), withIntermediateDirectories: true)
        reloadList()
        Task { await refresh() }
    }

    func switchTo(_ target: String) async {
        let cur = currentProfile()
        guard target != cur, busy == nil else { return }
        busy = "Quitting Claude…"
        switching = target
        defer { busy = nil; switching = nil }
        guard await quitClaude() else {
            banner = "Claude didn't quit. Close it manually, then switch again."
            return
        }
        busy = "Switching to \(target)…"
        do {
            let curPark = parkDir.appendingPathComponent(cur)
            let targetPark = parkDir.appendingPathComponent(target)
            if fm.fileExists(atPath: curPark.path) {
                // Only an empty placeholder may be replaced; anything else is real data.
                if ((try? fm.contentsOfDirectory(atPath: curPark.path)) ?? ["x"]).isEmpty {
                    try fm.removeItem(at: curPark)
                } else { throw err("\(curPark.path) already exists; refusing to overwrite.") }
            }
            if fm.fileExists(atPath: liveDir.path) { try fm.moveItem(at: liveDir, to: curPark) }
            if fm.fileExists(atPath: targetPark.path) { try fm.moveItem(at: targetPark, to: liveDir) }
            try target.write(to: currentFile, atomically: true, encoding: .utf8)
        } catch {
            banner = "Switch failed: \(error.localizedDescription)"
            return
        }
        busy = "Moving terminal login…"
        do { try await switchCLI(to: target) } catch { banner = "Terminal not switched: \(error.localizedDescription)" }
        busy = "Opening Claude…"
        await launchClaude()
        reloadList()
        await refresh()
    }

    func refreshCLI() {
        cliEmail = liveOauthAccount()?["emailAddress"] as? String
        if let saved = (try? String(contentsOf: cliCurrentFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            cliProfile = saved
        } else {
            // First run: work out which profile the terminal is on from its email.
            cliProfile = profiles.first { $0.snapshot?.email != nil && $0.snapshot?.email == cliEmail }?.name
                ?? (cliEmail == nil ? current : nil)
            if let p = cliProfile { try? p.write(to: cliCurrentFile, atomically: true, encoding: .utf8) }
        }
    }

    /// Parks the terminal's Claude login under its current profile and restores `target`'s
    /// (or logs the terminal out if `target` has none yet, so `claude /login` can set it up).
    func switchCLI(to target: String) async throws {
        refreshCLI()
        guard let cur = cliProfile else {
            throw err("Couldn't tell which profile the terminal is logged in as (\(cliEmail ?? "unknown")).")
        }
        guard cur != target else { return }
        var live = readLiveCLICreds() ?? [:]
        if let oauth = live["claudeAiOauth"] as? [String: Any] {
            // A still-running `claude` can re-save its old login after a switch. Make sure the
            // login we're about to park really belongs to `cur` before filing it there.
            let expected = profiles.first { $0.name == cur }?.snapshot?.email
            if let tok = oauth["accessToken"] as? String, let expected,
               let actual = (try? await getJSON("profile", tok))
                   .flatMap({ ($0["account"] as? [String: Any])?["email"] as? String }),
               actual != expected {
                throw err("The terminal is logged in as \(actual), not \(cur) (\(expected)). Quit running `claude` sessions and try again.")
            }
            var parked: [String: Any] = ["claudeAiOauth": oauth]
            parked["oauthAccount"] = liveOauthAccount()
            try writeKeychain(service: switcherService, account: "cli-\(cur)", json: parked)
        }
        let restore = readKeychain(service: switcherService, account: "cli-\(target)")
        live["claudeAiOauth"] = restore?["claudeAiOauth"]
        try writeKeychain(service: cliService, account: NSUserName(), json: live)
        try setLiveOauthAccount(restore?["oauthAccount"] as? [String: Any])
        try target.write(to: cliCurrentFile, atomically: true, encoding: .utf8)
        refreshCLI()
    }

    func moveTerminal(to target: String) async {
        guard busy == nil else { return }
        busy = "Moving terminal login…"
        do { try await switchCLI(to: target) } catch { banner = "Terminal not switched: \(error.localizedDescription)" }
        busy = nil
    }

    /// Copies threads into another profile. If that profile is live and Claude is running,
    /// Claude is restarted so it picks the new threads up.
    func copyThreads(_ threads: [ThreadInfo], to target: String) async -> String {
        guard busy == nil else { return "Busy, try again in a moment." }
        let restart = target == currentProfile()
            && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if restart {
            busy = "Quitting Claude…"
            guard await quitClaude() else { busy = nil; return "Claude didn't quit. Close it manually and try again." }
        }
        busy = "Copying \(threads.count) threads…"
        let result: String
        do {
            let (copied, skipped) = try copyThreadFiles(threads, to: profileDir(target))
            result = "Copied \(copied) thread\(copied == 1 ? "" : "s") to \(target)"
                + (skipped > 0 ? " (\(skipped) already there)" : "") + "."
        } catch { result = "Copy failed: \(error.localizedDescription)" }
        if restart { busy = "Opening Claude…"; await launchClaude() }
        busy = nil
        reloadList()
        return result
    }
}

func quitClaude() async -> Bool {
    let running = { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) }
    running().forEach { $0.terminate() }
    for _ in 0..<60 where !running().isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
    return running().isEmpty
}

func launchClaude() async {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Terminal (Claude Code CLI) login
//
// The CLI keeps its login in the keychain item "Claude Code-credentials" (key `claudeAiOauth`,
// next to MCP server logins under `mcpOAuth`, which stay shared) and the account details in
// ~/.claude.json `oauthAccount`. Parked logins go in our own keychain item, one per profile.
// Everything goes through /usr/bin/security, which is how the CLI itself reads the item.

let cliService = "Claude Code-credentials"
// Keeps the name from when this app was "Claude Switcher", so logins saved by earlier versions
// stay readable. The Claude-Profiles folder is kept for the same reason.
let switcherService = "Claude Switcher"
let cliCurrentFile = parkDir.appendingPathComponent(".cli-current")
let claudeJSON = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")

@discardableResult
func security(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    if stdin != nil { p.standardInput = inp }
    do { try p.run() } catch { return (-1, "") }
    if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func readKeychain(service: String, account: String) -> [String: Any]? {
    let r = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard r.status == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(r.out.trimmingCharacters(in: .newlines).utf8)) as? [String: Any]
}

func writeKeychain(service: String, account: String, json: [String: Any]) throws {
    let hex = try JSONSerialization.data(withJSONObject: json).map { String(format: "%02x", $0) }.joined()
    let acct = account.replacingOccurrences(of: "\"", with: "")
    // -i reads the command from stdin so the secret never shows up in `ps`.
    let r = security(["-i"], stdin: "add-generic-password -U -a \"\(acct)\" -s \"\(service)\" -X \(hex)\n")
    guard r.status == 0, readKeychain(service: service, account: account) != nil else {
        throw err("Couldn't save the login to the keychain (\(service)).")
    }
}

func readLiveCLICreds() -> [String: Any]? { readKeychain(service: cliService, account: NSUserName()) }

func liveOauthAccount() -> [String: Any]? {
    ((try? Data(contentsOf: claudeJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["oauthAccount"] as? [String: Any]
}

func setLiveOauthAccount(_ acct: [String: Any]?) throws {
    guard var j = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeJSON)) as? [String: Any] else {
        throw err("Couldn't read ~/.claude.json")
    }
    j["oauthAccount"] = acct
    try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: claudeJSON, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeJSON.path)
}

// MARK: - Claude Code threads
//
// Each desktop Code thread is one JSON file in <profile>/claude-code-sessions/<account>/<org>/.
// The conversation itself lives in the shared ~/.claude/projects, so copying the JSON is enough
// for another account to resume it.

struct ThreadInfo: Identifiable, Hashable {
    var id: String { file.lastPathComponent }
    let file: URL
    let title: String
    let cwd: String
    let lastActivity: Date
    let archived: Bool
    var project: String { (cwd as NSString).lastPathComponent }
}

/// Fields tied to the source account: its connectors, remote-control bridge and armed scheduled work.
let accountBoundThreadKeys = ["remoteMcpServersConfig", "bridgeSessionIds", "armedWorkAtQuit"]

/// The <account>/<org> folder holding a profile's threads, preferring its last signed-in account.
func threadsDir(_ profile: URL) -> URL? {
    let root = profile.appendingPathComponent("claude-code-sessions")
    let acctPref = ((try? Data(contentsOf: profile.appendingPathComponent("config.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["lastKnownAccountUuid"] as? String
    let accts = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
    guard let acct = accts.first(where: { $0 == acctPref }) ?? accts.first else { return nil }
    let acctDir = root.appendingPathComponent(acct)
    let orgs = ((try? fm.contentsOfDirectory(atPath: acctDir.path)) ?? []).filter { !$0.hasPrefix(".") }
    return orgs.first.map { acctDir.appendingPathComponent($0) }
}

func listThreads(_ profile: String) -> [ThreadInfo] {
    guard let dir = threadsDir(profileDir(profile)) else { return [] }
    let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
    return files.compactMap { name -> ThreadInfo? in
        let url = dir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cwd = j["cwd"] as? String,
              !cwd.contains("/Library/Application Support/") // scratch threads inside the profile folder
        else { return nil }
        let t = (j["lastActivityAt"] as? Double) ?? (j["createdAt"] as? Double) ?? 0
        return ThreadInfo(file: url, title: (j["title"] as? String) ?? "Untitled", cwd: cwd,
                          lastActivity: Date(timeIntervalSince1970: t / 1000),
                          archived: (j["isArchived"] as? Bool) ?? false)
    }.sorted { $0.lastActivity > $1.lastActivity }
}

func copyThreadFiles(_ threads: [ThreadInfo], to profile: URL) throws -> (copied: Int, skipped: Int) {
    guard let dest = threadsDir(profile) else {
        throw err("That account hasn't used Claude Code yet. Switch to it, open the Code tab once, then copy.")
    }
    var copied = 0, skipped = 0
    for t in threads {
        let out = dest.appendingPathComponent(t.file.lastPathComponent)
        if fm.fileExists(atPath: out.path) { skipped += 1; continue }
        guard var j = try JSONSerialization.jsonObject(with: Data(contentsOf: t.file)) as? [String: Any] else { continue }
        accountBoundThreadKeys.forEach { j.removeValue(forKey: $0) }
        try JSONSerialization.data(withJSONObject: j).write(to: out, options: .atomic)
        copied += 1
    }
    return (copied, skipped)
}

// MARK: - Formatting

func left(_ w: Window?) -> Double? { w.map { max(0, 100 - $0.used) } }
func pct(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "--" }

func countdown(_ d: Date?) -> String {
    guard let d else { return "--" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "now" }
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
}

func weekdayTime(_ d: Date?) -> String {
    guard let d else { return "--" }
    return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

func ago(_ d: Date?) -> String {
    guard let d else { return "never" }
    let s = Int(-d.timeIntervalSinceNow)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
