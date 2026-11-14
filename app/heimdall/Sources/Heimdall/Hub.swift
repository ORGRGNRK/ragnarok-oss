import AppKit
import Foundation
import SwiftUI

/// The Hub: every project, app and Ragnarok piece in one place, with what it is, its git state, its app, what runs
/// for it on Alexus, its recent activity, and one-click actions (open in the Room, build, run, git status).
/// Every action is recorded as a receipt in ~/.ragnarok/terminal-receipts.jsonl (provider "hub"), like terminal work.
@MainActor
final class HubModel: ObservableObject {
    var healProc: Process?
    @Published var packet: Packet?
    @Published var packetNote = ""
    struct Container: Hashable { let name: String; let status: String; let project: String
        var healthy: Bool { !status.contains("unhealthy") && status.hasPrefix("Up") } }

    struct Project: Identifiable, Hashable {
        let path: String
        var name: String { (path as NSString).lastPathComponent }
        /// folders outside ~/Developer show as ~/name, so ~/scripts and ~/Developer/scripts don't look the same
        var label: String {
            if path == "alexus:home-assistant" { return "Home Assistant" }
            return path.hasPrefix(HubModel.home + "/Developer/") || path.hasPrefix("alexus:") ? name : "~/" + name
        }
        var id: String { path }
        var kinds: [String] = []          // swift, docker, node, python, xcode, notes
        var about = ""                    // first line of README/AGENTS/CLAUDE
        var branch: String?
        var lastCommit = ""               // date · subject
        var dirty = 0                     // uncommitted files
        var app: String?                  // ~/Applications/X.app built from it
        var build: String?                // detected build command
        var alexusFolder = false
        var containers: [Container] = []
        var modified: Date = .distantPast
    }

    @Published var projects: [Project] = []
    @Published var selected: String?
    @Published var filter = "all"
    @Published var query = ""
    @Published var alexusNote = "Checking Alexus…"
    @Published var refreshing = false
    @Published var tab = "hub"               // the window's tab; the Hub can switch to the Room
    @Published var output = ""               // last action's output
    @Published var runKind: String?          // "resume" / "heal" / "packet" while runLive runs (for RunProgress)
    @Published var runStarted: Date?
    @Published var lastOutputAt: Date?
    @Published var running: String?          // action in progress
    @Published var services: [Service] = []  // MCP servers (claude mcp list)
    @Published var jobs: [Job] = []          // Mac background jobs (~/Library/LaunchAgents)
    @Published var servicesNote = "Not checked yet"
    @Published var history: [Item] = []
    @Published var historyFor: String?
    @Published var historyLoading = false
    @Published var healPlan = ""
    @Published var runningApps: Set<String> = []   // paths of ~/Applications apps that are running now
    var containers: [Container] { projects.flatMap(\.containers) }

    nonisolated static let home = NSHomeDirectory()
    nonisolated static let roots = [home + "/Developer"]
    nonisolated static let monorepoApps = [home + "/Developer/ragnarok/app"]
    nonisolated static let extra = ["conveyor", "conveyor-app", "conveyor-lanes", "scripts", "exo"].map { home + "/" + $0 }
    /// Home-network ssh first, Tailscale second. The one that answered last is tried first next time.
    nonisolated private static let sshLock = NSLock()
    nonisolated(unsafe) private static var sshChosenStore: String?
    nonisolated static var sshCandidates: [String] {
        let v = LocalConfig.current
        let lan = v.alexusUser + "@" + v.alexusHost
        let ts = v.alexusUser + "@" + v.alexusTailscale
        return lan == ts ? [lan] : [lan, ts]
    }
    nonisolated static func sshTarget() -> String {
        sshLock.lock(); defer { sshLock.unlock() }
        return sshChosenStore ?? sshCandidates[0]
    }
    nonisolated static func rememberSSH(_ target: String) {
        sshLock.lock(); sshChosenStore = target; sshLock.unlock()
    }
    /// Apps whose names don't follow their folder's name.
    nonisolated static let appNames = ["heimdall": "Ragnarok", "ragnarok-control-center": "Ragnarok Control Center",
                                       "local-ai-app": "LocalAI", "phone-grader-app": "PhoneGrader"]

    var shown: [Project] {
        projects.filter { p in
            (filter == "all" || p.kinds.contains(filter) || (filter == "alexus" && (p.alexusFolder || !p.containers.isEmpty))
             || (filter == "changed" && p.dirty > 0))
            && (query.isEmpty || p.name.localizedCaseInsensitiveContains(query) || p.about.localizedCaseInsensitiveContains(query))
        }
    }
    var current: Project? { projects.first { $0.path == selected } }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let local = await Task.detached { Self.discover() }.value
            projects = local
            if selected == nil { selected = local.first?.path }
            let (folders, containers, note) = await Task.detached { Self.alexusState() }.value
            projects = Self.link(local, folders: folders, containers: containers)
            alexusNote = note
            refreshing = false
        }
        refreshApps()
        refreshServices()
    }

    // MARK: discovery (runs off the main thread)

    nonisolated static func discover() -> [Project] {
        let fm = FileManager.default
        var dirs: [String] = []
        for r in roots + monorepoApps {
            for n in (try? fm.contentsOfDirectory(atPath: r)) ?? [] where !n.hasPrefix(".") {
                dirs.append(r + "/" + n)
            }
        }
        dirs += extra
        var seenCanon = Set<String>()
        var byName: [String: Int] = [:]
        var out: [Project] = []
        for d in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue, !d.hasSuffix(".app") else { continue }
            let canon = URL(fileURLWithPath: d).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard seenCanon.insert(canon).inserted else { continue }
            let proj = inspect(d)
            if let existingIdx = byName[proj.name.lowercased()] {
                let existing = out[existingIdx]
                let existingEmpty = existing.kinds.isEmpty && existing.branch == nil
                let candidateReal = !proj.kinds.isEmpty || proj.branch != nil
                if existingEmpty && candidateReal {
                    out[existingIdx] = proj
                }
                continue
            }
            byName[proj.name.lowercased()] = out.count
            out.append(proj)
        }
        return out.sorted { $0.modified > $1.modified }
    }

    nonisolated static func inspect(_ d: String) -> Project {
        let fm = FileManager.default
        var p = Project(path: d)
        let has = { (f: String) in fm.fileExists(atPath: d + "/" + f) }
        let names = (try? fm.contentsOfDirectory(atPath: d)) ?? []
        if has("Package.swift") { p.kinds.append("swift") }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") }) || has("project.yml") { p.kinds.append("xcode") }
        if has("docker-compose.yml") || has("compose.yaml") || has("docker-compose.yaml") { p.kinds.append("docker") }
        if has("package.json") { p.kinds.append("node") }
        if has("pyproject.toml") || has("requirements.txt") || names.contains(where: { $0.hasSuffix(".py") }) { p.kinds.append("python") }
        if p.kinds.isEmpty && names.contains(where: { $0.hasSuffix(".md") }) { p.kinds.append("notes") }
        for doc in ["README.md", "AGENTS.md", "CLAUDE.md"] {
            if let s = try? String(contentsOfFile: d + "/" + doc, encoding: .utf8) {
                p.about = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") && !$0.hasPrefix("```") }.map { String($0.prefix(220)) } ?? ""
                if p.about.isEmpty, let h = s.split(separator: "\n").first { p.about = h.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                break
            }
        }
        // its own repo, or a folder inside one (since 11-02 most projects live in ~/Developer/ragnarok and the old
        // ~/Developer/<name> paths are links to them): commit and changes are counted for this folder only
        if has(".git") || git(d, ["rev-parse", "--is-inside-work-tree"]) == "true" {
            p.branch = git(d, ["branch", "--show-current"])
            p.lastCommit = git(d, ["log", "-1", "--format=%cs · %s", "--", "."]).map { String($0.prefix(120)) } ?? ""
            p.dirty = (git(d, ["status", "--porcelain", "--", "."]) ?? "").split(separator: "\n").count
        }
        if has("make-app.sh") { p.build = "./make-app.sh" }
        else if has("Package.swift") { p.build = "swift build" }
        else if has("package.json"), let pj = try? String(contentsOfFile: d + "/package.json", encoding: .utf8), pj.contains("\"build\"") { p.build = "npm run build" }
        let appName = appNames[p.name] ?? p.name
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "-app", with: "").filter { $0.isLetter || $0.isNumber } }
        if let apps = try? fm.contentsOfDirectory(atPath: home + "/Applications") {
            let claimed = Set(appNames.values.map { $0 + ".app" })   // e.g. Ragnarok.app belongs to heimdall, not ragnarok
            p.app = apps.first { $0.hasSuffix(".app") && ($0 == appName + ".app"
                || (!claimed.contains($0) && norm(($0 as NSString).deletingPathExtension) == norm(p.name))) }
                .map { home + "/Applications/" + $0 }
        }
        let gitDate = (try? fm.attributesOfItem(atPath: d + "/.git/index")[.modificationDate] as? Date) ?? nil
        p.modified = gitDate ?? ((try? fm.attributesOfItem(atPath: d)[.modificationDate] as? Date) ?? .distantPast)
        return p
    }

    nonisolated static func git(_ d: String, _ args: [String]) -> String? {
        let (code, out) = run("/usr/bin/git", ["-C", d] + args, timeout: 8)
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && !s.isEmpty ? s : nil
    }

    /// Alexus: its ~/Developer folders and every container with status and compose project. Read-only, over ssh as ALEXUS_USER.
    /// The home-network address is tried first; if that host is down, the Tailscale address is tried.
    nonisolated static func alexusState() -> ([String], [Container], String) {
        let cmd = "ls ~/Developer 2>/dev/null; echo ---; docker ps -a --format '{{.Names}}\\t{{.Status}}\\t{{.Label \"com.docker.compose.project\"}}' 2>/dev/null"
        let first = sshTarget()
        let order = [first] + sshCandidates.filter { $0 != first }
        for target in order {
            let (code, out) = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target, cmd], timeout: 20)
            guard code == 0, let split = out.range(of: "---\n") ?? out.range(of: "---") else { continue }
            rememberSSH(target)
            let via = target == sshCandidates[0] ? "" : " · over Tailscale"
            let folders = out[..<split.lowerBound].split(separator: "\n").map(String.init)
            let cs = out[split.upperBound...].split(separator: "\n").compactMap { l -> Container? in
                let f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return f.count >= 2 ? Container(name: f[0], status: f[1], project: f.count > 2 ? f[2] : "") : nil
            }
            let bad = cs.filter { !$0.healthy }.count
            return (folders, cs, "Alexus: \(cs.count) containers, \(bad) not healthy · \(folders.count) folders in ~/Developer\(via)")
        }
        return ([], [], "Alexus not reachable over ssh")
    }

    /// The Home Assistant container has no compose project label, so name-matching is the only join.
    nonisolated static func isHomeAssistant(_ c: Container) -> Bool {
        let n = c.name.lowercased(), p = c.project.lowercased()
        return n == "homeassistant" || n == "home-assistant" || p == "homeassistant" || p == "home-assistant"
    }

    /// A container belongs to a project when Docker's compose label says so (<name> or ck-<name>, the client-kit
    /// naming); containers without a label match by name prefix.
    nonisolated static func belongs(_ c: Container, to name: String) -> Bool {
        let n = name.lowercased(), proj = c.project.lowercased()
        if !proj.isEmpty { return proj == n || proj == "ck-" + n }
        let cn = c.name.lowercased(); return cn == n || cn.hasPrefix(n + "-")
    }

    /// Match Alexus folders and containers to Mac projects by name.
    nonisolated static func link(_ ps: [Project], folders: [String], containers: [Container]) -> [Project] {
        var out = ps
        for i in out.indices {
            let n = out[i].name.lowercased()
            out[i].alexusFolder = folders.contains { $0.lowercased() == n }
            out[i].containers = out[i].path.hasPrefix(home + "/Developer/") ? containers.filter { belongs($0, to: n) } : []
        }
        // Alexus-only stacks (folders there with no Mac copy) still belong in the hub
        let macNames = Set(ps.map { $0.name.lowercased() })
        for f in folders where !macNames.contains(f.lowercased()) {
            var p = Project(path: "alexus:~/Developer/" + f)
            p.kinds = ["alexus"]; p.alexusFolder = true; p.about = "Only on Alexus (no copy on this Mac)."
            p.containers = containers.filter { belongs($0, to: f) }
            out.append(p)
        }
        // Home Assistant is always a project. Its container usually has no compose label, so it would otherwise
        // show up as a raw docker name, or not at all when ssh to the old home-network address fails.
        let claimedBefore = Set(out.flatMap { $0.containers.map(\.name) })
        var ha = Project(path: "alexus:home-assistant")
        ha.kinds = ["alexus"]
        ha.about = "Home Assistant on Alexus. Log in on its own page; Ragnarok does not keep a token."
        ha.containers = containers.filter { isHomeAssistant($0) && !claimedBefore.contains($0.name) }
        out.insert(ha, at: 0)
        // containers that belong to no folder (e.g. the ck-receipts stack) get their own entry, so nothing running is missed
        let claimed = Set(out.flatMap { $0.containers.map(\.name) })
        let loose = Dictionary(grouping: containers.filter { !claimed.contains($0.name) }) { $0.project.isEmpty ? $0.name : $0.project }
        for (stack, cs) in loose.sorted(by: { $0.key < $1.key }) {
            var p = Project(path: "alexus:docker/" + stack)
            p.kinds = ["alexus"]; p.containers = cs
            p.about = "Running on Alexus in Docker, with no matching project folder."
            out.append(p)
        }
        return out
    }

    /// K5 (break-test): the command runs in its own process group (perl setpgrp, then exec), so on timeout the whole
    /// group is stopped — children that keep the pipe open can no longer make the Hub wait past the deadline.
    nonisolated static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: Double) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "setpgrp(0,0); exec { $ARGV[0] } @ARGV or exit 127", exe] + args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HEIMDALL_LAUNCHER")
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        let buf = RunBuffer(), eof = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.signal() } else { buf.add(d) }
        }
        guard (try? p.run()) != nil else { out.fileHandleForReading.readabilityHandler = nil; return (-1, "couldn't start \(exe)") }
        let pid = p.processIdentifier
        var timedOut = false
        if eof.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-pid, SIGTERM)
            if eof.wait(timeout: .now() + 2) == .timedOut { kill(-pid, SIGKILL); _ = eof.wait(timeout: .now() + 1) }
            out.fileHandleForReading.readabilityHandler = nil
        }
        p.waitUntilExit()
        let text = String(decoding: buf.data, as: UTF8.self)
        return timedOut ? (124, text + "\n[stopped: no finish after \(Int(timeout)) s]") : (p.terminationStatus, text)
    }

    // MARK: actions


    func openApp(_ p: Project) {
        guard let a = p.app else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: a))
        receipt(p, "open \((a as NSString).lastPathComponent)", exit: 0, out: "")
    }

    func finder(_ p: Project) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }

    /// Build or git status, in the project folder; output shown in the Hub and kept in a receipt.
    func act(_ p: Project, _ label: String, _ command: String, timeout: Double = 900) {
        guard running == nil, !p.path.hasPrefix("alexus:") else { return }
        running = "\(label) · \(p.name)"; output = "$ \(command)\n"
        Task {
            let start = Date()
            let (code, out) = await Task.detached { Self.run("/bin/zsh", ["-lc", command], cwd: p.path, timeout: timeout) }.value
            output += out.suffix(20_000) + "\n[exit \(code) · \(Int(Date().timeIntervalSince(start))) s]"
            receipt(p, command, exit: code, out: out, start: start)
            running = nil
            // report item 15: look the project up again AFTER the await (the list may have refreshed meanwhile)
            var fresh = await Task.detached { Self.inspect(p.path) }.value
            fresh.containers = p.containers; fresh.alexusFolder = p.alexusFolder
            if let i = projects.firstIndex(where: { $0.path == p.path }) { projects[i] = fresh }
        }
    }

    func receipt(_ p: Project, _ what: String, exit: Int32, out: String, start: Date = Date()) {
        let changed = p.path.hasPrefix("/") ? Receipts.changed(since: start, under: p.path) : []
        Receipts.write(provider: "hub", question: "\(p.name): \(what)", cwd: p.path, start: start, exit: exit,
                       changed: changed, claims: [], verdict: exit == 0 ? "no-claims" : "failed")
    }
}

struct HubView: View {
    @EnvironmentObject var hub: HubModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var room: RoomModel
    @State private var asks: [String: String] = [:]      // report item 17: typed text belongs to its project
    @State private var healAsks: [String: String] = [:]
    @State private var mode = "quick"
    @State private var histFilter = "all"
    @State private var healWho = "claude"
    @State private var resumeRounds = 1

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search projects", text: $hub.query).textFieldStyle(.roundedBorder)
                    Button { hub.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(hub.refreshing).help("Look again")
                    Button { hub.tab = "home" } label: { Image(systemName: "house") }
                        .help("Home Assistant (its tab, inside Ragnarok)")
                }
                .padding(8)
                Picker("", selection: $hub.filter) {
                    Text("All").tag("all"); Text("Apps").tag("swift"); Text("Docker").tag("docker")
                    Text("Node").tag("node"); Text("Python").tag("python"); Text("Alexus").tag("alexus"); Text("Changed").tag("changed")
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 8).padding(.bottom, 6)
                List(selection: $hub.selected) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").font(.caption).foregroundStyle(servicesColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Services").font(.callout.weight(.medium))
                            Text(hub.servicesNote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag("services:")
                    ForEach(hub.shown) { p in
                    HStack(spacing: 6) {
                        Circle().fill(dot(p)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.label).font(.callout.weight(.medium)).lineLimit(1)
                            Text(p.kinds.joined(separator: " · ") + (p.dirty > 0 ? " · \(p.dirty) changed" : ""))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if p.app != nil { Image(systemName: "app.fill").font(.caption2).foregroundStyle(.secondary) }
                        if !p.containers.isEmpty { Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .tag(p.path)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Text(hub.refreshing ? "Looking…" : "\(hub.projects.count) projects · \(hub.alexusNote)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)

            if hub.selected == "services:" { ServicesView() }
            else if hub.current?.path == "alexus:home-assistant" { HomeAssistantView() }
            else if let p = hub.current { detail(p) } else {
                Text("Pick a project").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if hub.projects.isEmpty { hub.refresh() }; room.start() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in hub.refreshApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in hub.refreshApps() }
    }

    private var servicesColor: Color {
        hub.services.contains { $0.state == "fail" } || hub.containers.contains { !$0.healthy } ? .red : hub.services.isEmpty ? .gray : .green
    }

    /// green = clean, orange = uncommitted changes, red = a container on Alexus isn't healthy
    private func dot(_ p: HubModel.Project) -> Color {
        if p.containers.contains(where: { !$0.healthy }) { return .red }
        if p.dirty > 0 { return .orange }
        return p.branch != nil || !p.containers.isEmpty ? .green : .gray
    }

    @ViewBuilder private func detail(_ p: HubModel.Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.label).font(.title2.bold())
                    Text(p.path.replacingOccurrences(of: HubModel.home, with: "~")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !p.about.isEmpty { Text(p.about.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")).font(.callout).padding(.top, 2) }
                }
                HStack(spacing: 8) {
                    if p.path.hasPrefix("/") {
                        if let b = p.build { Button { hub.act(p, "build", b) } label: { Label("Build", systemImage: "hammer") } }
                        if let a = p.app {
                            if hub.isRunning(a) { Button { hub.quitApp(p) } label: { Label("Quit app", systemImage: "stop.fill") } }
                            else { Button { hub.openApp(p) } label: { Label("Run app", systemImage: "play.fill") } }
                        }
                        if p.branch != nil { Button { hub.act(p, "git", "git status -sb && git log --oneline -5", timeout: 30) } label: { Label("Git status", systemImage: "arrow.triangle.branch") } }
                        Button { hub.finder(p) } label: { Label("Finder", systemImage: "folder") }
                    }
                }
                .controlSize(.regular).disabled(hub.running != nil)

                section("Code") {
                    if let b = p.branch {
                        row("Branch", b); row("Last commit", p.lastCommit.isEmpty ? "none" : p.lastCommit)
                        row("Uncommitted", p.dirty == 0 ? "nothing" : "\(p.dirty) file\(p.dirty == 1 ? "" : "s")")
                    } else { row("Git", p.path.hasPrefix("/") ? "not a git repository" : "on Alexus") }
                    row("Kind", p.kinds.isEmpty ? "unknown" : p.kinds.joined(separator: ", "))
                    row("Build", p.build ?? "no build step found")
                    row("App", p.app.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "none in ~/Applications")
                }
                section("On Alexus") {
                    row("Folder", p.alexusFolder ? "~/Developer/\(p.name)" : "none")
                    if p.containers.isEmpty { row("Containers", "none") }
                    else if p.containers.count > 1 {
                        HStack(spacing: 6) {
                            Text("Whole stack:").font(.caption).foregroundStyle(.secondary)
                            Button("Restart all") { hub.container("restart", p.containers.map(\.name), in: p) }
                            Button("Stop all") { hub.container("stop", p.containers.map(\.name), in: p) }
                            Button("Start all") { hub.container("start", p.containers.map(\.name), in: p) }
                        }
                        .controlSize(.small).disabled(hub.running != nil)
                    }
                    ForEach(p.containers, id: \.self) { c in
                        HStack(spacing: 6) {
                            Circle().fill(c.healthy ? Color.green : Color.red).frame(width: 7, height: 7)
                            Text(c.name).font(.caption.monospaced())
                            Text(c.status).font(.caption).foregroundStyle(c.healthy ? Color.secondary : Color.red)
                            Spacer()
                            Group {
                                Button("Logs") { hub.logs(c.name, in: p) }
                                if c.status.hasPrefix("Up") {
                                    Button("Restart") { hub.container("restart", [c.name], in: p) }
                                    Button("Stop") { hub.container("stop", [c.name], in: p) }
                                } else { Button("Start") { hub.container("start", [c.name], in: p) } }
                            }
                            .controlSize(.small).disabled(hub.running != nil)
                        }
                    }
                }
                if p.branch != nil { packetSection(p) }
                if p.branch != nil { healSection(p) }
                handOff(p)
                if hub.running != nil || !hub.output.isEmpty {
                    section(hub.running.map { "Running: \($0)" } ?? "Last action") {
                        if hub.healProc != nil && hub.running != nil {
                            Button("Stop") { hub.stopHeal() }.controlSize(.small)
                                .help("Stops the change. The staging copy is removed and nothing is changed.")
                        }
                        Text(hub.output).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                historySection(p)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: p.path) { hub.loadHistory(p); hub.loadPlan(p); hub.loadPacket(p) }
    }

    /// Everything that happened to this project, newest first: what the Hub collected, plus room tasks and timeline events.
    @ViewBuilder private func historySection(_ p: HubModel.Project) -> some View {
        let items = Self.merged(hub.historyFor == p.path ? hub.history : [], room: roomItems(p), activity: recent(p).map {
            HubModel.Item(time: $0.time, kind: "activity", who: $0.actor, title: $0.title.oneLine(160)) })
        let shown = items.filter { HubModel.matches($0.kind, histFilter) }
        section("History") {
            HStack {
                Picker("", selection: $histFilter) {
                    ForEach(["all", "code", "runs", "failure", "alexus", "ai"], id: \.self) { k in
                        Text(HubModel.historyKinds[k]! + count(items, k)).tag(k)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                if hub.historyLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { hub.loadHistory(p) } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small).help("Look again")
            }
            if shown.isEmpty && !hub.historyLoading { Text("Nothing here yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(shown.prefix(80)) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.icon(i.kind)).font(.caption2).foregroundStyle(i.kind == "failure" ? Color.red : Color.secondary).frame(width: 14)
                    Text(Self.when(i.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                    Text(i.who).font(.caption.bold()).foregroundStyle(Palette.color(i.who)).frame(width: 70, alignment: .leading).lineLimit(1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.title).font(.caption).foregroundStyle(i.kind == "failure" ? Color.red : Color.primary).lineLimit(2)
                        if !i.detail.isEmpty { Text(i.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .textSelection(.enabled)
                }
            }
            if shown.count > 80 { Text("Showing the newest 80 of \(shown.count).").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func count(_ items: [HubModel.Item], _ k: String) -> String {
        k == "all" ? "" : { let n = items.filter { HubModel.matches($0.kind, k) }.count; return n > 0 ? " \(n)" : "" }()
    }

    /// Newest first; the same thing reported twice (same time to the second and same title) shows once.
    static func merged(_ a: [HubModel.Item], room: [HubModel.Item], activity: [HubModel.Item]) -> [HubModel.Item] {
        var seen = Set<String>()
        return (a + room + activity).sorted { $0.time > $1.time }.filter { seen.insert("\(Int($0.time.timeIntervalSince1970))|\($0.title)").inserted }
    }

    private func roomItems(_ p: HubModel.Project) -> [HubModel.Item] {
        let name = Self.roomName(p)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [HubModel.Item] = []
        for t in room.msgs where t.type == "task" && t.text.contains("In \(name):") {
            let ask = t.text.replacingOccurrences(of: "In \(name): ", with: "")
            if let d = iso.date(from: t.ts) { out.append(HubModel.Item(time: d, kind: "room", who: t.by, title: "room task: \(ask)".oneLine(160))) }
            for r in room.msgs where r.id != t.id && (r.ref == t.id || r.text.contains(t.id)) && r.type != "claim" {
                if let d = iso.date(from: r.ts) {
                    out.append(HubModel.Item(time: d, kind: "room", who: r.by, title: (r.type == "done" ? "done: " : "") + r.text.oneLine(160)))
                }
            }
        }
        return out
    }

    static func icon(_ k: String) -> String {
        ["commit": "arrow.triangle.branch", "receipt": "doc.text", "failure": "exclamationmark.triangle.fill", "conveyor": "shippingbox.and.arrow.backward",
         "container": "shippingbox", "room": "bubble.left.and.bubble.right", "activity": "eye"][k] ?? "circle"
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' HH:mm" : Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d HH:mm" : "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// How a project is named in room tasks, so its tasks can be found again: ~/Developer/x, ~/x, or Alexus ~/Developer/x.
    nonisolated static func roomName(_ p: HubModel.Project) -> String {
        if p.path.hasPrefix("alexus:") { return "Alexus " + p.path.dropFirst(7) }
        return p.path.replacingOccurrences(of: HubModel.home, with: "~")
    }

    /// The text posted to the room: belt: goes to the full conveyor, no-belt: is left for hand work, anything else
    /// gets one read-only AI (conveyor-room decides by the first word).
    static func taskText(_ p: HubModel.Project, mode: String, ask: String) -> String {
        let prefix = mode == "belt" ? "belt: " : mode == "hand" ? "no-belt: " : ""
        return prefix + "In \(roomName(p)): " + ask.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hand the project to the AIs (a room task), and its tasks so far with their latest replies.
    @ViewBuilder private func handOff(_ p: HubModel.Project) -> some View {
        let name = Self.roomName(p)
        let mine = room.msgs.filter { $0.type == "task" && $0.text.contains("In \(name):") }
        section("Hand to the AIs") {
            HStack(spacing: 6) {
                Picker("", selection: $mode) {
                    Text("Ask (read-only)").tag("quick"); Text("Build on the conveyor").tag("belt"); Text("By hand").tag("hand")
                }
                .labelsHidden().frame(width: 190)
                TextField("What should happen in \(p.label)?", text: Binding(get: { asks[p.path] ?? "" }, set: { asks[p.path] = $0 })).textFieldStyle(.roundedBorder)
                    .onSubmit { send(p) }
                Button("Send") { send(p) }.disabled((asks[p.path] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || room.sending)
            }
            Text(mode == "quick" ? "One AI looks and answers; it can't change anything. If changes are needed it passes it to the conveyor."
                 : mode == "belt" ? "The full conveyor: a planner writes the steps, a second AI checks them, then it's built and each step is proven."
                 : "Posted as a task the conveyor leaves alone, for you or an AI to do by hand.")
                .font(.caption2).foregroundStyle(.secondary)
            if mine.isEmpty { Text("No room tasks for this project yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(mine.suffix(6).reversed()) { t in
                let replies = room.msgs.filter { $0.id != t.id && ($0.ref == t.id || $0.text.contains(t.id)) }
                let state = replies.last { $0.type == "done" } != nil ? "done" : replies.contains { $0.type == "claim" } ? "being worked on" : "waiting"
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(state == "done" ? Color.green : state == "waiting" ? Color.gray : Color.orange).frame(width: 7, height: 7)
                        Text(t.text.replacingOccurrences(of: "In \(name): ", with: "")).font(.caption.weight(.medium)).lineLimit(2)
                        Spacer()
                        Text("\(state) · \(String(t.id.prefix(8)))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let r = replies.last(where: { $0.type != "claim" }) {
                        Text("\(r.by): \(r.text)").font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                    }
                }
                .padding(6).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Open the Room") { hub.tab = "room" }.controlSize(.small)
            }
        }
    }

    /// The self-healing loop for this project: an AI changes a staging copy; it only lands if it builds and passes its test.
    @ViewBuilder private func healSection(_ p: HubModel.Project) -> some View {
        section("Change it with an AI (proven)") {
            HStack(spacing: 6) {
                Picker("", selection: $healWho) { ForEach(["claude", "grok", "codex"], id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 120)
                TextField("What should change in \(p.label)?", text: Binding(get: { healAsks[p.path] ?? "" }, set: { healAsks[p.path] = $0 })).textFieldStyle(.roundedBorder)
                    .onSubmit { runHeal(p) }
                Button("Change it") { runHeal(p) }
                    .disabled((healAsks[p.path] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || hub.running != nil || hub.healPlan.contains("test: (none"))
                    .help("Built and tested in a separate copy before it lands")
            }
            RunProgress(kind: "heal")
            Text(hub.healPlan.isEmpty ? "" : "Steps: " + hub.healPlan).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Done in a separate copy. It's committed only if it builds and passes the test. If that fails, it tries again by itself, up to 4 times. Otherwise nothing changes. Live output appears below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One switch/resume packet per project, in Ragnarok HQ. Any AI can pick the project up from it and keep going.
    @ViewBuilder private func packetSection(_ p: HubModel.Project) -> some View {
        section("Switch / resume packet") {
            if let k = hub.packet {
                Text("\(k.id) · by \(k.ai) · \(k.created) UTC").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                DisclosureGroup("State") { Text(k.state).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("Next steps").font(.caption.bold())
                Text(k.next).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(hub.packetNote).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Picker("", selection: $healWho) { ForEach(["claude", "grok", "codex"], id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 120)
                Picker("", selection: $resumeRounds) {
                    Text("1 round").tag(1); Text("keep going (3)").tag(3); Text("keep going (5)").tag(5)
                }
                .labelsHidden().frame(width: 140)
                Button("Resume") { hub.resume(p, who: healWho, rounds: resumeRounds, packetOnly: false) }
                    .disabled(hub.packet == nil || hub.running != nil || hub.healPlan.contains("test: (none"))
                    .help("The AI does the next steps through the proven loop (build + test before it lands), then writes the next packet")
                Button("Save packet") { hub.resume(p, who: healWho, rounds: 1, packetOnly: true) }
                    .disabled(hub.running != nil)
                    .help("Write a fresh packet from the project's current state (a switch), without doing any work")
                Button { hub.loadPacket(p) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload")
            }
            RunProgress(kind: "resume")
            Text(hub.healPlan.contains("test: (none") && !HubModel.isMainApp(p)
                 ? "Resume needs a test step for this project (add TEST= to .ragnarok-heal), so nothing unproven lands."
                 : "Steps that need you (money, accounts, deleting, sending, sudo, keys, clicking) are left in the packet as OWNER: steps.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func runHeal(_ p: HubModel.Project) {
        let a = (healAsks[p.path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, hub.running == nil, !hub.healPlan.contains("test: (none") else { return }
        hub.heal(p, who: healWho, a); healAsks[p.path] = nil
    }

    private func send(_ p: HubModel.Project) {
        let a = (asks[p.path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !room.sending else { return }
        let text = Self.taskText(p, mode: mode, ask: a)
        let m = mode, path = p.path
        room.post("task", text) { ok in
            guard ok else { return }   // not sent: the text stays in the box
            hub.receipt(p, "room task (\(m)): \(a)", exit: 0, out: "")
            if (asks[path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == a { asks[path] = nil }
        }
    }

    /// The last 30 timeline events whose text names this project's folder.
    private func recent(_ p: HubModel.Project) -> [Event] {
        let key = "/" + p.name
        var out: [Event] = []
        for e in store.events.reversed() where e.title.contains(key) || e.body.contains(key + "/") || e.body.contains(key + "\"") {
            out.append(e); if out.count >= 30 { break }
        }
        return out
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled)
        }
    }
}

/// Output collected from a Hub command's pipe (written on the pipe's queue, read after it finishes).
final class RunBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var d = Data()
    func add(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return d }
}
