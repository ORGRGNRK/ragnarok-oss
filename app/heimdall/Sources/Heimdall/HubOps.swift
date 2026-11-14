import AppKit
import Foundation
import SwiftUI

/// Hub operations: start/stop/restart/logs for Alexus containers, run/quit apps, MCP server health and the Mac's
/// background jobs. Anything that changes state asks first and writes a receipt (provider "hub").
extension HubModel {
    struct Service: Hashable { let name: String; let target: String; let state: String; let detail: String }  // state: ok | auth | fail
    struct Job: Hashable { let label: String; let pid: String?; let lastExit: String?; var loaded: Bool { lastExit != nil } }

    // MARK: change a project with an AI, proven (ragnarok-heal; main Ragnarok uses heimdall-edit)

    nonisolated static let healScript = AppPaths.repoBin("ragnarok-heal")
    nonisolated static let heimdallEdit = AppPaths.repoBin("heimdall-edit")

    /// The build/test/install steps the loop would use for this project (`ragnarok-heal --plan`).
    func loadPlan(_ p: Project) {
        guard p.path.hasPrefix("/") else { healPlan = ""; return }
        if Self.isMainApp(p) { healPlan = "main Ragnarok: heimdall-edit (build · self-test · install · crash rollback)"; return }
        healPlan = "…"
        Task {
            let (_, out) = await Task.detached { Self.run(Self.healScript, [p.path, "--plan"], timeout: 20) }.value
            guard current?.path == p.path else { return }
            healPlan = out.split(separator: "\n").dropFirst().map { $0.replacingOccurrences(of: "  ", with: " ") }.joined(separator: " · ")
        }
    }

    /// Runs the loop with live output. Nothing changes unless the change builds and passes its test.
    func heal(_ p: Project, who: String, _ instruction: String) {
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running == nil, p.path.hasPrefix("/"), !ask.isEmpty else { return }
        let main = Self.isMainApp(p)
        // the instruction goes on stdin ("-"), so long or multi-line text never hits argument limits (report A8)
        let (exe, args) = main ? (Self.heimdallEdit, [who, "-"]) : (Self.healScript, [p.path, who, "-"])
        runLive(p, kind: "heal", exe: exe, args: args, stdin: ask, title: "\(who) changing \(p.label)",
                header: "$ \((exe as NSString).lastPathComponent) \(who) \"\(ask)\"\n",
                okText: "Done: built, tested and committed." + (main ? " Click Restart (Timeline tab) or reopen Ragnarok to use it." : ""),
                failText: "Nothing was changed.")
    }

    // MARK: switch / resume packets (bin/ragnarok-packet, bin/ragnarok-resume; stored in Ragnarok HQ Switch_Packets)

    struct Packet: Equatable { let id: String; let ai: String; let created: String; let state: String; let next: String }
    nonisolated static let packetScript = AppPaths.bundledBin("ragnarok-packet")
    nonisolated static let resumeScript = AppPaths.repoBin("ragnarok-resume")

    /// Same slug rule as ragnarok-packet: folder name, lowercased, other characters as "-".
    nonisolated static func slug(_ p: Project) -> String {
        let s = p.name.lowercased().map { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(s).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func loadPacket(_ p: Project) {
        guard p.path.hasPrefix("/") else { packet = nil; packetNote = "Alexus-only folder: no packet here"; return }
        packetNote = "loading the packet from Ragnarok HQ…"
        Task {
            let (code, out) = await Task.detached { Self.run(Self.packetScript, ["get", Self.slug(p)], timeout: 40) }.value
            guard current?.path == p.path else { return }
            let d = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            if code == 0, let d, let id = d["Packet_ID"] as? String {
                packet = Packet(id: id, ai: d["AI_Actor"] as? String ?? "?", created: String((d["Created"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "),
                                state: d["Summary_State"] as? String ?? "", next: d["Next_Steps"] as? String ?? "")
                packetNote = ""
            } else {
                packet = nil
                packetNote = code == 0 ? "No packet yet. Save one so any AI can pick this project up." : "Couldn't reach Ragnarok HQ: " + out.oneLine(160)
            }
        }
    }

    /// Resume from the packet (rounds of proven work, a new packet after each), or packetOnly: just write a fresh packet.
    func resume(_ p: Project, who: String, rounds: Int, packetOnly: Bool) {
        guard running == nil, p.path.hasPrefix("/") else { return }
        let args = [p.path, who] + (packetOnly ? ["--packet-only"] : ["--rounds", "\(rounds)"])
        runLive(p, kind: packetOnly ? "packet" : "resume", exe: Self.resumeScript, args: args, stdin: "",
                title: packetOnly ? "writing a packet for \(p.label)" : "\(who) resuming \(p.label)",
                header: "$ ragnarok-resume \(p.label) \(args.dropFirst().joined(separator: " "))\n",
                okText: packetOnly ? "Packet saved." : "Done. The new packet below says what happened and what's next.",
                failText: "Stopped. The packet below says what happened.")
    }

    /// Runs a script with live output in the Hub; Stop sends SIGTERM (the scripts clean up and change nothing).
    func runLive(_ p: Project, kind: String = "", exe: String, args: [String], stdin: String, title: String, header: String, okText: String, failText: String) {
        guard running == nil else { return }
        let cwd = p.path
        running = title; output = header; runKind = kind; runStarted = Date(); lastOutputAt = Date()
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: exe); proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HEIMDALL_LAUNCHER")
        proc.environment = env
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        let inPipe = Pipe(); proc.standardInput = inPipe
        // report item 16: chunks go to the main queue in order, and "Done" waits for the pipe's real end
        let eof = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; eof.signal(); return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.lastOutputAt = Date()
                self.output += s; if self.output.count > 40_000 { self.output = String(self.output.suffix(30_000)) } } }
        }
        let start = Date()
        proc.terminationHandler = { pr in
            let code = pr.terminationStatus
            _ = eof.wait(timeout: .now() + 3)
            DispatchQueue.main.async { _ = MainActor.assumeIsolated { Task { @MainActor in
                self.output += "\n[exit \(code) · \(Int(Date().timeIntervalSince(start))) s] " + (code == 0 ? okText : failText)
                self.running = nil; self.runStarted = nil; self.runKind = nil
                self.healProc = nil
                var fresh = await Task.detached { Self.inspect(p.path) }.value
                fresh.containers = p.containers; fresh.alexusFolder = p.alexusFolder
                if let i = self.projects.firstIndex(where: { $0.path == p.path }) { self.projects[i] = fresh }   // looked up after the await
                self.loadHistory(p)
                if self.current?.path == p.path { self.loadPacket(p) }
            } } }
        }
        do {
            try proc.run(); healProc = proc
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(String(stdin.prefix(100_000)).utf8))
            try? inPipe.fileHandleForWriting.close()
        } catch { AppLog.error("hub-operation", error); output += "couldn't start: \(error.localizedDescription)"; running = nil }
    }

    /// Stop a running change: the script gets SIGTERM, cleans up its staging copy and changes nothing.
    func stopHeal() { if let p = healProc, p.isRunning { p.terminate(); output += "\n[stopping…]" } }

    /// This app's own repo (changed through heimdall-edit), matched by its real path, not by folder name.
    nonisolated static func isMainApp(_ p: Project) -> Bool {
        AppPaths.isHeimdallRepo(p.path)
    }

    // MARK: reinstall bundle (bin/ragnarok-bundle → ~/Ragnarok-Backups, private, never uploaded)

    func makeBundle() {
        guard running == nil else { return }
        running = "making a reinstall bundle"; output = "$ bin/ragnarok-bundle\n"
        let start = Date()
        Task {
            let (code, out) = await Task.detached { Self.run(AppPaths.repoBin("ragnarok-bundle"), [], timeout: 600) }.value
            output += out + "[exit \(code) · \(Int(Date().timeIntervalSince(start))) s]"
                + (code == 0 ? "\nTo reinstall: unpack it and run ./install.sh (README.txt inside lists what you still bring yourself)." : "")
            Receipts.write(provider: "hub", question: "make reinstall bundle", cwd: Self.home + "/Ragnarok-Backups", start: start, exit: code,
                           changed: [], claims: [], verdict: code == 0 ? "no-claims" : "failed")
            running = nil
            if code == 0 { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Self.home + "/Ragnarok-Backups")]) }
        }
    }

    // MARK: apps

    func refreshApps() {
        runningApps = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func isRunning(_ app: String) -> Bool { runningApps.contains(URL(fileURLWithPath: app).standardizedFileURL.path) }

    func quitApp(_ p: Project) {
        guard let a = p.app else { return }
        let path = URL(fileURLWithPath: a).standardizedFileURL.path
        guard path != Bundle.main.bundleURL.standardizedFileURL.path else { output = "That's this app; quit it from the menu."; return }
        for r in NSWorkspace.shared.runningApplications where r.bundleURL?.standardizedFileURL.path == path { r.terminate() }
        receipt(p, "quit \((a as NSString).lastPathComponent)", exit: 0, out: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshApps() }
    }

    // MARK: Alexus containers

    nonisolated static func safeName(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil }

    /// verb: start | stop | restart. Asks first: these change what runs on Alexus.
    func container(_ verb: String, _ names: [String], in p: Project) {
        guard running == nil, ["start", "stop", "restart"].contains(verb), !names.isEmpty, names.allSatisfy(Self.safeName) else { return }
        guard confirm("\(verb.capitalized) on Alexus?", names.joined(separator: "\n") + "\n\nRuns docker \(verb) as \(LocalConfig.current.alexusUser) on Alexus.") else { return }
        remote(p, "docker \(verb)", "docker \(verb) " + names.joined(separator: " "), refreshAfter: true)
    }

    /// Last 80 log lines of a container (read-only).
    func logs(_ name: String, in p: Project) {
        guard Self.safeName(name) else { return }
        remote(p, "logs \(name)", "docker logs --tail 80 \(name) 2>&1", refreshAfter: false)
    }

    private func remote(_ p: Project, _ label: String, _ cmd: String, refreshAfter: Bool) {
        guard running == nil else { return }
        running = "\(label) · \(p.label)"; output = "alexus$ \(cmd)\n"
        Task {
            let start = Date()
            let (code, out) = await Task.detached {
                Self.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", Self.sshTarget(), cmd], timeout: 120)
            }.value
            output += out.suffix(20_000) + "\n[exit \(code) · \(Int(Date().timeIntervalSince(start))) s]"
            if refreshAfter { receipt(p, "alexus: \(cmd)", exit: code, out: out, start: start) }
            running = nil
            if refreshAfter { refresh() }
        }
    }

    // MARK: services and background jobs

    func refreshServices() {
        servicesNote = "Checking…"
        Task {
            let (svc, jobs) = await Task.detached { (Self.mcpServers(), Self.launchJobs()) }.value
            services = svc; self.jobs = jobs
            let bad = svc.filter { $0.state == "fail" }.count, auth = svc.filter { $0.state == "auth" }.count
            servicesNote = svc.isEmpty ? "Couldn't read MCP servers" : "\(svc.count) MCP servers: \(svc.count - bad - auth) connected, \(bad) failing, \(auth) need sign-in"
        }
    }

    nonisolated static func mcpServers() -> [Service] {
        let (_, out) = run("/bin/zsh", ["-lc", "cd ~ && claude mcp list"], timeout: 60)
        return parseMCP(out)
    }

    /// Lines look like `name: target - ✔ Connected` (or ! Needs authentication, ✘ Failed to connect — why).
    nonisolated static func parseMCP(_ out: String) -> [Service] {
        out.split(separator: "\n").compactMap { raw in
            let l = String(raw)
            guard let dash = l.range(of: " - ", options: .backwards), let colon = l.range(of: ": "), colon.lowerBound < dash.lowerBound else { return nil }
            let status = String(l[dash.upperBound...])
            let state = status.hasPrefix("✔") ? "ok" : status.hasPrefix("!") ? "auth" : status.hasPrefix("✘") ? "fail" : ""
            guard !state.isEmpty else { return nil }
            let why = status.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
            return Service(name: String(l[..<colon.lowerBound]), target: String(l[colon.upperBound..<dash.lowerBound]), state: state,
                           detail: state == "ok" ? "connected" : state == "auth" ? "needs sign-in" : String((why.isEmpty ? status : why).prefix(90)))
        }
    }

    /// Every plist in ~/Library/LaunchAgents with its launchctl state.
    nonisolated static func launchJobs() -> [Job] {
        let labels = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/LaunchAgents")) ?? [])
            .filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) }.sorted()
        let (_, out) = run("/bin/launchctl", ["list"], timeout: 10)
        var state: [String: (String, String)] = [:]
        for l in out.split(separator: "\n") { let f = l.split(separator: "\t").map(String.init); if f.count == 3 { state[f[2]] = (f[0], f[1]) } }
        return labels.map { Job(label: $0, pid: state[$0].flatMap { $0.0 == "-" ? nil : $0.0 }, lastExit: state[$0]?.1) }
    }

    /// Start a background job now (launchctl kickstart). Asks first.
    func kick(_ j: Job) {
        guard running == nil, Self.safeName(j.label), j.loaded else { return }
        guard confirm("Run \(j.label) now?", "launchctl kickstart gui/\(getuid())/\(j.label), as Mac \(NSUserName()).") else { return }
        running = "run \(j.label)"; output = "$ launchctl kickstart gui/\(getuid())/\(j.label)\n"
        let start = Date()
        Task {
            let (code, out) = await Task.detached { Self.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(j.label)"], timeout: 30) }.value
            output += out + "[exit \(code)]"
            Receipts.write(provider: "hub", question: "job: kickstart \(j.label)", cwd: Self.home, start: start, exit: code,
                           changed: [], claims: [], verdict: code == 0 ? "no-claims" : "failed")
            running = nil; refreshServices()
        }
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "Do it"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// Everything that runs: MCP servers, Mac background jobs, and Alexus containers that aren't healthy.
struct ServicesView: View {
    @EnvironmentObject var hub: HubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Services").font(.title2.bold())
                    Spacer()
                    Button { hub.makeBundle() } label: { Label("Make reinstall bundle", systemImage: "archivebox") }
                        .disabled(hub.running != nil).help("Packs Ragnarok, its repos, apps and data into ~/Ragnarok-Backups (private; nothing is uploaded)")
                    Button { hub.refresh() } label: { Label("Check again", systemImage: "arrow.clockwise") }.disabled(hub.refreshing)
                }
                Text(hub.servicesNote).font(.caption).foregroundStyle(.secondary)
                block("MCP servers (what the AIs connect to)") {
                    ForEach(hub.services, id: \.self) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(s.state == "ok" ? .green : s.state == "auth" ? .gray : .red).frame(width: 7, height: 7)
                            Text(s.name).font(.caption.bold()).frame(width: 190, alignment: .leading)
                            Text(s.detail).font(.caption).foregroundStyle(s.state == "fail" ? .red : .secondary).lineLimit(2)
                        }
                    }
                }
                block("Mac background jobs (~/Library/LaunchAgents)") {
                    ForEach(hub.jobs, id: \.self) { j in
                        HStack(spacing: 6) {
                            Circle().fill(color(j)).frame(width: 7, height: 7)
                            Text(j.label).font(.caption.monospaced()).frame(width: 260, alignment: .leading)
                            Text(j.pid.map { "running (pid \($0))" } ?? (j.loaded ? "waiting · last exit \(j.lastExit ?? "?")" : "not loaded"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if j.loaded && j.pid == nil { Button("Run now") { hub.kick(j) }.controlSize(.small) }
                        }
                    }
                }
                let bad = hub.containers.filter { !$0.healthy }
                block("Alexus containers not healthy") {
                    if bad.isEmpty { Text("All \(hub.containers.count) are up.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(bad, id: \.self) { c in
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text(c.name).font(.caption.monospaced())
                            Text(c.status).font(.caption).foregroundStyle(.red)
                            Spacer()
                            if let p = hub.projects.first(where: { $0.containers.contains(c) }) {
                                Button("Show") { hub.selected = p.path }.controlSize(.small)
                            }
                        }
                    }
                }
                if hub.running != nil || !hub.output.isEmpty {
                    block(hub.running.map { "Running: \($0)" } ?? "Last action") {
                        Text(hub.output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ j: HubModel.Job) -> Color { j.pid != nil ? .green : !j.loaded ? .gray : j.lastExit == "0" ? .secondary : .orange }

    private func block<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(t.uppercased()).font(.caption.bold()).foregroundStyle(.secondary); c() }
    }
}
