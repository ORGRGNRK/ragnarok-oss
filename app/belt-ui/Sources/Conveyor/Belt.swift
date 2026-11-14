import AppKit
import Foundation

// The app is a window over the belt, never a second belt. Every change goes
// through the conveyor's own scripts; the app only reads the tray folders.

enum Tray: String, CaseIterable, Identifiable {
    case plan, queue, running, verify, human, done, failed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Planning"
        case .queue: "Waiting"
        case .running: "Working"
        case .verify: "Checking"
        case .human: "Needs you"
        case .done: "Done"
        case .failed: "Dead ends"
        }
    }

    var blurb: String {
        switch self {
        case .plan: "two AIs agree the steps first"
        case .queue: "next run takes the oldest"
        case .running: "an AI is on it now"
        case .verify: "a second AI is trying to say no"
        case .human: "only you can decide these"
        case .done: "every check passed"
        case .failed: "kept whole, with every reason"
        }
    }
}

// The belt's seats (conveyor-run.sh run_seat). Each one is the maker's own
// CLI, logged in with the user's own account; the app never holds a key.
enum Seat: String, CaseIterable, Identifiable {
    case claude, codex, gemini, grok, local
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        case .local: "Local model (your own server)"
        }
    }

    var maker: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        case .gemini: "Google"
        case .grok: "xAI"
        case .local: "a model on this Mac or your network, no account"
        }
    }

    /// The program that has to be installed. The local seat is the belt's own
    /// agent (python3) talking to an OpenAI-compatible server, which can be on
    /// another computer, so only python3 is needed here.
    var programs: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .gemini: ["gemini"]
        case .grok: ["grok"]
        case .local: ["python3"]
        }
    }

    var installURL: URL {
        switch self {
        case .claude: URL(string: "https://github.com/anthropics/claude-code")!
        case .codex: URL(string: "https://github.com/openai/codex")!
        case .gemini: URL(string: "https://github.com/google-gemini/gemini-cli")!
        case .grok: URL(string: "https://docs.x.ai/build/overview")!
        case .local: URL(string: "https://ollama.com")!
        }
    }
}

/// Where a terminal would find the AI programs. An app opened from Finder
/// gets a bare PATH, so these are searched explicitly.
let searchPath: [String] = {
    let home = NSHomeDirectory()
    return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.grok/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
}()

func which(_ program: String) -> String? {
    searchPath.map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct BeltTask: Identifiable, Hashable {
    let url: URL
    let tray: Tray
    let title: String
    let lastEntry: String?   // heading of the newest "## Leg" section
    let modified: Date
    var id: URL { url }

    static func read(_ url: URL, tray: Tray) -> BeltTask? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let title = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
            ?? url.deletingPathExtension().lastPathComponent
        let last = lines.last(where: { $0.hasPrefix("## Leg ") || $0.hasPrefix("## Plan ") }).map { String($0.dropFirst(3)) }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return BeltTask(url: url, tray: tray, title: title, lastEntry: last, modified: modified)
    }
}

// What the belt is doing, read from logs/. A leg's log starts with
// "--- <step> leg (<seat> seat) ---"; a claude or grok seat streams its steps to the
// .jsonl beside it, ending with a "result" event when the leg is over.
struct LiveEvent: Identifiable, Equatable {
    let id: Int
    let icon: String
    let text: String
}

struct Activity: Equatable {
    let taskTitle: String
    let step: String
    let seat: String
    let started: Date
    let live: Bool
    let events: [LiveEvent]
}

struct Receipt: Identifiable, Equatable {
    let id: Int
    let time: String
    let task: String
    let step: String
    let verdict: String
}

enum Logs {
    static func stepName(_ raw: String) -> String {
        switch raw {
        case "spec": "Planning: writing the checklist"
        case "driver": "Doing the work"
        case "verifier": "Checking the work"
        default: raw
        }
    }

    static func verdictName(_ raw: String) -> String {
        switch raw {
        case "spec-wait": "plan waiting for you"
        case "done": "done"
        case "pass": "check passed"
        case "seat-crash": "AI program failed to run"
        default: raw
        }
    }

    static func newestLeg(in logs: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "log" && $0.lastPathComponent != "notify.log" }
            .max { mtime($0) < mtime($1) }
    }

    static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func activity(root: URL, titles: [String: String]) -> Activity? {
        let logs = root.appendingPathComponent("logs")
        guard let log = newestLeg(in: logs),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        // <task stem>.<timestamp>.<pid>.log
        let stem = log.lastPathComponent.components(separatedBy: ".").first ?? ""
        var step = "", seat = ""
        for line in text.components(separatedBy: "\n") where line.hasPrefix("--- ") && line.hasSuffix(" seat) ---") {
            let words = line.dropFirst(4).components(separatedBy: " ")
            if words.count >= 3 { step = words[0]; seat = words[2].trimmingCharacters(in: CharacterSet(charactersIn: "(")) }
        }
        let raw = log.deletingPathExtension().appendingPathExtension("jsonl")
        let lines = ((try? String(contentsOf: raw, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").suffix(400)
        var events: [LiveEvent] = []
        var finished = false
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "system" where (o["subtype"] as? String) == "init":
                events.append(LiveEvent(id: events.count, icon: "play.circle",
                                        text: "Started" + ((o["model"] as? String).map { " (\($0))" } ?? "")))
            case "assistant":
                let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    if block["type"] as? String == "text", let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(LiveEvent(id: events.count, icon: "text.bubble", text: t))
                    } else if block["type"] as? String == "tool_use" {
                        events.append(LiveEvent(id: events.count, icon: "hammer",
                                                text: toolLine(block["name"] as? String ?? "tool",
                                                               block["input"] as? [String: Any] ?? [:])))
                    }
                }
            case "result":
                finished = true
                let last = (o["result"] as? String ?? "").components(separatedBy: "\n")
                    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                events.append(LiveEvent(id: events.count, icon: "flag.checkered", text: "Finished: \(last)"))
            default:
                continue
            }
        }
        // No result yet and the stream moved in the last 20 minutes: the leg
        // is still running. An older silent stream is a crash, not a leg.
        let fresh = Date().timeIntervalSince(mtime(FileManager.default.fileExists(atPath: raw.path) ? raw : log)) < 1200
        // The earlier of the two: a copied log's creation date is when it was
        // copied, while its modified date is still the leg's start.
        return Activity(taskTitle: titles[stem] ?? stem, step: stepName(step), seat: seat,
                        started: min(creation(log), mtime(log)),
                        live: !finished && fresh && !step.isEmpty, events: events)
    }

    static func creation(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? mtime(url)
    }

    static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        let firstLine: (String) -> String = { String($0.components(separatedBy: "\n").first ?? "").prefix(160).description }
        // Claude names the file file_path; Grok Build uses path or target_file.
        if let p = (input["file_path"] ?? input["path"] ?? input["target_file"]) as? String {
            let verb = ["Read": "Reading", "Write": "Writing", "Edit": "Editing", "MultiEdit": "Editing",
                        "read_file": "Reading", "write_file": "Writing", "search_replace": "Editing"][name] ?? name
            return "\(verb) \(p)"
        }
        if let c = input["command"] as? String { return "Running: \(firstLine(c))" }
        if let p = input["pattern"] as? String { return "\(name == "Grep" || name == "grep" ? "Searching for" : "Finding files") \(p)" }
        if let u = input["url"] as? String { return "Opening \(u)" }
        if let d = input["description"] as? String { return "\(name): \(firstLine(d))" }
        return name
    }

    static func receipts(root: URL, titles: [String: String]) -> [Receipt] {
        let file = root.appendingPathComponent("logs/receipts.jsonl")
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n").suffix(30)
        var out: [Receipt] = []
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let task = (o["task"] as? String ?? "").replacingOccurrences(of: ".md", with: "")
            let ts = o["ts"] as? String ?? ""
            // 2026-10-26T08:05:17-07:00 -> 10-26 08:05
            let time = ts.count >= 16 ? "\(ts.dropFirst(5).prefix(5)) \(ts.dropFirst(11).prefix(5))" : ts
            out.append(Receipt(id: out.count, time: time, task: titles[task] ?? task,
                               step: o["seat"] as? String ?? "", verdict: verdictName(o["verdict"] as? String ?? "")))
        }
        return out
    }
}

@MainActor
final class BeltStore: ObservableObject {
    @Published private(set) var activity: Activity?
    @Published private(set) var receipts: [Receipt] = []
    @Published private(set) var root: URL?
    @Published private(set) var tasks: [Tray: [BeltTask]] = [:]

    // Who does the work (and writes the checklist; the belt's spec leg uses
    // the driver seat) and who tries to prove it wrong.
    @Published var workerSeat: Seat {
        didSet { UserDefaults.standard.set(workerSeat.rawValue, forKey: "workerSeat") }
    }
    @Published var checkerSeat: Seat {
        didSet { UserDefaults.standard.set(checkerSeat.rawValue, forKey: "checkerSeat") }
    }
    // The belt's own default, conveyor-general, is a model built on the
    // author's box. A stranger's Ollama has no such model.
    @Published var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "localModel") }
    }
    /// Where the local seat's OpenAI-compatible server is (CONVEYOR_LOCAL_BASE_URL).
    @Published var localBaseURL: String {
        didSet { UserDefaults.standard.set(localBaseURL, forKey: "localBaseURL") }
    }
    // Planning first (SPEC-planning.md): who writes the plan, who picks holes
    // in it, and who gets one go at a step that keeps failing (nil = ask me).
    @Published var plannerSeat: Seat {
        didSet { UserDefaults.standard.set(plannerSeat.rawValue, forKey: "plannerSeat") }
    }
    @Published var criticSeat: Seat {
        didSet { UserDefaults.standard.set(criticSeat.rawValue, forKey: "criticSeat") }
    }
    @Published var escalateSeat: Seat? {
        didSet { UserDefaults.standard.set(escalateSeat?.rawValue ?? "", forKey: "escalateSeat") }
    }

    private static let rootKey = "beltRoot"
    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        workerSeat = d.string(forKey: "workerSeat").flatMap(Seat.init) ?? .claude
        checkerSeat = d.string(forKey: "checkerSeat").flatMap(Seat.init) ?? .claude
        localModel = d.string(forKey: "localModel") ?? "qwen2.5:7b"
        localBaseURL = d.string(forKey: "localBaseURL") ?? "http://127.0.0.1:1234/v1"
        plannerSeat = d.string(forKey: "plannerSeat").flatMap(Seat.init) ?? .claude
        criticSeat = d.string(forKey: "criticSeat").flatMap(Seat.init) ?? .grok
        escalateSeat = d.string(forKey: "escalateSeat").flatMap(Seat.init)
        if let host = d.string(forKey: "remoteHost"), let path = d.string(forKey: "remotePath") {
            let r = RemoteBelt(host: host, path: path)
            remote = r
            root = r.cache
        } else {
            let saved = d.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0) }
            let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("conveyor")
            root = [saved, fallback].compactMap { $0 }.first(where: Self.isBelt)
        }
        refresh()
        // Plain polling: the belt moves on minute scales and a 2 s re-read of
        // six small folders costs nothing. A remote belt is copied first.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.remote != nil { await self.syncNow() } else { self.refresh() }
            }
        }
        if remote != nil { Task { await syncNow() } }
    }

    // MARK: Remote

    @Published private(set) var remote: RemoteBelt?
    @Published private(set) var syncError: String?
    private var syncing = false

    func syncNow() async {
        guard let remote, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let err = await remote.sync()
        guard remote == self.remote else { return }  // switched belts meanwhile
        if err != syncError { syncError = err }
        refresh()
    }

    /// Returns an error to show, or nil once connected and copied.
    func connect(host: String, path: String) async -> String? {
        let r = RemoteBelt(host: host.trimmingCharacters(in: .whitespaces),
                           path: path.trimmingCharacters(in: .whitespaces))
        if let err = await r.check() { return err }
        if let err = await r.sync() { return err }
        remote = r
        root = r.cache
        syncError = nil
        let d = UserDefaults.standard
        d.set(r.host, forKey: "remoteHost")
        d.set(r.path, forKey: "remotePath")
        refresh()
        return nil
    }

    static func isBelt(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: url.appendingPathComponent("conveyor").path)
            && fm.fileExists(atPath: url.appendingPathComponent("queue").path)
    }

    /// Returns false when the folder is not a conveyor install.
    func choose(_ url: URL) -> Bool {
        guard Self.isBelt(url) else { return false }
        remote = nil
        syncError = nil
        root = url
        let d = UserDefaults.standard
        d.removeObject(forKey: "remoteHost")
        d.removeObject(forKey: "remotePath")
        d.set(url.path, forKey: Self.rootKey)
        refresh()
        return true
    }

    func refresh() {
        guard let root else { tasks = [:]; return }
        var out: [Tray: [BeltTask]] = [:]
        for tray in Tray.allCases {
            let dir = root.appendingPathComponent(tray.rawValue)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            out[tray] = files.filter { $0.pathExtension == "md" }
                .compactMap { BeltTask.read($0, tray: tray) }
                .sorted { $0.modified > $1.modified }
        }
        if out != tasks { tasks = out }

        var titles: [String: String] = [:]
        for task in out.values.joined() { titles[task.url.deletingPathExtension().lastPathComponent] = task.title }
        let act = Logs.activity(root: root, titles: titles)
        if act != activity { activity = act }
        let rec = Logs.receipts(root: root, titles: titles)
        if rec != receipts { receipts = rec }
    }

    /// `./conveyor add "title" -m body`. Returns the script's output on failure.
    /// Files (any kind) are copied into attachments/<id>/ and listed in the
    /// task by full path; every task gets outputs/<id>/ for its results (see
    /// TaskFiles). Not into a tray: the task file moves between trays and
    /// would leave them behind. The seat opens them with its own file tools.
    func add(title: String, body: String, files: [URL] = [], plan: Bool = false) async -> String? {
        if let err = TaskFiles.problem(with: files) { return err }
        if plan {
            // Only the belt's own conveyor-add knows where plan/ is and how a
            // planned task starts; there is no app-side fallback for it.
            if remote != nil { return "Planning first only works on a belt on this Mac for now." }
            guard let root else { return "No conveyor folder chosen." }
            guard Self.supportsPlan(root) else {
                return "This belt is older than planning first (its conveyor-add has no --plan). Update the belt, or untick Plan it first."
            }
            let args = ["add", title, "--plan"] + files.flatMap { ["--attach", $0.path] } + ["-m", body]
            let result = await Self.run(root: root, args, env: seatEnv)
            refresh()
            return result.status == 0 ? nil : result.output
        }
        if let remote {
            let err = await remote.add(title: title, body: body, files: files)
            await syncNow()
            return err
        }
        guard let root else { return "No conveyor folder chosen." }
        // A belt whose conveyor-add knows --attach does the copying itself, so
        // the folders share the task file's name. An older belt gets the same
        // layout from the app.
        if Self.supportsAttach(root) {
            let args = ["add", title] + files.flatMap { ["--attach", $0.path] } + ["-m", body]
            let result = await Self.run(root: root, args, env: seatEnv)
            refresh()
            return result.status == 0 ? nil : result.output
        }
        let id = TaskFiles.newID(title: title)
        let fm = FileManager.default
        let outputs = root.appendingPathComponent("outputs").appendingPathComponent(id)
        var listed: [String] = []
        do {
            try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
            if !files.isEmpty {
                let dir = root.appendingPathComponent("attachments").appendingPathComponent(id)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (src, name) in zip(files, TaskFiles.uniqueNames(files)) {
                    let dst = dir.appendingPathComponent(name)
                    try fm.copyItem(at: src, to: dst)
                    listed.append(dst.path)
                }
            }
        } catch {
            return "Could not copy the files: \(error.localizedDescription)"
        }
        let full = body + "\n\n" + TaskFiles.sections(attachments: listed, outputs: outputs.path) + "\n"
        // Written here, not by this older conveyor-add, which would pick its
        // own file name and not match attachments/<id>/ and outputs/<id>/.
        let err = Self.writeTask(root: root, id: id, title: title, body: full)
        refresh()
        return err
    }

    /// Writes queue/<id>.md in conveyor-add's format ("# title", blank,
    /// queued:, by:, blank, body). Via a hidden temp file linked into place,
    /// so a watcher never reads half a file; an existing task is never replaced.
    nonisolated static func writeTask(root: URL, id: String, title: String, body: String) -> String? {
        let fm = FileManager.default
        let queue = root.appendingPathComponent("queue")
        let file = queue.appendingPathComponent("\(id).md"), tmp = queue.appendingPathComponent(".\(id).md.tmp")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        stamp.timeZone = .current
        let by = ProcessInfo.processInfo.environment["CONVEYOR_BY"] ?? NSUserName()
        let text = "# \(title)\n\nqueued: \(stamp.string(from: Date()))\nby: \(by)\n\n" + body
        do {
            try fm.createDirectory(at: queue, withIntermediateDirectories: true)
            if fm.fileExists(atPath: file.path) { return "A task with this name is already in queue/." }
            try Data(text.utf8).write(to: tmp)
            defer { try? fm.removeItem(at: tmp) }
            try fm.linkItem(at: tmp, to: file)
        } catch {
            return "Could not write the task file: \(error.localizedDescription)"
        }
        return nil
    }

    /// The belt has the plan stage: its conveyor-add takes --plan.
    nonisolated static func supportsPlan(_ root: URL) -> Bool {
        let text = (try? String(contentsOf: root.appendingPathComponent("conveyor-add"), encoding: .utf8)) ?? ""
        return text.contains("--plan")
    }

    /// Whether to offer planning: a belt on this Mac that has it.
    var planAvailable: Bool {
        guard remote == nil, let root else { return false }
        return Self.supportsPlan(root)
    }

    /// A planned task the planner and critic could not agree on goes back to
    /// plan/ for a fresh start (after the person edited the request).
    func replan(_ task: BeltTask) -> String? {
        guard task.tray == .human, remote == nil, let root else { return "Only a task on this Mac in Needs you can be planned again." }
        let dest = root.appendingPathComponent("plan").appendingPathComponent(task.url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: task.url, to: dest)
        } catch {
            return "Could not move it to planning: \(error.localizedDescription)"
        }
        refresh()
        return nil
    }

    nonisolated static func supportsAttach(_ root: URL) -> Bool {
        let text = (try? String(contentsOf: root.appendingPathComponent("conveyor-add"), encoding: .utf8)) ?? ""
        return text.contains("--attach")
    }

    // MARK: Run

    @Published private(set) var running = false
    @Published private(set) var runOutput = ""
    private var runProcess: Process?

    /// `./conveyor run`: works the queue until it is empty, stuck, or the
    /// leg cap. Output streams into runOutput.
    func startRun(maxLegs: Int = 6) {
        // A remote belt runs on its own timer, as its own user.
        guard let root, !running, remote == nil else { return }
        if let missing = Self.missingScript(root) { runOutput = missing; return }
        running = true
        runOutput = ""
        runProcess = Self.launch(root: root, ["run", "--max", String(maxLegs)], env: seatEnv,
            onOutput: { [weak self] text in Task { @MainActor in self?.runOutput += text } },
            onExit: { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    self.runOutput += status == 0 ? "" : "\n(stopped, exit \(status))\n"
                    self.running = false
                    self.runProcess = nil
                    self.refresh()
                }
            })
        if runProcess == nil { running = false; runOutput = "Could not start the conveyor." }
    }

    /// The run is a tree (conveyor -> conveyor-run.sh -> timeout -> the AI
    /// program); stopping only the top would leave the AI working unseen.
    func stopRun() {
        guard let p = runProcess else { return }
        Self.killTree(p.processIdentifier)
    }

    nonisolated static func killTree(_ pid: Int32) {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        let kids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0) }
        kill(pid, SIGSTOP)  // so it cannot start a new child while its children go
        kids.forEach(killTree)
        kill(pid, SIGTERM)
        kill(pid, SIGCONT)
    }

    nonisolated static func launch(root: URL, _ args: [String], env extra: [String: String],
                                   onOutput: @escaping @Sendable (String) -> Void,
                                   onExit: @escaping @Sendable (Int32) -> Void) -> Process? {
        if missingScript(root) != nil { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("conveyor").path] + args
        p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        env.merge(extra) { _, new in new }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
        do { try p.run() } catch { return nil }
        return p
    }

    // MARK: Approve

    /// A plan waiting in human/: tick its `verify: HUMAN` line and move it back
    /// to queue/ -- the belt's own rule for recording the person's yes
    /// (AGENTS.md). Only ever called from a button the person pressed.
    func approve(_ task: BeltTask) async -> String? {
        guard task.tray == .human else { return "Only a task in Needs you can be approved." }
        if let remote {
            let err = await remote.approve(task.url.lastPathComponent)
            await syncNow()
            return err
        }
        guard let root else { return "No conveyor folder chosen." }
        guard var text = try? String(contentsOf: task.url, encoding: .utf8) else { return "Could not read the task." }
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("- [ ]") && $0.contains(":: verify: HUMAN") }) else {
            return "This task has no step waiting for your yes."
        }
        lines[i] = "- [x]" + lines[i].dropFirst(5)
        text = lines.joined(separator: "\n")
        let dest = root.appendingPathComponent("queue").appendingPathComponent(task.url.lastPathComponent)
        do {
            try text.write(to: task.url, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: task.url, to: dest)
        } catch {
            return "Could not move it back to the queue: \(error.localizedDescription)"
        }
        refresh()
        return nil
    }

    /// `./conveyor doctor` with the chosen providers: the belt's own check.
    /// A remote belt gets a read-only check over SSH instead: its folder on
    /// this Mac is only a copy of the trays, with no scripts to run.
    func doctor() async -> String {
        if let remote { return await remote.doctor() }
        guard let root else { return "No conveyor folder chosen." }
        return await Self.run(root: root, ["doctor"], env: seatEnv).output
    }

    /// The belt reads its seats from these variables (conveyor-run.sh).
    var seatEnv: [String: String] {
        var env = ["CONVEYOR_DRIVER_SEAT": workerSeat.rawValue,
                   "CONVEYOR_VERIFIER_SEAT": checkerSeat.rawValue,
                   "CONVEYOR_LOCAL_MODEL": localModel,
                   "CONVEYOR_LOCAL_BASE_URL": localBaseURL,
                   "CONVEYOR_PLANNER_SEAT": plannerSeat.rawValue,
                   "CONVEYOR_CRITIC_SEAT": criticSeat.rawValue]
        if let escalateSeat { env["CONVEYOR_ESCALATE_SEAT"] = escalateSeat.rawValue }
        for (program, key) in [("claude", "CONVEYOR_CLAUDE"), ("codex", "CONVEYOR_CODEX"), ("gemini", "CONVEYOR_GEMINI"), ("grok", "CONVEYOR_GROK")] {
            // A path the person set themselves wins over the one found here.
            if ProcessInfo.processInfo.environment[key] == nil, let path = which(program) { env[key] = path }
        }
        return env
    }

    /// Why `root` cannot be run, in words, or nil when its `conveyor` script is there.
    nonisolated static func missingScript(_ root: URL) -> String? {
        var dir: ObjCBool = false
        let script = root.appendingPathComponent("conveyor").path
        if FileManager.default.fileExists(atPath: script, isDirectory: &dir), !dir.boolValue { return nil }
        if root.path.contains("/Application Support/Conveyor/remote/") {
            return "This is a belt on another computer; it runs there, so there is nothing to run on this Mac."
        }
        return "There is no conveyor program in \(root.path). Choose the conveyor folder again (Change belt)."
    }

    nonisolated static func run(root: URL, _ args: [String], env extra: [String: String] = [:]) async -> (status: Int32, output: String) {
        if let missing = missingScript(root) { return (127, missing) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [root.appendingPathComponent("conveyor").path] + args
                p.currentDirectoryURL = root
                // An app opened from Finder gets a bare PATH; see searchPath.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
                env.merge(extra) { _, new in new }
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    cont.resume(returning: (-1, "Could not start the conveyor: \(error.localizedDescription)"))
                }
            }
        }
    }
}
