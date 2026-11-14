import Foundation
import SwiftUI

struct RoomTaskAssignment: Identifiable {
    let id: String
    let text: String
    let by: String
}

/// The shared room on Alexus (room/room.py, installed at ~/Developer/ragnarok-room/bin/room there).
/// Heimdall follows it with `room watch` over ssh as the owner and can post linked task claims as the selected agent.
/// The author of every message comes from the file owner on Alexus, so AIs show under their own login.
@MainActor
final class RoomModel: ObservableObject {
    struct Msg: Identifiable, Hashable {
        let id: String; let ts: String; let by: String; let type: String; let text: String; let ref: String?
        let unverified: Bool
    }
    @Published var msgs: [Msg] = []
    @Published var status = "Connecting to the room on Alexus…"
    @Published var sending = false
    @Published var conveyorBridgeEnabled = false

    nonisolated static let remote = LocalConfig.current.alexusHome + "/Developer/ragnarok-room/bin/room"
    nonisolated static let target = LocalConfig.current.ssh
    nonisolated static let conveyorBridgePath = NSHomeDirectory() + "/.conveyor/room.on"
    private var proc: Process?
    private var started = false

    init() {
        conveyorBridgeEnabled = Self.isConveyorBridgeEnabled()
    }

    nonisolated static func isConveyorBridgeEnabled(path: String = conveyorBridgePath) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    @discardableResult
    nonisolated static func setConveyorBridge(enabled: Bool, path: String = conveyorBridgePath) -> Bool {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        if enabled {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: path) {
                return fm.createFile(atPath: path, contents: Data())
            }
            return true
        } else {
            if fm.fileExists(atPath: path) {
                do {
                    try fm.removeItem(atPath: path)
                    return true
                } catch {
                    AppLog.error("room-bridge-remove", error)
                    return false
                }
            }
            return true
        }
    }

    func refreshConveyorBridge() {
        let active = Self.isConveyorBridgeEnabled()
        if conveyorBridgeEnabled != active {
            conveyorBridgeEnabled = active
        }
    }

    func setConveyorBridge(enabled: Bool) {
        Self.setConveyorBridge(enabled: enabled)
        conveyorBridgeEnabled = Self.isConveyorBridgeEnabled()
    }

    func start() {
        refreshConveyorBridge()
        guard !started else { return }
        started = true
        launch()
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=20", Self.target, "python3 \(Self.remote) watch"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.status = "Room connection dropped; reconnecting…"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.msgs = []; self?.launch()
            }
        }
        do { try p.run(); proc = p; status = "Live · shared with your AIs on Alexus" }
        catch { AppLog.error("room-watch", error); status = "Can't start ssh: \(error.localizedDescription)"; return }
        Task {
            for await line in FileHandleLines.lines(from: out.fileHandleForReading) {
                if let m = Self.parse(line) { msgs.append(m); if msgs.count > 2000 { msgs.removeFirst(msgs.count - 2000) } }
            }
        }
    }

    nonisolated static func parse(_ line: String) -> Msg? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = d["id"] as? String else { return nil }
        return Msg(id: id, ts: d["ts"] as? String ?? "", by: d["by"] as? String ?? "?", type: d["type"] as? String ?? "say",
                   text: d["text"] as? String ?? "", ref: d["ref"] as? String, unverified: d["unverified"] as? Bool ?? false)
    }

    /// Open tasks worked out from the messages (task → claim → done).
    var tasks: [(id: String, text: String, by: String, state: String, owner: String?)] {
        var order: [String] = []; var t: [String: (text: String, by: String, state: String, owner: String?)] = [:]
        for m in msgs {
            if m.type == "task" { t[m.id] = (m.text, m.by, "open", nil); order.append(m.id) }
            else if let r = m.ref, t[r] != nil, m.type == "claim" || m.type == "done" {
                t[r]!.state = m.type == "claim" ? "claimed" : "done"; t[r]!.owner = m.by
            }
        }
        return order.compactMap { id in t[id].flatMap { $0.state == "done" ? nil : (id, $0.text, $0.by, $0.state, $0.owner) } }
    }

    /// kind: say | task | claim | done. Text goes over stdin, so nothing in it is treated as a command.
    /// done(true) only when the room really took it, so the text box keeps unsent text (report item 18).
    func post(_ kind: String, _ text: String, ref: String? = nil, by agent: String? = nil,
              done: (@MainActor (Bool) -> Void)? = nil) {
        guard !sending else { done?(false); return }
        if let agent, !["claude", "argon", "grok", "codex"].contains(agent) {
            status = "Can't post as unsupported agent \(agent)"
            done?(false); return
        }
        sending = true
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var cmd = "RAGNAROK_ROOM_VIA=heimdall python3 \(Self.remote) \(kind)"
            if let ref { cmd += " " + ref.filter { $0.isHexDigit } }
            cmd += " -"
            var ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
            if let agent { ssh += ["-i", NSHomeDirectory() + "/.ssh/id_\(agent)", "-o", "IdentitiesOnly=yes"] }
            let host = String(Self.target.split(separator: "@", omittingEmptySubsequences: false).last ?? Substring(Self.target))
            let target = agent.map { "\($0)@\(host)" } ?? Self.target
            p.arguments = ssh + [target, cmd]
            let i = Pipe(), e = Pipe(); p.standardInput = i; p.standardOutput = Pipe(); p.standardError = e
            var err = ""
            do {
                try p.run(); i.fileHandleForWriting.write(Data(text.utf8)); try? i.fileHandleForWriting.close()
                p.waitUntilExit()
                if p.terminationStatus != 0 { err = String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
            } catch { AppLog.error("room-post", error); err = error.localizedDescription }
            let message = err
            await MainActor.run {
                self.sending = false
                if !message.isEmpty { self.status = "Couldn't post (your text is still in the box): \(message.oneLine(160))" }
                done?(message.isEmpty)
            }
        }
    }
}

struct RoomView: View {
    @EnvironmentObject var room: RoomModel
    @StateObject private var agents = AgentStore.shared
    @State private var text = ""
    @State private var asTask = false
    @State private var showAgentSheet = false
    @State private var taskForAgent: RoomTaskAssignment?

    // The room is the shared chat and the task list. (Until 11-02 it also had a file tree, editor, explain panel and
    // an AI terminal; Agents and the Edit bar do that work now.)
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                chatPanel.frame(minWidth: 420)
                tasksPanel
                    .padding(10).frame(minWidth: 200, idealWidth: 280, maxWidth: 380)
            }
            Divider()
            statusBar
        }
        .onAppear {
            room.start()
            room.refreshConveyorBridge()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                room.refreshConveyorBridge()
            }
        }
        .sheet(isPresented: $showAgentSheet) {
            if let task = taskForAgent {
                NewAgentSheet(store: agents, shown: $showAgentSheet, roomTask: task) { runID, who in
                    claim(task, runID: runID, who: who)
                }
            }
        }
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ROOM").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(room.conveyorBridgeEnabled ? .green : .secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(room.conveyorBridgeEnabled ? "Bridge active" : "Bridge off")
                        .font(.caption2)
                        .foregroundStyle(room.conveyorBridgeEnabled ? .primary : .secondary)
                }
                .help("Conveyor Room Bridge (~/.conveyor/room.on): " + (room.conveyorBridgeEnabled ? "active" : "disabled"))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                List(room.msgs) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(RoomView.localTime(m.ts)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(m.by + (m.unverified ? " (unverified)" : "")).font(.caption.bold())
                            .foregroundStyle(Palette.color(Actors.normalize(m.by))).frame(width: 90, alignment: .leading)
                        Text(Self.line(m, room.msgs)).textSelection(.enabled)
                        Spacer(minLength: 4)
                    }
                    .id(m.id)
                }
                .listStyle(.plain)
                .onChange(of: room.msgs.count) { if let last = room.msgs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            HStack {
                Toggle("Task", isOn: $asTask).toggleStyle(.checkbox).help("Post this as a task an AI can claim")
                TextField(asTask ? "Describe a task for anyone to pick up…" : "Message everyone…", text: $text)
                    .textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Post", action: send).disabled(room.sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
    }

    private var tasksPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("TASKS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(room.conveyorBridgeEnabled ? .green : .secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(room.conveyorBridgeEnabled ? "Bridge active" : "Bridge off")
                        .font(.caption2)
                        .foregroundStyle(room.conveyorBridgeEnabled ? .primary : .secondary)
                }
            }
            Toggle("Conveyor Room Bridge", isOn: Binding(
                get: { room.conveyorBridgeEnabled },
                set: { room.setConveyorBridge(enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Run ~/conveyor/conveyor-room on open tasks (~/.conveyor/room.on)")

            Divider()

            if room.tasks.isEmpty { Text("None open").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(room.tasks, id: \.id) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.text).lineLimit(3)
                            Text("\(t.state == "claimed" ? "being done by \(t.owner ?? "?")" : "open") · from \(t.by) · \(t.id)")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if t.state == "open" { Button("I'll do it") { room.post("claim", "", ref: t.id) } }
                                if t.state == "open" {
                                    Menu("Connect agent") {
                                        Button("Auto · Claude") { startAutomatically(t) }
                                            .help("Start Claude in ~/Developer/ragnarok and connect it to this task")
                                        Button("Choose agent…") {
                                            taskForAgent = RoomTaskAssignment(id: t.id, text: t.text, by: t.by)
                                            showAgentSheet = true
                                        }
                                    }.disabled(room.sending)
                                }
                                Button("Mark done") { room.post("done", "", ref: t.id) }
                            }
                            .controlSize(.small)
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Text("AIs use the `room` command: room say / task / claim / done / read / tasks. On Alexus each AI posts as its own login.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(room.status.hasPrefix("Live") ? .green : .orange).frame(width: 8, height: 8)
            Text(room.status).lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(room.conveyorBridgeEnabled ? .green : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(room.conveyorBridgeEnabled ? "Bridge active" : "Bridge off")
            }
            .help("Conveyor Room Bridge (~/.conveyor/room.on): " + (room.conveyorBridgeEnabled ? "active" : "disabled"))
            Text("·")
            Text("\(room.tasks.count) open task\(room.tasks.count == 1 ? "" : "s")")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    /// "2026-11-01T17:10:00Z" → "09:10" in the Mac's own time zone.
    nonisolated static func localTime(_ ts: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = ts.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let d = iso.date(from: ts) else { return String(ts.dropFirst(11).prefix(5)) }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current
        return f.string(from: d)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        room.post(asTask ? "task" : "say", t) { ok in if ok && text.trimmingCharacters(in: .whitespacesAndNewlines) == t { text = "" } }
    }

    private func startAutomatically(_ task: (id: String, text: String, by: String, state: String, owner: String?)) {
        let prompt = "Room task \(task.id) (posted by \(task.by)):\n\n\(task.text)\n\nComplete this task, then report the result in the Agents section."
        guard let runID = agents.start(task: prompt, cwd: AppPaths.defaultWorkFolder,
                                       model: nil, who: "claude", prove: true, roomTaskID: task.id) else {
            room.status = agents.message.isEmpty ? "Couldn't start the agent for room task \(task.id)" : agents.message
            return
        }
        claim(RoomTaskAssignment(id: task.id, text: task.text, by: task.by), runID: runID, who: "claude")
    }

    private func claim(_ task: RoomTaskAssignment, runID: String, who: String) {
        // the Room knows SSH identities, not runners: Antigravity posts as argon (Event.swift maps it the same way)
        let who = who == "antigravity" ? "argon" : who
        room.post("claim", "Started Heimdall agent run \(runID)", ref: task.id, by: who) { ok in
            if !ok {
                agents.stop(runID)
                room.status = "Agent stopped: couldn't claim room task \(task.id) as \(who)."
            } else {
                room.status = "Live · room task \(task.id) connected to \(who) run \(runID)."
            }
        }
    }

    nonisolated static func line(_ m: RoomModel.Msg, _ all: [RoomModel.Msg]) -> String {
        let taskText = { (id: String?) in all.first { $0.id == id && $0.type == "task" }?.text.oneLine(60) ?? (id ?? "?") }
        switch m.type {
        case "task": return "📋 Task: \(m.text)"
        case "claim": return "is doing: \(taskText(m.ref))" + (m.text.isEmpty ? "" : " — \(m.text)")
        case "done": return "✅ finished: \(taskText(m.ref))" + (m.text.isEmpty ? "" : " — \(m.text)")
        default: return m.text
        }
    }
}
