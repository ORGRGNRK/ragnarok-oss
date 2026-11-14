import Foundation
import SwiftUI

/// The Room tab's terminal: one conversation, and the owner can swap which AI answers at any point.
/// Each message runs that provider's CLI once in headless mode, in the explorer's folder, with a recap of the
/// recent conversation (so an AI picks up where another left off). "zsh" sends the line to the shared Heimdall shell.
/// Tools: claude runs with default permissions (anything needing approval is refused), 
/// grok gets no auto-approve flag. Each CLI keeps its own transcript, which the Timeline already shows.
@MainActor
final class AITerminal: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case claude, grok, codex, alexus, zsh
        var id: String { rawValue }
        var label: String { self == .alexus ? "local" : rawValue }
        var binary: String? {
            switch self { case .claude: "claude"; case .grok: "grok"; case .codex: "codex"
                          case .alexus: "curl"; case .zsh: nil }
        }
    }
    struct Turn: Identifiable, Hashable { let id = UUID(); let who: String; let isUser: Bool; var text: String }

    @Published var provider: Provider = Provider(rawValue: UserDefaults.standard.string(forKey: "roomTermProvider") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "roomTermProvider") }
    }
    @Published var turns: [Turn] = []
    @Published var busy = false
    /// What's typed in the terminal box. Published so the Room can hand a message over ("→ terminal").
    @Published var draft = ""
    /// Show the terminal AI the latest room messages and open tasks.
    @Published var seesRoom: Bool = UserDefaults.standard.object(forKey: "termSeesRoom") as? Bool ?? true {
        didSet { UserDefaults.standard.set(seesRoom, forKey: "termSeesRoom") }
    }
    private var proc: Process?
    private var task: Task<Void, Never>?

    /// On Ragnarok's PATH, which LoginPath set from the owner's own shell at launch.
    nonisolated static func which(_ name: String) -> String? { LoginPath.which(name) }

    func available(_ p: Provider) -> Bool { p.binary.map { Self.which($0) != nil } ?? true }

    /// The text sent to the AI: a short recap of the last turns (any provider), then the owner's message.
    nonisolated static func prompt(_ text: String, history: [Turn], cwd: String, file: (path: String, text: String, dirty: Bool)? = nil, textOnly: Bool = false, notes: String? = nil, room: String? = nil, failures: String? = nil) -> String {
        let recent = history.suffix(8).map { t -> String in
            let body = t.text.count > 1500 ? String(t.text.prefix(1500)) + " …" : t.text
            return "[\(t.who)] \(body)"
        }
        var s = "You are answering \(LocalConfig.owner) in the terminal of their Ragnarok app (built as Heimdall) on their Mac. Working folder: \(cwd)\n"
        s += "\(LocalConfig.owner) can switch which AI answers at any time, so earlier replies may be from other AIs.\n"
        s += "Never write lines that look like app or system messages (for example starting with [heimdall]). Only say something was done if you actually did it.\n"
        if textOnly {
            s += "IMPORTANT: you are text only. You can explain and give instructions, but you cannot run commands, install software, "
            s += "or read or change files. Never claim or pretend that anything ran.\n"
        } else {
            s += "To find more of \(LocalConfig.owner)'s code or notes, run `heimdall-recall \"what you're looking for\"` (searches all of ~/Developer by meaning; "
            s += "add --failures for past failures on this Mac) instead of reading whole repositories. "
            s += "After you answer, Heimdall checks the files you say you created, changed or deleted against the disk and shows \(LocalConfig.owner) a receipt.\n"
        }
        if let file {
            let cap = 8000
            let body = file.text.count > cap ? String(file.text.prefix(cap)) + "\n… (cut at \(cap) characters; read the file for the rest)" : file.text
            s += "\nThe file open in \(LocalConfig.owner)'s editor (\"this\" usually means it): \(file.path)"
            s += file.dirty ? " (has unsaved edits; the text below is what's on their screen)\n" : "\n"
            s += "----- begin file -----\n" + body + "\n----- end file -----\n"
        }
        if let room { s += "\n" + room + "\n" }
        if !recent.isEmpty { s += "\nRecent conversation:\n" + recent.joined(separator: "\n") + "\n" }
        if let notes { s += "\n" + notes + "\n" }
        if let failures { s += "\n" + failures + "\n" }
        s += "\n\(LocalConfig.owner) now says:\n" + text
        return s
    }

    /// A terminal reply as posted to the room. The room names the poster from the ssh login (the owner), so the
    /// text says which AI actually wrote it.
    nonisolated static func shareText(_ t: Turn) -> String {
        let who = t.who == "alexus" ? "local model" : t.who
        let body = t.text.replacingOccurrences(of: "📚 found related notes in your files\n", with: "")
        return "(\(who)'s reply in the Heimdall terminal, shared by \(LocalConfig.owner))\n" + (body.count > 3000 ? String(body.prefix(3000)) + " …" : body)
    }

    /// The shared room as context: the last 12 messages and the open tasks, as the room shows them.
    nonisolated static func roomContext(_ msgs: [RoomModel.Msg], tasks: [(id: String, text: String, by: String, state: String, owner: String?)]) -> String? {
        guard !msgs.isEmpty else { return nil }
        var s = "The shared room on Alexus (\(LocalConfig.owner) and their AIs talk there; you can't post to it, \(LocalConfig.owner) can share your reply). Latest messages, oldest first:\n"
        s += msgs.suffix(12).map { m in "[\(m.by)] " + RoomView.line(m, msgs).oneLine(400) }.joined(separator: "\n")
        if !tasks.isEmpty {
            s += "\nOpen room tasks:\n" + tasks.prefix(10).map { "- \($0.text.oneLine(200)) (\($0.state)\($0.owner.map { " by " + $0 } ?? ""))" }.joined(separator: "\n")
        }
        return s
    }

    /// Returns false when nothing was started (busy, empty), so the caller keeps the typed text (report item 4).
    @discardableResult
    func send(_ text: String, cwd: String, shell: ShellSession, file: (path: String, text: String, dirty: Bool)? = nil, room: String? = nil) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if provider == .zsh { shell.start(); shell.send(t); return true }
        guard !busy else { return false }
        guard let bin = provider.binary, let exe = Self.which(bin) else {
            turns.append(Turn(who: "heimdall", isUser: false, text: "\(provider.rawValue) isn't installed on this Mac.")); return false
        }
        let history = turns
        turns.append(Turn(who: "owner", isUser: true, text: t))
        let provider = self.provider
        turns.append(Turn(who: provider.rawValue, isUser: false, text: ""))
        let idx = turns.count - 1
        // Converse-style recall first: the parts of the owner's own files that match their message, by meaning.
        busy = true
        let apple: Bool = { if case .apple = Self.localBackend(), provider == .alexus { return true }; return false }()
        task = Task { [weak self] in
            async let n = Recall.notes(for: t, perHit: apple ? 350 : 1200, k: apple ? 3 : 6)
            async let f = apple ? nil : Recall.failures(for: t)
            let (notes, failures) = await (n, f)
            await MainActor.run {
                guard let self else { return }
                self.task = nil
                if Task.isCancelled { self.turns[idx].text = "[stopped]"; self.busy = false; return }
                if idx < self.turns.count {
                    var pre = ""
                    if notes != nil { pre += "📚 found related notes in your files\n" }
                    if failures != nil { pre += "⚠️ past failures that look related were passed along\n" }
                    self.turns[idx].text = pre
                }
                let full = Self.prompt(t, history: history, cwd: cwd, file: file, textOnly: provider == .alexus, notes: notes, room: room, failures: failures)
                if provider == .alexus { self.runAlexus(full, idx: idx, question: t, cwd: cwd); return }
                self.launch(full, idx: idx, exe: exe, bin: bin, provider: provider, cwd: cwd, question: t)
            }
        }
        return true
    }

    private func launch(_ full: String, idx: Int, exe: String, bin: String, provider: Provider, cwd: String, question: String) {
        let started = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"; env["TERM"] = "dumb"
        env.removeValue(forKey: "HEIMDALL_LAUNCHER")
        p.environment = env
        var stdin: Data?
        switch provider {
        case .claude: p.arguments = ["-p", full]
        case .grok:   p.arguments = ["--cwd", cwd, "-p", full]
        case .codex:  p.arguments = ["exec", full]
        case .alexus:
            let model = UserDefaults.standard.string(forKey: "chatModel") ?? "llama3.2:3b"
            let body: [String: Any] = ["model": model, "stream": false, "messages": [
                ["role": "system", "content": Self.textOnlySystem], ["role": "user", "content": full]]]
            stdin = try? JSONSerialization.data(withJSONObject: body)
            p.arguments = ["-sS", "--max-time", "600", "-H", "Content-Type: application/json", "--data-binary", "@-", ChatModel.ollama.absoluteString]
        case .zsh: return
        }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let isAlexus = provider == .alexus
        // report item 5: stderr is drained as it comes (a CLI writing >64 KB of stderr used to block forever)
        let errBuf = RunBuffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else if errBuf.data.count < 256_000 { errBuf.add(d) }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in
                guard let self, idx < self.turns.count else { return }
                self.turns[idx].text += isAlexus ? s : ShellSession.clean(s)
                self.checkLogin(idx)
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            err.fileHandleForReading.readabilityHandler = nil
            let e = String(decoding: errBuf.data + err.fileHandleForReading.availableDataNonBlocking(), as: UTF8.self)
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                if idx < self.turns.count {
                    if !rest.isEmpty { self.turns[idx].text += isAlexus ? String(decoding: rest, as: UTF8.self) : ShellSession.clean(String(decoding: rest, as: UTF8.self)) }
                    if isAlexus { self.turns[idx].text = Self.ollamaText(self.turns[idx].text) }
                    if code != 0 && code != 15 { self.turns[idx].text += "\n[exited \(code)] " + e.oneLine(400) }
                    if code == 15 { self.turns[idx].text += "\n[stopped]" }
                    self.turns[idx].text = self.turns[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.busy = false; self.proc = nil
                self.receipt(idx: idx, provider: provider.rawValue, question: question, cwd: cwd, start: started, exit: code)
            }
        }
        do {
            try p.run(); proc = p; busy = true
            if let stdin { inp.fileHandleForWriting.write(stdin) }
            try? inp.fileHandleForWriting.close()
        } catch {
            AppLog.error("ai-terminal", error, context: "could not start \(bin)")
            turns[idx].text = "[couldn't start \(bin): \(error.localizedDescription)]"
            busy = false
        }
    }

    /// Small local models follow rules far better from the system message than from the user text (tested 2026-11-01).
    nonisolated static let textOnlySystem = "You are a helpful assistant in the terminal of \(LocalConfig.owner)'s Ragnarok app on their Mac (macOS, Apple Silicon). You have two tools: web_search (search the web) and fetch_page (read one web page). For anything current, about a specific product or tool, or anything you are not sure of, call web_search first, then fetch_page on the most official result, and answer only from what you read, listing the source URLs at the end. If the pages do not say, say you could not find it. You can explain and give step-by-step instructions and commands for \(LocalConfig.owner) to run themselves, but you cannot run commands, install software, or read or change files on their Mac, so never claim or pretend that anything ran, was installed or was switched, and never write lines that look like system messages such as [heimdall]. If \(LocalConfig.owner) wants something actually done, tell them the claude or grok button can do it, or they can run your commands with the zsh button."

    nonisolated static func ollamaText(_ raw: String) -> String {
        guard let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return raw }
        if let m = d["message"] as? [String: Any], let c = m["content"] as? String { return c }
        if let e = d["error"] as? String { return "[Alexus: \(e)]" }
        return raw
    }

    func stop() { proc?.terminate(); task?.cancel() }

    /// Apple's on-device model can't call tools, so its instructions don't mention any.
    nonisolated static let appleSystem = "You are a helpful assistant in \(LocalConfig.owner)'s Ragnarok app on their Mac. \(LocalConfig.owner)'s question comes first, then notes from web pages. Reply with a short, direct answer to their question for a Mac: a few sentences or numbered steps, with any commands copied exactly from the notes. Do not repeat or list the notes themselves. End with one line: Sources: and the one or two URLs you used. If the notes don't answer it, say so in one sentence. You cannot run commands or change anything on their Mac, so never claim that anything ran or was installed."

    /// The local model the Alexus tab is set to ("Run on": Alexus / Other server / Apple), read from its saved settings.
    nonisolated static func localBackend() -> WebTools.Backend {
        let d = UserDefaults.standard
        switch d.string(forKey: "chatProvider") ?? "alexus" {
        case "lmstudio": return .openAI(base: d.string(forKey: "chatServerURL") ?? LocalModels.lmStudio, model: d.string(forKey: "chatLMModel") ?? "")
        case "apple": return .apple(useCase: d.string(forKey: "chatAppleModel") ?? "general")
        default: return .ollama(model: d.string(forKey: "chatModel") ?? "llama3.2:3b")
        }
    }

    nonisolated static func backendLabel(_ b: WebTools.Backend) -> String {
        switch b {
        case .ollama(let m): return "Alexus · \(m)"
        case .openAI(let base, let m): return "\(LocalModels.base(base)) · \(m.isEmpty ? "no model picked" : m)"
        case .apple: return "Apple on-device"
        }
    }

    /// The tool loop on its own (also used by `Heimdall --ask-alexus "question"` for testing).
    /// "my files", "our code", "this repo", "heimdall"… — the answer lives in their files, not on the web.
    nonisolated static func aboutOwnStuff(_ q: String) -> Bool {
        let l = q.lowercased()
        if l.range(of: #"\b(my|our|his|this|these)\b[\w\s'-]{0,25}\b(files?|code|codebase|repos?|repository|notes?|scripts?|projects?|apps?|folders?|logs?)\b"#, options: .regularExpression) != nil { return true }
        return ["heimdall", "alexus", "ragnarok", "conveyor", "~/developer", NSUserName().lowercased()].contains { l.contains($0) }
    }

    nonisolated static func alexusAnswer(_ full: String, backend: WebTools.Backend, question: String? = nil,
                                         progress: @escaping (String) async -> Void) async -> String {
        var msgs: [[String: Any]] = [["role": "system", "content": textOnlySystem], ["role": "user", "content": full]]
        // Small models often skip their tools, so Heimdall does the first search itself: search the owner's words,
        // read the top two pages, and hand the model what they say.
        var isApple = false
        if case .apple = backend { isApple = true }
        // Questions about the owner's own files/code are answered from their notes (already in `full`), not a forced web search.
        if let q = question, !aboutOwnStuff(q), !Task.isCancelled {
            await progress("🔎 searching: " + q)
            let found = await WebTools.search(q)
            var notes = "Web search results for \(LocalConfig.owner)'s question (gathered by Heimdall, not by you):\n" + found
            for u in WebTools.topURLs(found, count: 2) {
                await progress("📄 reading: " + u)
                let page = await WebTools.fetch(u)
                // only the parts that match the question (pages start with menus); Apple's model has a small window
                let head = page.prefix { $0 != "\n" }
                let rest = String(page.dropFirst(head.count))
                notes += "\n\n" + head + "\n" + WebTools.relevant(rest, question: q, budget: isApple ? 1500 : 3500)
            }
            if found.hasPrefix("SEARCH FAILED") {
                await progress("⚠️ web search unavailable right now")
                notes += "\n\nThe web search failed, so you have NO sources. Tell \(LocalConfig.owner) in one sentence that the search didn't work and they should try again or use the claude or grok button. Do not answer from memory."
            }
            notes += "\n\nAnswer \(LocalConfig.owner) from these sources. Copy commands and package names exactly as the pages write them; do not change them. List the URLs you used. If they don't answer it, say so (you may call web_search or fetch_page for more)."
            msgs.append(["role": "user", "content": notes])
        }
        if case .apple(let useCase) = backend {
            // Apple's model: no tool calls here, but it gets the search results gathered above.
            let hist = msgs.compactMap { m -> [String: String]? in
                guard let r = m["role"] as? String, let c = m["content"] as? String else { return nil }
                return ["role": r, "content": c]
            }
            // small context window: short instructions, web notes first (trimmed), the owner's message last
            let notes = hist.count > 2 ? hist[2]["content"] ?? "" : ""
            let ask = hist.count > 1 ? hist[1]["content"] ?? "" : ""
            let q = question ?? ""
            let body = "\(LocalConfig.owner)'s question: " + q + "\n\n" + String(notes.prefix(4500)) + "\n\n" + (ask.count > 2500 ? "…" + String(ask.suffix(2500)) : ask)
                + "\n\nNow answer \(LocalConfig.owner)'s question (\"" + q + "\") directly, for a Mac."
            let merged = [["role": "system", "content": appleSystem], ["role": "user", "content": body]]
            if Task.isCancelled { return "[stopped]" }
            return await LocalModels.appleReply(history: merged, useCase: useCase) { _ in }
        }
        do {
            for round in 0..<7 {
                try Task.checkCancellation()
                let reply = try await WebTools.chat(backend, messages: msgs, tools: round < 6)
                let calls = round < 6 ? WebTools.toolCalls(reply) : []
                if calls.isEmpty { return reply["content"] as? String ?? "" }
                var said: [String: Any] = ["role": "assistant", "content": reply["content"] as? String ?? ""]
                if let tc = reply["tool_calls"] { said["tool_calls"] = tc }
                msgs.append(said)
                for c in calls {
                    await progress((c.name == "web_search" ? "🔎 searching: " : c.name == "search_files" ? "📚 searching your files: " : "📄 reading: ") + c.arg)
                    var toolMsg: [String: Any] = ["role": "tool", "content": await WebTools.run(c), "tool_name": c.name]
                    if !c.id.isEmpty { toolMsg["tool_call_id"] = c.id }
                    msgs.append(toolMsg)
                }
            }
            return "[gave up after 6 tool rounds]"
        } catch is CancellationError { return "[stopped]" }
        catch { AppLog.error("ai-terminal-\(backendLabel(backend))", error); return Task.isCancelled ? "[stopped]" : "[Can't reach \(backendLabel(backend)): \(error.localizedDescription)]" }
    }

    /// alexus: Ollama on Alexus with two tools (web_search, fetch_page) run here on the Mac. Up to 6 tool rounds.
    private func runAlexus(_ full: String, idx: Int, question: String, cwd: String) {
        busy = true
        let started = Date()
        let backend = Self.localBackend()
        task = Task { [weak self] in
            let final = await Self.alexusAnswer(full, backend: backend, question: question) { line in
                await MainActor.run {
                    guard let self, idx < self.turns.count else { return }
                    self.turns[idx].text += line + "\n"
                }
            }
            let answer = final
            await MainActor.run {
                guard let self else { return }
                if idx < self.turns.count {
                    let pre = self.turns[idx].text
                    self.turns[idx].text = (pre.isEmpty ? "" : pre + "\n") + answer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.busy = false; self.task = nil
                self.receipt(idx: idx, provider: "local", question: question, cwd: cwd, start: started, exit: 0)
            }
        }
    }

    /// After each answer: measure what changed under the working folder, check the reply's claims, show a
    /// one-line receipt under the reply and append it to ~/.ragnarok/terminal-receipts.jsonl.
    private func receipt(idx: Int, provider: String, question: String, cwd: String, start: Date, exit: Int32) {
        guard idx < turns.count else { return }
        let reply = turns[idx].text
        if reply.hasSuffix("[stopped]") { return }
        Task { @MainActor [weak self] in
            let line = await Task.detached { () -> String in
                let changed = Receipts.changed(since: start, under: cwd)
                let claims = Receipts.claims(in: reply, cwd: cwd, since: start)
                let v = Receipts.verdict(exit: exit, claims: claims)
                Receipts.write(provider: provider, question: question, cwd: cwd, start: start, exit: exit, changed: changed, claims: claims, verdict: v)
                return Receipts.summary(changed: changed, claims: claims, verdict: v, cwd: cwd)
            }.value
            guard let self, idx < self.turns.count else { return }
            self.turns[idx].text += "\n" + line
        }
    }

    /// A CLI that isn't signed in asks a question headless mode can't answer. Stop it and open the
    /// CLI in Terminal, where the owner can answer and sign in themselves.
    private func checkLogin(_ idx: Int) {
        let t = turns[idx].text.lowercased()
        guard Self.needsLogin(t), let p = proc, p.isRunning else { return }
        let name = turns[idx].who
        p.terminate()
        turns.append(Turn(who: "heimdall", isUser: false, text:
            "\(name) isn't signed in. Opened Terminal running `\(name)`: answer its question there and sign in in your browser, then ask again here."))
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"cd ~ && \(name)\""
        let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); o.arguments = ["-e", script]
        try? o.run()
    }

    nonisolated static func needsLogin(_ lower: String) -> Bool {
        (lower.contains("authentication page") || lower.contains("sign in") || lower.contains("log in")) && lower.contains("[y/n]")
    }
}

extension FileHandle {
    /// Whatever is already buffered, without waiting for the writer to close (empty if nothing).
    func availableDataNonBlocking() -> Data {
        let fd = fileDescriptor, flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
        while true { let n = Darwin.read(fd, &buf, buf.count); if n <= 0 { break }; out.append(buf, count: n); if out.count > 1_000_000 { break } }
        return out
    }
}
