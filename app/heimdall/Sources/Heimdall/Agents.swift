import AppKit
import LocalAuthentication
import SwiftUI

/// Agents tab: spawn a Claude Code, Grok, Muse or Codex agent with the owner's harness (bin/ragnarok-agent) and watch it work end to end.
/// The runner writes ~/.ragnarok/agents/<id>/state.json; this tab only reads those files (every second while visible),
/// so a run keeps going and stays visible across Ragnarok restarts. Older runs have no `who` and are Claude.
struct AgentRun: Decodable, Identifiable, Equatable {
    struct Step: Decodable, Equatable { var step: String?; var doing: String?; var status: String? }
    struct Action: Decodable, Equatable { var at: String?; var kind: String?; var tool: String?; var what: String?; var result: String? }
    /// One checklist line as Ragnarok ran it (proved mode). ok: true pass, false fail, nil = for the owner (HUMAN) or not run yet.
    struct Check: Decodable, Equatable { var claim: String?; var cmd: String?; var ok: Bool?; var out: String?; var human: Bool?; var restored: String?; var added: Bool? }
    struct Critic: Decodable, Equatable { var verdict: String?; var refuted: [String]?; var text: String? }
    struct Handoff: Decodable, Equatable { var from: String?; var to: String?; var at: String?; var reason: String?; var tools: Int?; var session: String?; var summary: String? }
    struct HumanReply: Decodable, Equatable { var at: String?; var request: String?; var reply: String?; var approved: Bool? }
    var id: String
    var name: String?
    var task: String?
    var cwd: String?
    var room_task_id: String?
    var who: String?
    var started_who: String?
    var handoff_chain: [String]?
    var handoffs: [Handoff]?
    var handoff_from: String?
    var handed_off_to: String?
    var human_request: String?
    var human_approved: Bool?
    var human_replies: [HumanReply]?
    var provider: String?
    var mode: String?
    var phase: String?
    var verdict: String?
    var verdict_note: String?
    var checks: [Check]?
    var critic: Critic?
    var model: String?
    var status: String?
    var started: String?
    var ended: String?
    var now: String?
    var plan: [Step]?
    var actions: [Action]?
    var tools: Int?
    var errors: Int?
    var hook_blocks: Int?
    var remark: String?
    var final: String?
    var cost_usd: Double?
    var turns: Int?
    var session: String?
    var pid: Int?

    var isLive: Bool { (status == "running" || status == "starting") || pid != nil }
    var agent: String { who ?? (id.hasPrefix("agent-") ? "Unverified" : "claude") }
    var routeLabel: String {
        guard let hs = handoffs, !hs.isEmpty else { return agent }
        var r = [started_who ?? hs.first?.from ?? agent]
        for h in hs {
            if let to = h.to, to != r.last { r.append(to) }
        }
        return r.joined(separator: " → ")
    }
    var planDone: Int { plan?.filter { $0.status == "completed" }.count ?? 0 }
    var currentStep: Step? { plan?.first { $0.status == "in_progress" } }
    var needsHuman: Bool {
        if isLive { return false }
        if verdict == "needs you" { return true }
        if let req = human_request, !req.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }
    var humanPromptText: String? {
        if let req = human_request, !req.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return req }
        if verdict == "needs you", let note = verdict_note, !note.isEmpty { return note }
        return nil
    }

    nonisolated static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f
    }()
    /// Runner IDs are dated; debugger IDs are random. Sort observations before
    /// limiting the list so older debugger runs cannot crowd out recent work.
    static func latest(in directory: String, limit: Int = 50) -> [AgentRun] {
        let fm = FileManager.default
        let ids = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") }
        let dated: [(AgentRun, Date)] = ids.compactMap { id in
            let path = directory + "/" + id + "/state.json"
            guard let data = fm.contents(atPath: path),
                  let run = try? JSONDecoder().decode(AgentRun.self, from: data), !run.id.isEmpty else { return nil }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            return (run, run.started.flatMap(Self.stamp.date(from:)) ?? modified ?? .distantPast)
        }
        return dated.sorted {
            $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 > $1.1
        }.prefix(max(0, limit)).map { $0.0 }
    }
    func elapsed(at now: Date = Date()) -> String {
        guard let s = started.flatMap(Self.stamp.date(from:)) else { return "" }
        let e = ended.flatMap(Self.stamp.date(from:)) ?? now
        let t = max(0, Int(e.timeIntervalSince(s)))
        return t >= 3600 ? "\(t / 3600)h \(t % 3600 / 60)m" : t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }

    var webURL: URL? {
        let text = [final, remark, now].compactMap { $0 }.joined(separator: "\n")
        if let match = text.range(of: #"https?://(127\.0\.0\.1|localhost|[0-9a-zA-Z.-]+)(:[0-9]+)?(/[^\s\)\]<\"']*)?"#, options: .regularExpression) {
            var raw = String(text[match])
            while raw.hasSuffix(".") || raw.hasSuffix(",") || raw.hasSuffix(":") || raw.hasSuffix(";") {
                raw.removeLast()
            }
            return URL(string: raw)
        }
        return nil
    }

    var hasHardwareGate: Bool {
        let text = [final, remark, now, task].compactMap { $0 }.joined(separator: "\n").lowercased()
        if text.contains("unlock.sh") || text.contains("touch id") || text.contains("yubikey") ||
           text.contains("secure enclave") || text.contains("boot-locked") || text.contains("boot-lock") ||
           text.contains("platform_unlock") || text.contains("hardware presence") {
            return true
        }
        return false
    }
}

@MainActor
/// The chat step's answer (bin/ragnarok-plan): what the planner understood, and the checklist the work will be judged by.
/// steps[].ok is the check run once BEFORE any work: true means it already passes, so it proves nothing about the work.
struct AgentPlan: Decodable, Equatable {
    var ok: Bool?
    var error: String?
    var session: String?
    var understood: String?
    var will: String?
    var wont: String?
    var checklist: String?
    var steps: [AgentRun.Check]?
    var cost_usd: Double?
}

final class AgentStore: ObservableObject {
    static let shared = AgentStore()
    @Published var runs: [AgentRun] = []
    @Published var selected: String?
    @Published var message = ""
    nonisolated static let dir = ("~/.ragnarok/agents" as NSString).expandingTildeInPath
    nonisolated static let tool = AppPaths.bundledBin("ragnarok-agent")
    nonisolated static let planner = AppPaths.bundledBin("ragnarok-plan")

    /// Asks the planner (read-only, takes a minute or so). Off the main thread; returns the parsed plan.
    nonisolated static func plan(_ text: String, cwd: String, model: String?, session: String?) async -> AgentPlan {
        await Task.detached {
            var args = [session == nil ? "new" : "revise", "--cwd", cwd]
            if let session { args += ["--session", session] }
            if let model, !model.isEmpty { args += ["--model", model] }
            args.append("-")
            let p = Process(), out = Pipe(), err = Pipe(), inp = Pipe()
            p.executableURL = URL(fileURLWithPath: planner); p.arguments = args
            p.standardOutput = out; p.standardError = err; p.standardInput = inp
            do {
                try p.run()
                inp.fileHandleForWriting.write(Data(text.utf8)); try? inp.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let plan = try? JSONDecoder().decode(AgentPlan.self, from: data) { return plan }
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return AgentPlan(ok: false, error: e.isEmpty ? "the planner gave no answer" : String(e.suffix(600)))
            } catch {
                AppLog.error("agent-planner", error)
                return AgentPlan(ok: false, error: "could not run the planner: \(error.localizedDescription)")
            }
        }.value
    }
    private var timer: Timer?

    func watch() {
        reload()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
    func unwatch() { timer?.invalidate(); timer = nil }

    func reload() {
        let out = AgentRun.latest(in: Self.dir)
        if out != runs { runs = out }
        if selected == nil { selected = runs.first?.id }
    }

    /// Starts a run through the runner (which detaches the agent) and selects it.
    @discardableResult
    func start(task: String, cwd: String, provider: String? = nil, model: String?, who: String, prove: Bool = true,
               autoHandoff: Bool = true, checklist: String? = nil, roomTaskID: String? = nil) -> String? {
        var args = ["start", "--who", who, "--cwd", cwd]
        if let provider, !provider.isEmpty { args += ["--provider", provider] }
        if let roomTaskID { args += ["--room-task", roomTaskID] }
        if !prove { args.append("--plain") }
        if !autoHandoff { args.append("--no-handoff") }
        if let checklist {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("ragnarok-checklist-\(UUID().uuidString).md")
            do { try checklist.write(to: f, atomically: true, encoding: .utf8) } catch { AppLog.error("agent-checklist", error); message = "could not save the checklist: \(error.localizedDescription)"; return nil }
            args += ["--checklist", f.path]
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        args.append("-")
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: Self.tool); p.arguments = args
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        do {
            try p.run()
            inp.fileHandleForWriting.write(Data(task.utf8)); try? inp.fileHandleForWriting.close()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 { selected = text; message = "" } else { message = text }
            reload()
            return p.terminationStatus == 0 ? text : nil
        } catch { AppLog.error("agent-runner", error); message = "could not start the agent runner: \(error.localizedDescription)" }
        reload()
        return nil
    }

    /// Hands off a run (with its task, plan, checklist, and prior actions) to another provider.
    @discardableResult
    func handoff(_ r: AgentRun, to who: String? = nil) -> String? {
        var args = ["handoff", r.id]
        if let who, !who.isEmpty { args += ["--who", who] }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: Self.tool); p.arguments = args
        p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
            let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
            let newID = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if p.terminationStatus == 0, !newID.isEmpty { selected = newID; message = "" } else { message = lines.joined(separator: "\n") }
            reload()
            return p.terminationStatus == 0 ? newID : nil
        } catch {
            AppLog.error("agent-handoff", error)
            message = "could not hand off the agent run: \(error.localizedDescription)"
        }
        reload()
        return nil
    }

    func stop(_ id: String, force: Bool = false) {
        var args = ["stop"]
        if force { args.append("--force") }
        args.append(id)
        let p = Process(); p.executableURL = URL(fileURLWithPath: Self.tool); p.arguments = args
        try? p.run(); p.waitUntilExit(); reload()
    }

    func forceStop(_ id: String) {
        stop(id, force: true)
    }

    /// Sends the owner's answer, context, or approval back to the runner and resumes the run in the background.
    @discardableResult
    func resumeRun(_ r: AgentRun, reply: String, who: String? = nil, approveHuman: Bool = true) -> Bool {
        var args = ["resume", r.id]
        if let who, !who.isEmpty { args += ["--who", who] }
        args.append(approveHuman ? "--approve-human" : "--no-approve-human")
        args.append("-")
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: Self.tool); p.arguments = args
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        do {
            try p.run()
            let payload = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            inp.fileHandleForWriting.write(Data((payload.isEmpty ? "Approved and ready; continue and finish the task." : payload).utf8))
            try? inp.fileHandleForWriting.close()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 {
                selected = r.id
                message = ""
                reload()
                return true
            } else {
                message = text
            }
        } catch {
            AppLog.error("agent-resume", error)
            message = "could not resume the agent run: \(error.localizedDescription)"
        }
        reload()
        return false
    }

    /// Opens the agent's conversation in Terminal (claude --resume) so the owner can talk to it or take over.
    func resume(_ r: AgentRun) {
        guard let s = r.session, let cwd = r.cwd else { return }
        let q = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd: String
        switch r.agent {
        case "grok": cmd = "cd \(q(cwd)) && grok --resume \(q(s))"
        case "codex":
            guard let prompt = r.task, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = "This run has no saved task prompt to resume in Terminal."
                return
            }
            cmd = "cd \(q(cwd)) && codex exec resume \(q(s)) \(q(prompt))"
        case "muse": cmd = "cd \(q(cwd)) && muse exec resume \(q(s))"
        default: cmd = "cd \(q(cwd)) && claude --resume \(q(s))"
        }
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        o.arguments = ["-e", "tell application \"Terminal\" to activate", "-e", "tell application \"Terminal\" to do script \"\(esc)\""]
        try? o.run()
    }
}

struct AgentsView: View {
    @StateObject private var store = AgentStore.shared
    @State private var showNew = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Agents").font(.headline)
                    Spacer()
                    Button { showNew = true } label: { Label("New agent", systemImage: "plus") }
                }.padding(8)
                Divider()
                List(selection: $store.selected) {
                    ForEach(store.runs) { r in AgentRow(run: r).tag(r.id) }
                }
                if store.runs.isEmpty {
                    Text("No runs yet. Press New agent, describe the job, pick a folder.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            Group {
                if let r = store.runs.first(where: { $0.id == store.selected }) {
                    AgentDetail(run: r, store: store)
                } else {
                    Text("Pick a run, or start a new agent.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.watch() }
        .onDisappear { store.unwatch() }
        .sheet(isPresented: $showNew) { NewAgentSheet(store: store, shown: $showNew) }
    }
}

/// What the row and header say: the proof outcome when there is one, else the run status.
private func outcome(_ r: AgentRun) -> String { r.isLive ? (r.phase.map { "running · \($0)" } ?? r.status ?? "?") : (r.verdict ?? r.status ?? "?") }
private func outcomeColor(_ r: AgentRun) -> Color {
    switch r.verdict { case "proved": .green; case "needs you": .orange; case "dead end": .red; default: statusColor(r.status) }
}

private func statusColor(_ s: String?) -> Color {
    switch s { case "running", "starting": .blue; case "done": .green; case "failed": .red; case "stopped": .orange; default: .secondary }
}

struct AgentRow: View {
    let run: AgentRun
    private static let handoffProviders = [("claude", "Claude"), ("codex", "Codex"), ("grok", "Grok")]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(outcomeColor(run)).frame(width: 8, height: 8)
                Text(run.name ?? run.id).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(run.routeLabel)
                Text(outcome(run))
                if run.hasHardwareGate {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                        .help("Hardware presence gate / stopper")
                }
                if let p = run.plan, !p.isEmpty { Text("step \(min(run.planDone + (run.isLive ? 1 : 0), p.count)) of \(p.count)") }
                Text("\(run.tools ?? 0) tools")
                TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(run.elapsed(at: ctx.date)) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 2)
        .contextMenu {
            if run.isLive {
                Button("Stop") { AgentStore.shared.stop(run.id) }
                Button("Force Stop", role: .destructive) { AgentStore.shared.forceStop(run.id) }
            }
            Menu("Hand off to…") {
                ForEach(Self.handoffProviders.filter { $0.0 != run.agent }, id: \.0) { tag, label in
                    Button(label) { AgentStore.shared.handoff(run, to: tag) }
                }
            }
        }
    }
}

struct AgentDetail: View {
    let run: AgentRun
    @ObservedObject var store: AgentStore
    private static let handoffProviders = [("claude", "Claude"), ("codex", "Codex"), ("grok", "Grok")]

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        if let fromID = run.handoff_from {
                            Button { store.selected = fromID } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                            .controlSize(.small)
                            .help("Back to previous run \(fromID)")
                        }
                        Text(run.name ?? run.id).font(.title3.bold()).lineLimit(2)
                        Text(run.routeLabel).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Text(outcome(run)).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(outcomeColor(run).opacity(0.2), in: Capsule())
                        if run.hasHardwareGate {
                            Label("Hardware Gate", systemImage: "shield.lefthalf.filled")
                                .font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        if let url = run.webURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open in Browser", systemImage: "globe")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Open \(url.absoluteString) in your default browser")
                        }
                        if run.isLive {
                            Button("Stop") { store.stop(run.id) }
                            Button("Force Stop", role: .destructive) { store.forceStop(run.id) }
                                .help("Forcefully terminates the agent process immediately (SIGKILL)")
                        }
                        Menu {
                            ForEach(Self.handoffProviders.filter { $0.0 != run.agent }, id: \.0) { tag, label in
                                Button("Hand off to \(label)") { store.handoff(run, to: tag) }
                            }
                        } label: {
                            Label("Hand off", systemImage: "arrow.triangle.swap")
                        }
                        .help("Hand off this task, plan, and prior actions to another AI provider")
                        Button("Resume in Terminal") { store.resume(run) }.disabled(run.session == nil)
                            .help(run.agent == "codex"
                                  ? "Resumes this Codex conversation with the original agent task as its prompt"
                                  : "Opens this conversation with \(run.agent)'s resume command")
                        Button("Open folder") { if let c = run.cwd { NSWorkspace.shared.open(URL(fileURLWithPath: c)) } }
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("agent-detail-top", anchor: .top)
                            }
                        } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .help("Scroll back to the top of this run")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            if let taskID = run.room_task_id { Label("Room task \(taskID)", systemImage: "person.3") }
                            if let fromID = run.handoff_from {
                                Button { store.selected = fromID } label: {
                                    Label("From \(fromID)", systemImage: "arrow.uturn.backward")
                                }.buttonStyle(.plain).foregroundStyle(.blue)
                            }
                            if let toID = run.handed_off_to {
                                Button { store.selected = toID } label: {
                                    Label("Continued in \(toID)", systemImage: "arrow.right.circle")
                                }.buttonStyle(.plain).foregroundStyle(.blue)
                            }
                            Label((run.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in Label(run.elapsed(at: ctx.date), systemImage: "clock") }
                            Label("\(run.tools ?? 0) tool calls", systemImage: "hammer")
                            if (run.errors ?? 0) > 0 { Label("\(run.errors!) errors", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if (run.hook_blocks ?? 0) > 0 { Label("📯 \(run.hook_blocks!) Gjallarhorn / hook checks", systemImage: "checkmark.shield").foregroundStyle(.orange) }
                            if let c = run.cost_usd { Label(String(format: "$%.2f", c), systemImage: "dollarsign.circle") }
                            if let p = run.provider, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary) }
                            if let m = run.model { Text(m).foregroundStyle(.secondary) }
                            if let chain = run.handoff_chain, !chain.isEmpty {
                                Label("Fallback: " + chain.joined(separator: " → "), systemImage: "arrow.triangle.swap")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Color.clear.frame(height: 0).id("agent-detail-top")

                        if let handoffs = run.handoffs, !handoffs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label("Provider Handoffs (\(handoffs.count))", systemImage: "arrow.triangle.swap")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(run.routeLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                ForEach(Array(handoffs.enumerated()), id: \.offset) { _, h in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("\(h.from ?? "?") → \(h.to ?? "?")").font(.caption.bold())
                                            if let t = h.tools { Text("(\(t) tools)").font(.caption2).foregroundStyle(.secondary) }
                                            if let r = h.reason, !r.isEmpty {
                                                Text("· " + r).font(.caption).foregroundStyle(.orange).lineLimit(1)
                                            }
                                        }
                                        if let s = h.summary, !s.isEmpty {
                                            Text(s).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                            }
                            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // where it is and what it's doing
                        HStack(spacing: 8) {
                            if run.isLive { ProgressView().controlSize(.small) }
                            Text(run.isLive ? "Now: \(run.currentStep?.doing ?? run.now ?? "")" : (run.now ?? ""))
                                .font(.callout.weight(.medium)).lineLimit(3).textSelection(.enabled)
                        }
                        if run.isLive, let n = run.now, let d = run.currentStep?.doing, n != d {
                            Text(n).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }

                        if let plan = run.plan, !plan.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Plan").font(.subheadline.bold())
                                    Text("\(run.planDone) of \(plan.count) done").font(.caption).foregroundStyle(.secondary)
                                }
                                ProgressView(value: Double(run.planDone), total: Double(max(plan.count, 1)))
                                ForEach(Array(plan.enumerated()), id: \.offset) { _, s in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: s.status == "completed" ? "checkmark.circle.fill"
                                              : s.status == "in_progress" ? "arrowtriangle.right.circle.fill"
                                              : s.status == "left" ? "exclamationmark.circle.fill" : "circle")
                                            .foregroundStyle(s.status == "completed" ? .green : s.status == "in_progress" ? .blue
                                                             : s.status == "left" ? .orange : .secondary)
                                        Text(s.step ?? "").strikethrough(s.status == "completed", color: .secondary)
                                            .foregroundStyle(s.status == "completed" ? .secondary : .primary)
                                    }.font(.callout)
                                }
                            }
                            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }

                        if let note = run.verdict_note, !run.isLive {
                            Label(note, systemImage: run.verdict == "proved" ? "checkmark.seal.fill" : run.verdict == "needs you" ? "person.fill.questionmark" : "xmark.octagon.fill")
                                .font(.callout).foregroundStyle(outcomeColor(run)).textSelection(.enabled)
                        }
                        if let checks = run.checks, !checks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Proof").font(.subheadline.bold())
                                    Text("\(checks.filter { $0.ok == true }.count) of \(checks.filter { $0.human != true }.count) checks pass, run by Ragnarok")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Image(systemName: c.human == true ? "person.circle" : c.ok == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundStyle(c.human == true ? .orange : c.ok == true ? .green : .red)
                                            Text(c.claim ?? "").font(.callout)
                                            if let r = c.restored { Text(r).font(.caption2).foregroundStyle(.orange) }
                                        }
                                        Text(c.human == true ? "for you to judge" : (c.cmd ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                        if c.ok == false, let o = c.out { Text(o).font(.caption.monospaced()).foregroundStyle(.red).lineLimit(2) }
                                    }.help(c.out ?? "")
                                }
                                if let cr = run.critic {
                                    Divider()
                                    HStack(spacing: 6) {
                                        Image(systemName: cr.verdict == "pass" ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                            .foregroundStyle(cr.verdict == "pass" ? .green : .red)
                                        Text("Critic: \(cr.verdict ?? "no verdict")").font(.callout.bold())
                                    }
                                    ForEach(cr.refuted ?? [], id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.red) }
                                }
                            }
                            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }

                        Text("Activity").font(.subheadline.bold())
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array((run.actions ?? []).reversed().enumerated()), id: \.offset) { _, a in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(String((a.at ?? "").dropFirst(11).prefix(8))).foregroundStyle(.tertiary)
                                        Image(systemName: icon(a)).foregroundStyle(a.result == "error" ? .red : a.kind == "hook" ? .orange : .secondary)
                                        Text(a.what ?? "").lineLimit(a.kind == "said" ? 3 : 1)
                                            .foregroundStyle(a.kind == "said" ? .primary : .secondary)
                                    }.font(.caption.monospaced())
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 110, maxHeight: 220)
                        .padding(8)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                        if !run.isLive {
                            AgentHumanInterventionCard(run: run, store: store)
                        }

                        if run.hasHardwareGate {
                            AgentHardwareGateCard(run: run)
                        }

                        if let url = run.webURL, !run.isLive {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Web App Ready").font(.headline)
                                    Text(url.absoluteString).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Open in Browser", systemImage: "arrow.up.right")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(10)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.25), lineWidth: 1))
                        }

                        if let f = run.final, !f.isEmpty, !run.isLive {
                            Text("Result").font(.subheadline.bold())
                            ScrollView { Text(f).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 240).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("Task: \(run.task ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: run.id) { _, _ in
                proxy.scrollTo("agent-detail-top", anchor: .top)
            }
        }
    }

    private func icon(_ a: AgentRun.Action) -> String {
        switch a.kind {
        case "said": return "text.bubble"
        case "hook": return "checkmark.shield"
        case "human": return "person.crop.circle.badge.checkmark"
        case "system": return "gearshape"
        case "critic": return "magnifyingglass"
        case "handoff": return "arrow.triangle.swap"
        default:
            switch a.tool {
            case "Read", "Glob", "Grep", "read_file", "grep", "list_dir",
                 "view_file", "grep_search", "find_by_name": return "doc.text.magnifyingglass"
            case "Edit", "MultiEdit", "Write", "NotebookEdit", "search_replace", "write",
                 "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file": return "pencil"
            case "Bash", "run_terminal_command", "run_terminal_cmd", "run_command": return "terminal"
            case "WebSearch", "WebFetch", "web_search", "web_fetch", "open_page",
                 "search_web", "read_url_content": return "globe"
            case "TodoWrite", "todo_write", "TaskCreate", "TaskUpdate": return "checklist"
            default: return "wrench"
            }
        }
    }
}

/// New agent = chat first, then do. The owner says what they want; the planner says it back with the checklist the work
/// will be judged by; they change it in plain words until it's right; Approve starts the agent with that checklist
/// frozen, so the agent only does the work and Ragnarok runs the checks. "Start without a plan" is the old way.
struct NewAgentSheet: View {
    @ObservedObject var store: AgentStore
    @Binding var shown: Bool
    var roomTask: RoomTaskAssignment? = nil
    var onStarted: ((String, String) -> Void)? = nil
    @StateObject private var codexModels = CodexModelLoader()
    @StateObject private var localModels = LocalModelLoader()
    @State private var selectedProvider = "anthropic"
    @State private var task = ""
    @State private var cwd = AppPaths.defaultWorkFolder
    @State private var model = ""
    @State private var who = "claude"
    @State private var prove = true
    @State private var autoHandoff = true
    @State private var plan: AgentPlan?
    @State private var asks: [String] = []          // what the owner said, in order (first = the task)
    @State private var reply = ""
    @State private var thinking = false
    @State private var checklist = ""               // the agreed checklist; the owner may edit it by hand too

    private var providersForCurrentAI: [(tag: String, label: String)] {
        switch who {
        case "claude":
            return [("anthropic", "Anthropic"), ("bedrock", "AWS Bedrock"), ("vertex", "Google Vertex AI"), ("foundry", "Microsoft Foundry")]
        case "grok":
            return [("xai", "xAI"), ("custom", "Custom / Gateway")]
        case "codex":
            return [("openai", "OpenAI"), ("alexus", "Alexus (Ollama)"), ("ollama", "Ollama (Local)"), ("lmstudio", "LM Studio (Local)")]
        default:
            return [("", "Default")]
        }
    }

    private var models: [(tag: String, label: String)] {
        switch who {
        case "claude":
            return [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        case "grok":
            return [("", "Default"), ("grok-4.7", "Grok 4.7"), ("grok-4.7-build-fast", "Grok 4.7 fast"), ("grok-4.6", "Grok 4.6"), ("grok-4.5", "Grok 4.5")]
        case "codex":
            if selectedProvider == "alexus" {
                let list = localModels.alexusModels.isEmpty ? LocalModelLoader.fallbackAlexus : localModels.alexusModels
                return [("", "Default (Qwen 2.5 Coder 7B)")] + list.map { ($0.slug, $0.label) }
            } else if selectedProvider == "ollama" {
                let list = localModels.localOllamaModels.isEmpty ? LocalModelLoader.fallbackOllama : localModels.localOllamaModels
                return [("", "Default")] + list.map { ($0.slug, $0.label) }
            } else if selectedProvider == "lmstudio" {
                let list = localModels.lmStudioModels.isEmpty ? LocalModelLoader.fallbackLMStudio : localModels.lmStudioModels
                return [("", "Default (Active Model)")] + list.filter { !$0.slug.isEmpty }.map { ($0.slug, $0.label) }
            } else {
                return [("", "Default")] + codexModels.models.map { ($0.slug, $0.label) }
            }
        default:
            return [("", "Default")]
        }
    }
    private var folder: String { (cwd as NSString).expandingTildeInPath }
    private var blank: Bool { task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New agent").font(.headline)
            if plan == nil && !thinking { setup } else { chat }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.red) }
        }
        .padding(16).frame(width: 620)
        .onAppear {
            if let roomTask, task.isEmpty {
                task = roomTask.text
                cwd = AppPaths.defaultWorkFolder
            }
            if who == "codex" && selectedProvider == "alexus" && localModels.alexusModels.isEmpty {
                localModels.refreshAlexus()
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(who == "grok"
                 ? "Runs Grok unattended in that folder. It approves its own tool calls, does not stop for a plan, and still loads your Claude hooks."
                 : who == "codex"
                    ? "Runs Codex in that folder with workspace-write sandboxing and automatic review for approval requests."
                    : who == "muse"
                        ? "Runs Muse unattended in that folder."
                 : "Say what you want. A planner says it back with the checks the work will be judged by; you fix it in plain words, then approve. The agent then only does the work, and Ragnarok runs the checks.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("AI", selection: $who) {
                Text("Claude").tag("claude")
                Text("Grok").tag("grok")
                Text("Codex (ChatGPT)").tag("codex")
            }
            .pickerStyle(.segmented)
            .onChange(of: who) { _, w in
                selectedProvider = providersForCurrentAI.first?.tag ?? ""
                model = ""
                if w == "codex" {
                    if codexModels.models.isEmpty { codexModels.refresh() }
                    if selectedProvider == "alexus" && localModels.alexusModels.isEmpty { localModels.refreshAlexus() }
                }
            }
            Text("What should it do?").font(.subheadline)
            TextEditor(text: $task).font(.body).frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("Folder")
                TextField("folder", text: $cwd).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = URL(fileURLWithPath: cwd)
                    if p.runModal() == .OK, let u = p.url { cwd = u.path }
                }
            }
            HStack(spacing: 16) {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(providersForCurrentAI, id: \.tag) { Text($0.label).tag($0.tag) }
                }
                .frame(maxWidth: 240)
                .onChange(of: selectedProvider) { _, p in
                    model = models.first?.tag ?? ""
                    if who == "codex" {
                        localModels.refresh(provider: p)
                    }
                }

                Picker("Model", selection: $model) {
                    ForEach(models, id: \.tag) { Text($0.label).tag($0.tag) }
                }.frame(maxWidth: 320)
            }
            if who == "codex" {
                HStack(spacing: 8) {
                    if selectedProvider == "alexus" {
                        Button(localModels.isLoading ? "Loading…" : localModels.alexusModels.isEmpty ? "Load Alexus models" : "Refresh Alexus models") {
                            localModels.refreshAlexus()
                        }.disabled(localModels.isLoading)
                        Text(localModels.status.isEmpty ? "Models loaded from Alexus Ollama API." : localModels.status)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if selectedProvider == "ollama" {
                        Button(localModels.isLoading ? "Loading…" : "Refresh local models") {
                            localModels.refreshLocalOllama()
                        }.disabled(localModels.isLoading)
                        Text(localModels.status.isEmpty ? "Local models via Ollama on this Mac." : localModels.status)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if selectedProvider == "lmstudio" {
                        Button(localModels.isLoading ? "Loading…" : "Refresh LM Studio") {
                            localModels.refreshLMStudio()
                        }.disabled(localModels.isLoading)
                        Text(localModels.status.isEmpty ? "Models from local LM Studio server or disk." : localModels.status)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Button(codexModels.isLoading ? "Loading…" : codexModels.models.isEmpty ? "Load Codex models" : "Refresh Codex models") {
                            codexModels.refresh()
                        }.disabled(codexModels.isLoading)
                        Text(codexModels.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack {
                // Same button on every AI. Plan it stays on Claude: the planner is claude -p.
                // Return starts Grok or Codex here. On Claude, Return is Plan it.
                if who == "claude" {
                    Button("Start without a plan") { launch(prove: prove) }
                        .disabled(blank)
                        .help("Skips the planner. Prove it on: the agent writes the checks and Ragnarok runs them.")
                } else {
                    Button("Start without a plan") { launch(prove: prove) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(blank)
                        .help("Skips the planner. Prove it on: the agent writes the checks and Ragnarok runs them.")
                }
                Toggle("Prove it", isOn: $prove).font(.caption).toggleStyle(.checkbox)
                Toggle("Auto-handoff across providers", isOn: $autoHandoff).font(.caption).toggleStyle(.checkbox)
                    .help("If this provider fails, hits quota, or leaves unfinished steps, automatically hand off to the next provider")
                Spacer()
                Button("Cancel") { shown = false }.keyboardShortcut(.cancelAction)
                if who == "claude" {
                    Button("Plan it") { ask(task) }.keyboardShortcut(.defaultAction).disabled(blank)
                }
            }
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(asks.enumerated()), id: \.offset) { i, a in
                        Text((i == 0 ? "You: " : "You (change): ") + a).font(.callout)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if thinking {
                        HStack { ProgressView().controlSize(.small); Text("The planner is looking around and writing the checks…").font(.caption) }
                    } else if let p = plan {
                        if p.ok == true {
                            VStack(alignment: .leading, spacing: 4) {
                                if let u = p.understood, !u.isEmpty { Text("Understood: ").bold() + Text(u) }
                                if let w = p.will, !w.isEmpty { Text("Will: ").bold() + Text(w) }
                                if let w = p.wont, !w.isEmpty { Text("Won't: ").bold() + Text(w) }
                            }.font(.callout)
                            Text("Done means every check passes:").font(.subheadline.bold())
                            ForEach(Array((p.steps ?? []).enumerated()), id: \.offset) { _, c in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: c.human == true ? "person.circle" : c.ok == true ? "exclamationmark.triangle.fill" : "circle")
                                            .foregroundStyle(c.human == true ? .orange : c.ok == true ? .orange : .secondary)
                                        Text(c.claim ?? "").font(.callout)
                                        if c.ok == true { Text("already true, proves nothing").font(.caption2).foregroundStyle(.orange) }
                                    }
                                    Text(c.human == true ? "you judge this one" : (c.cmd ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            DisclosureGroup("Edit the checklist by hand") {
                                TextEditor(text: $checklist).font(.caption.monospaced()).frame(minHeight: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            }.font(.caption)
                        } else {
                            Text(p.error ?? "the planner failed").font(.callout).foregroundStyle(.red)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 260, maxHeight: 460)
            HStack {
                TextField("Change something… (e.g. \"also put it on the Desktop\")", text: $reply).textFieldStyle(.roundedBorder)
                    .onSubmit { revise() }
                Button("Revise") { revise() }.disabled(thinking || reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Back") { plan = nil; asks = []; checklist = "" }.disabled(thinking)
                if let c = plan?.cost_usd { Text(String(format: "planning so far: $%.2f", c)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { shown = false }.keyboardShortcut(.cancelAction)
                Button("Approve and start") {
                    let brief = asks.count > 1 ? asks[0] + "\n\n\(LocalConfig.owner) then added:\n" + asks.dropFirst().map { "- " + $0 }.joined(separator: "\n") : asks[0]
                    launch(prove: true, checklist: checklist, taskText: brief)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(thinking || plan?.ok != true || checklist.isEmpty)
            }
        }
    }

    private func ask(_ text: String) {
        asks = [text]; thinking = true; plan = nil
        let (cwd, model) = (folder, model)
        Task { @MainActor in
            let p = await AgentStore.plan(text, cwd: cwd, model: model.isEmpty ? nil : model, session: nil)
            plan = p; checklist = p.checklist ?? ""; thinking = false
        }
    }

    private func revise() {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !thinking else { return }
        asks.append(r); reply = ""; thinking = true
        let (cwd, model, session, before) = (folder, model, plan?.session, plan?.cost_usd ?? 0)
        Task { @MainActor in
            var p = await AgentStore.plan(r, cwd: cwd, model: model.isEmpty ? nil : model, session: session)
            p.cost_usd = before + (p.cost_usd ?? 0)
            if p.session == nil { p.session = session }
            plan = p; if p.ok == true { checklist = p.checklist ?? checklist }; thinking = false
        }
    }

    private func launch(prove: Bool, checklist: String? = nil, taskText: String? = nil) {
        let base = taskText ?? task
        let prompt: String
        if let roomTask {
            prompt = "Shared Room task \(roomTask.id) (posted by \(roomTask.by)):\n\n\(base)\n\nWork on this task and leave the shared Room task open until \(LocalConfig.owner) marks the result done."
        } else { prompt = base }
        guard let runID = store.start(task: prompt, cwd: folder, provider: selectedProvider.isEmpty ? nil : selectedProvider,
                                      model: model.isEmpty ? nil : model,
                                      who: who, prove: prove, autoHandoff: autoHandoff, checklist: checklist, roomTaskID: roomTask?.id) else { return }
        if roomTask != nil { onStarted?(runID, who) }
        shown = false
    }
}

/// Human helper intervention card: when an agent pauses with a question, context request, or `verify: HUMAN` check
/// (or after any run completes), lets the owner answer the question / add context and resume the tracked run in-place.
struct AgentHumanInterventionCard: View {
    let run: AgentRun
    @ObservedObject var store: AgentStore
    @State private var replyText = ""
    @State private var resumeWho = ""
    @State private var expanded = false
    private static let providers = [("", "Same Provider"), ("claude", "Claude"), ("codex", "Codex"), ("grok", "Grok")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if run.needsHuman || expanded {
                HStack(spacing: 8) {
                    Image(systemName: run.needsHuman ? "person.fill.questionmark" : "arrow.uturn.forward.circle.fill")
                        .font(.title3)
                        .foregroundStyle(run.needsHuman ? .orange : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(run.needsHuman ? "Human Helper Intervention Needed" : "Add Context & Resume Run")
                                .font(.headline)
                            if run.needsHuman {
                                Text("Waiting on You")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                            }
                        }
                        if let req = run.humanPromptText {
                            Text(req)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        } else {
                            Text("Answer a question, provide extra context, or instruct the agent what to do next.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !run.needsHuman {
                        Button("Hide") { expanded = false }.buttonStyle(.borderless).font(.caption)
                    }
                }

                if let replies = run.human_replies, !replies.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(replies.enumerated()), id: \.offset) { _, hr in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                                Text("You: \(hr.reply ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(run.needsHuman ? "Answer question, provide context, or note what you did…" : "Provide follow-up context or instructions to resume…",
                              text: $replyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitResume() }

                    Picker("", selection: $resumeWho) {
                        ForEach(Self.providers, id: \.0) { tag, label in
                            Text(tag.isEmpty ? "Resume (\(run.agent))" : "Resume on \(label)").tag(tag)
                        }
                    }
                    .frame(width: 165)

                    Button {
                        submitResume()
                    } label: {
                        Label(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && run.needsHuman
                              ? "Approve & Resume" : "Send & Resume",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(run.needsHuman ? .orange : .blue)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.secondary)
                    Text("Need to answer a question or give this run more context?")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        expanded = true
                    } label: {
                        Label("Answer / Resume Run…", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background((run.needsHuman ? Color.orange : Color.blue).opacity(run.needsHuman || expanded ? 0.08 : 0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke((run.needsHuman ? Color.orange : Color.blue).opacity(run.needsHuman || expanded ? 0.28 : 0.12), lineWidth: 1))
    }

    private func submitResume() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = resumeWho.isEmpty ? nil : resumeWho
        if store.resumeRun(run, reply: trimmed, who: target, approveHuman: true) {
            replyText = ""
            expanded = false
        }
    }
}

/// Status response from the Docker MCP platform hardware security gate.
struct PlatformGateStatus: Decodable, Equatable {
    var platform: String?
    var locked: Bool
    var method: String?
    var unlockedAt: String?
    var expiresAt: String?
    var remainingMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case platform, locked, method, unlockedAt, expiresAt, remainingMinutes, status
    }

    init(locked: Bool = true, method: String? = nil, remainingMinutes: Int? = 0, platform: String? = nil) {
        self.locked = locked
        self.method = method
        self.remainingMinutes = remainingMinutes
        self.platform = platform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let inner = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .status) {
            self.locked = (try? inner.decode(Bool.self, forKey: .locked)) ?? false
            self.method = try? inner.decode(String.self, forKey: .method)
            self.unlockedAt = try? inner.decode(String.self, forKey: .unlockedAt)
            self.expiresAt = try? inner.decode(String.self, forKey: .expiresAt)
            self.remainingMinutes = try? inner.decode(Int.self, forKey: .remainingMinutes)
            self.platform = try? container.decode(String.self, forKey: .platform)
        } else {
            self.locked = (try? container.decode(Bool.self, forKey: .locked)) ?? true
            self.method = try? container.decode(String.self, forKey: .method)
            self.unlockedAt = try? container.decode(String.self, forKey: .unlockedAt)
            self.expiresAt = try? container.decode(String.self, forKey: .expiresAt)
            self.remainingMinutes = try? container.decode(Int.self, forKey: .remainingMinutes)
            self.platform = try? container.decode(String.self, forKey: .platform)
        }
    }
}

/// Agent YubiKey / Apple Secure Enclave stopper card in Heimdall.
/// Surfaces the hardware gate status, allowing physical Touch ID or YubiKey unsealing directly from the agent card.
struct AgentHardwareGateCard: View {
    let run: AgentRun
    @State private var status: PlatformGateStatus?
    @State private var busy = false
    @State private var message: String?
    @State private var checkTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: (status?.locked ?? true) ? "lock.shield.fill" : "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle((status?.locked ?? true) ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((status?.locked ?? true) ? "Hardware Gate Active" : "Hardware Gate Unsealed")
                            .font(.headline)
                        Text((status?.locked ?? true) ? "Boot-Locked" : "Lease Active")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(((status?.locked ?? true) ? Color.orange : Color.green).opacity(0.2), in: Capsule())
                    }
                    Text((status?.locked ?? true)
                         ? "The agent stopped at physical hardware presence. Unseal with your YubiKey or Touch ID."
                         : "Unlocked via \(status?.method ?? "hardware presence") · \(status?.remainingMinutes ?? 60)m remaining")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            if let msg = message, !msg.isEmpty {
                Text(msg).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            HStack(spacing: 8) {
                if (status?.locked ?? true) {
                    Button {
                        unlockTouchID()
                    } label: {
                        Label("Touch ID (Secure Enclave)", systemImage: "touchid")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(busy)

                    Button {
                        unlockYubiKey()
                    } label: {
                        Label("YubiKey / FIDO2", systemImage: "key.horizontal")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                } else {
                    if !run.isLive {
                        Button {
                            AgentStore.shared.resumeRun(
                                run,
                                reply: "Hardware gate unlocked via \(status?.method ?? "hardware presence"); continue and complete the task.",
                                approveHuman: true
                            )
                        } label: {
                            Label("Resume Agent Now", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(busy)
                    }
                    Button(role: .destructive) {
                        lock()
                    } label: {
                        Label("Lock Platform", systemImage: "lock.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                Spacer()
                Button {
                    refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh gate status")
                .disabled(busy)
            }
        }
        .padding(10)
        .background(((status?.locked ?? true) ? Color.orange : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(((status?.locked ?? true) ? Color.orange : Color.green).opacity(0.25), lineWidth: 1))
        .onAppear {
            refreshStatus()
            checkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onDisappear {
            checkTimer?.invalidate()
            checkTimer = nil
        }
    }

    private func resolveTarget() -> (port: Int, secret: String?, unlockScript: String?, lockScript: String?) {
        var port = 8787
        var secret: String? = nil
        var unlockScript: String? = nil
        var lockScript: String? = nil

        let candidates = [
            run.cwd ?? "",
            (run.cwd ?? "") + "/connector/ygg-business",
            (run.cwd ?? "") + "/connector/platform-deployment",
            AppPaths.defaultWorkFolder + "/connector/ygg-business",
            (("~/Developer/ragnarok/connector/ygg-business" as NSString).expandingTildeInPath)
        ]

        let fm = FileManager.default
        for base in candidates where !base.isEmpty {
            let envPath = base + "/.env"
            if fm.fileExists(atPath: envPath), let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
                for line in content.split(separator: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("PLATFORM_MCP_HTTP_PORT=") {
                        if let p = Int(s.dropFirst("PLATFORM_MCP_HTTP_PORT=".count)) { port = p }
                    } else if s.hasPrefix("PLATFORM_UNLOCK_SECRET=") {
                        secret = String(s.dropFirst("PLATFORM_UNLOCK_SECRET=".count)).trimmingCharacters(in: .init(charactersIn: "\"'"))
                    }
                }
            }
            if unlockScript == nil && fm.isExecutableFile(atPath: base + "/unlock.sh") {
                unlockScript = base + "/unlock.sh"
            }
            if lockScript == nil && fm.isExecutableFile(atPath: base + "/lock.sh") {
                lockScript = base + "/lock.sh"
            }
        }
        return (port, secret, unlockScript, lockScript)
    }

    private func probeActivePort() async -> Int? {
        let (configuredPort, _, _, _) = resolveTarget()
        let portsToTry = configuredPort == 8837 ? [8837, 8787] : [configuredPort, 8837, 8787]
        for p in portsToTry {
            guard let url = URL(string: "http://127.0.0.1:\(p)/status") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.0
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return p
            }
        }
        return nil
    }

    private func fetchStatus() async -> PlatformGateStatus? {
        guard let p = await probeActivePort(), let url = URL(string: "http://127.0.0.1:\(p)/status") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let parsed = try? JSONDecoder().decode(PlatformGateStatus.self, from: data) else {
            return nil
        }
        return parsed
    }

    private func unlockTouchID() {
        busy = true
        message = "Touch ID sensor…"
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            busy = false
            message = "Touch ID not available: \(err?.localizedDescription ?? "unknown")"
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Ragnarok Platform via Secure Enclave") { ok, evalErr in
            Task { @MainActor in
                if ok {
                    self.message = "Touch ID verified. Unlocking platform…"
                    await self.sendUnlock(method: "secure_enclave")
                } else {
                    self.busy = false
                    self.message = "Touch ID failed: \(evalErr?.localizedDescription ?? "canceled")"
                }
            }
        }
    }

    private func unlockYubiKey() {
        busy = true
        message = "Touch your YubiKey gold contact pad…"
        Task.detached {
            let fidoScript = AppPaths.fidoScript
            let (code, out, err) = Gate.run(fidoScript, [])
            let ok = code == 0 && out.contains("AUTH_KEY_OK")
            let label = out.split(separator: ":").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            await MainActor.run {
                if ok {
                    self.message = "YubiKey \(label) verified. Unlocking platform…"
                    Task {
                        await self.sendUnlock(method: "yubikey")
                    }
                } else if code == 3 {
                    self.busy = false
                    self.message = "No enrolled YubiKey plugged in. Plug it in or use Touch ID."
                } else {
                    self.busy = false
                    self.message = "YubiKey check failed: \(err.oneLine(80))"
                }
            }
        }
    }

    private func sendUnlock(method: String) async {
        let (port, secret, _, _) = resolveTarget()
        guard let activePort = await probeActivePort() else {
            self.status = PlatformGateStatus(locked: false, method: method, remainingMinutes: 60)
            self.message = "Hardware presence verified via \(method) (MCP container not running on port \(port))."
            Gate.log(method: "agent-gate:\(method)", ok: true, detail: "verified (no container on port \(port))")
            self.busy = false
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/unlock") else {
            busy = false; message = "Invalid unlock URL"; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3.0
        var payload: [String: Any] = ["method": method]
        if let secret, !secret.isEmpty {
            payload["secret"] = secret
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var unlockedOK = false
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            let parsed = try? JSONDecoder().decode(PlatformGateStatus.self, from: data)
            self.status = parsed ?? PlatformGateStatus(locked: false, method: method, remainingMinutes: 60)
            self.message = "Platform successfully unsealed via \(method)!"
            unlockedOK = true
            Gate.log(method: "agent-gate:\(method)", ok: true, detail: "unlocked port \(activePort)")
        } else {
            self.message = "Could not contact container on port \(activePort)"
        }
        if unlockedOK {
            await refreshStatusAsync()
        }
        self.busy = false
    }

    private func lock() {
        busy = true
        message = "Locking platform…"
        Task {
            let (port, _, _, lockScript) = resolveTarget()
            let activePort = await probeActivePort() ?? port
            if let url = URL(string: "http://127.0.0.1:\(activePort)/lock") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 3.0
                req.httpBody = Data("{}".utf8)
                _ = try? await URLSession.shared.data(for: req)
            }
            if let script = lockScript {
                _ = Gate.run(script, [])
            }
            Gate.log(method: "agent-gate:lock", ok: true, detail: "locked port \(activePort)")
            self.status = PlatformGateStatus(locked: true)
            await refreshStatusAsync()
            self.busy = false
            self.message = "Platform sealed. Hardware presence required to unseal."
        }
    }

    private func refreshStatus() {
        Task {
            await refreshStatusAsync()
        }
    }

    private func refreshStatusAsync() async {
        if let found = await fetchStatus() {
            self.status = found
        } else {
            if self.status == nil {
                self.status = PlatformGateStatus(locked: true)
            }
        }
    }
}
