import Foundation

/// Everything the app has seen, newest last. Feeds push into it from background threads.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var events: [Event] = []
    @Published var feedStatus: [String: String] = [:]   // feed name -> "live" / error text
    let cap = 30_000

    func add(_ batch: [Event]) {
        guard !batch.isEmpty else { return }
        events.append(contentsOf: batch)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }
    func status(_ feed: String, _ text: String) { feedStatus[feed] = text }
}

/// Follows every file matching some glob patterns, like `tail -F` on many files at once.
/// New files are picked up; each file is read from where it was left. Never dies: errors are reported and retried.
final class FileFeed: @unchecked Sendable {
    let name: String
    let patterns: [String]
    let parse: Parsers.Parser
    let backfillBytes: UInt64
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: String] = [:]
    private var inodes: [String: UInt64] = [:]
    private let queue: DispatchQueue
    private weak var store: Store?
    private var timer: DispatchSourceTimer?

    init(name: String, patterns: [String], backfillBytes: UInt64 = 64 * 1024, parse: @escaping Parsers.Parser) {
        self.name = name; self.patterns = patterns; self.parse = parse; self.backfillBytes = backfillBytes
        self.queue = DispatchQueue(label: "feed.\(name)")
    }

    func start(_ store: Store) {
        self.store = store
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    private func files() -> [String] {
        patterns.flatMap { Glob.expand(($0 as NSString).expandingTildeInPath) }
    }

    private func tick() {
        var batch: [Event] = []
        let found = files()
        for path in found {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            var start: UInt64
            if let o = offsets[path] { start = o } else {
                // First sight: show only the recent tail, and only for files touched in the last day.
                let recent = ((attrs[.modificationDate] as? Date) ?? .distantPast) > Date().addingTimeInterval(-86_400)
                start = recent ? (size > backfillBytes ? size - backfillBytes : 0) : size
                if start > 0 { partial[path] = nil }
                offsets[path] = start
                if start > 0 && recent { skipFirstLine[path] = true }
            }
            // report item 19: a file replaced by rotation is noticed by its inode, even if the new one is already bigger
            let ino = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if let old = inodes[path], old != ino { start = 0; offsets[path] = 0 }
            inodes[path] = ino
            if size < start { start = 0; offsets[path] = 0 }      // file was truncated or replaced
            guard size > start, let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: start)
            var data = h.readDataToEndOfFile()
            // only whole lines are taken; the unfinished last line (maybe half a UTF-8 character) is read next time
            if let nl = data.lastIndex(of: 0x0A) { data = data[data.startIndex...nl] }
            else if data.count < 4_000_000 { continue }
            offsets[path] = start + UInt64(data.count)
            partial[path] = nil
            var text = String(decoding: data, as: UTF8.self)
            var lines = text.components(separatedBy: "\n")
            _ = lines.removeLast()
            if skipFirstLine.removeValue(forKey: path) != nil, !lines.isEmpty { lines.removeFirst() }
            text = ""
            for line in lines where !line.isEmpty { batch.append(contentsOf: parse(path, line)) }
        }
        let n = found.count
        let out = batch.sorted { $0.time < $1.time }
        Task { @MainActor [weak store, name] in
            store?.add(out)
            store?.status(name, n == 0 ? "no files yet" : "live · \(n) file\(n == 1 ? "" : "s")")
        }
    }
    private var skipFirstLine: [String: Bool] = [:]
}

/// Runs a command over SSH on Alexus and turns each output line into events. Restarts itself if it drops.
final class SSHFeed: @unchecked Sendable {
    let name: String
    let remote: String
    let parse: Parsers.Parser
    private weak var store: Store?
    private var proc: Process?
    private var bytes = Data()
    private let queue: DispatchQueue

    static let target = LocalConfig.current.ssh

    init(name: String, remote: String, parse: @escaping Parsers.Parser) {
        self.name = name; self.remote = remote; self.parse = parse
        self.queue = DispatchQueue(label: "ssh.\(name)")
    }

    func start(_ store: Store) { self.store = store; queue.async { self.launch() } }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=20",
                       "-o", "ServerAliveCountMax=3", Self.target, remote]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.queue.async { self.consume(d) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor [weak store = self.store, name = self.name] in
                store?.status(name, "reconnecting (exit \(proc.terminationStatus)) \(e.oneLine(80))")
            }
            self.queue.asyncAfter(deadline: .now() + 5) { self.launch() }
        }
        do {
            try p.run(); proc = p
            Task { @MainActor [weak store, name] in store?.status(name, "live · Alexus") }
        } catch {
            Task { @MainActor [weak store, name] in store?.status(name, "can't start ssh: \(error.localizedDescription)") }
            queue.asyncAfter(deadline: .now() + 10) { self.launch() }
        }
    }

    private func consume(_ d: Data) {
        // bytes are split into lines BEFORE decoding, so a character split across two reads stays whole
        bytes.append(d)
        guard let nl = bytes.lastIndex(of: 0x0A) else { return }
        let whole = bytes[bytes.startIndex...nl]; bytes = Data(bytes[bytes.index(after: nl)...])
        var lines = String(decoding: whole, as: UTF8.self).components(separatedBy: "\n")
        _ = lines.removeLast()
        let evs = lines.filter { !$0.isEmpty }.flatMap { parse(name, $0) }
        Task { @MainActor [weak store] in store?.add(evs) }
    }

    func stop() { proc?.terminationHandler = nil; proc?.terminate() }
}

enum Glob {
    static func expand(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        guard glob(pattern, 0, nil, &gt) == 0 else { return [] }
        return (0..<Int(gt.gl_pathc)).compactMap { gt.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}

/// All feeds Heimdall watches. See docs/PLAN.md for where each comes from.
enum AllFeeds {
    static func make() -> (files: [FileFeed], ssh: [SSHFeed]) {
        let files = [
            FileFeed(name: "Claude Code (Mac)", patterns: ["~/.claude/projects/*/*.jsonl"], parse: Parsers.claude),
            FileFeed(name: "Argon / Antigravity (Mac)", patterns: ["~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl"], parse: Parsers.argon),
            FileFeed(name: "Grok CLI (Mac)", patterns: ["~/.grok/sessions/*/*/chat_history.jsonl"], parse: Parsers.grok),
            FileFeed(name: "Codex tool activity (Mac)", patterns: ["~/.codex/sessions/*/*/*/*.jsonl"], backfillBytes: 8 * 1024 * 1024, parse: Parsers.codexTools),
            FileFeed(name: "AI receipts (Mac)", patterns: ["~/.ragnarok/receipts-spool.jsonl"], parse: Parsers.macReceipts),
            FileFeed(name: "\(LocalConfig.owner)'s shell (Mac)", patterns: ["~/.ragnarok/user-commands.jsonl", "~/.ragnarok/heimdall-shell.jsonl"], parse: Parsers.ownerShell),
            FileFeed(name: "Heimdall edits / launcher", patterns: ["~/.ragnarok/heimdall-edits.jsonl"], parse: Parsers.edits),
            FileFeed(name: "Project heal runs", patterns: ["~/.ragnarok/ragnarok-heal.jsonl"], parse: Parsers.heal),
            FileFeed(name: "Ragnarok app errors", patterns: [AppLog.path], parse: Parsers.appErrors),
            FileFeed(name: "Room terminal receipts", patterns: ["~/.ragnarok/terminal-receipts.jsonl"], parse: Parsers.terminalReceipts),
            FileFeed(name: "Alexus chat (Heimdall)", patterns: ["~/.ragnarok/heimdall-chat.jsonl"], parse: Parsers.chat),
        ]
        let ssh = [
            SSHFeed(name: "AI SSH commands (Alexus)",
                    remote: "tail -n 300 -F /var/log/ragnarok/ai_ssh_receipts.jsonl", parse: Parsers.alexusReceipts),
            SSHFeed(name: "auditd AI activity (Alexus)",
                    remote: "tail -n 300 -F /var/log/audit/audit.log | grep --line-buffered 'key=\"ai_'", parse: Parsers.audit),
            SSHFeed(name: "Shared room (Alexus)", remote: "python3 \(RoomModel.remote) watch", parse: Parsers.room),
        ]
        return (files, ssh)
    }
}
