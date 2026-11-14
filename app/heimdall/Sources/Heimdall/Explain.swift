import CryptoKit
import Foundation
import SwiftUI

/// "What does editing this file do?" — an AI reads a file (plus who in the repo refers to it) and writes a short
/// colour-coded markdown note. Notes are saved as .md in ~/Library/Application Support/Heimdall/explain, keyed by
/// path, and marked stale when the file changes. Files over the size cap and non-text files are skipped.
@MainActor
final class Explainer: ObservableObject {
    enum Engine: String, CaseIterable, Identifiable { case local, claude; var id: String { rawValue } }
    struct Note { let path: String; let risk: String; let markdown: String; let stale: Bool; let by: String }

    @Published var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "explainEngine") ?? "") ?? .local {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "explainEngine") }
    }
    @Published var working: String?          // path being explained right now
    @Published var queue: [String] = []      // waiting (folder scan)
    @Published var version = 0               // bumps when a note is written, so the tree redraws its dots
    @Published var failed: Set<String> = []  // couldn't explain this session (not saved, so it's retried next time)
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Report item 10: files that look like secrets are never sent to any AI.
    nonisolated static func isSensitive(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        let ext = (n as NSString).pathExtension
        if n.hasPrefix(".env") || n.hasPrefix("id_rsa") || n.hasPrefix("id_ed25519") || n.hasPrefix("id_ecdsa") { return true }
        if ["pem", "key", "p12", "p8", "pfx", "keychain", "kdbx", "age", "gpg", "asc", "jks"].contains(ext) { return true }
        if [".netrc", ".npmrc", ".pypirc", "credentials", "known_hosts", "authorized_keys", "scrub-values"].contains(n) { return true }
        return ["secret", "token", "password", "passwd", "credential", "apikey", "api_key", "api-key", "private"].contains { n.contains($0) }
    }

    /// Notes live in Application Support. The selftest points this at a temp folder, because the proof
    /// sandbox allows writes only under temp directories. `nonisolated(unsafe)` is required: a mutable
    /// static on this MainActor class cannot be `nonisolated`, and the note helpers run off the main actor.
    nonisolated(unsafe) static var dir = NSHomeDirectory() + "/Library/Application Support/Heimdall/explain"
    nonisolated static let maxRead = 14_000

    nonisolated static func noteFile(_ path: String) -> String {
        let h = SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir + "/" + h + ".md"
    }

    /// Size + modified time: if either changes, the note is stale.
    nonisolated static func stamp(_ path: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let size = a?[.size] as? Int ?? -1
        let mod = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mod))"
    }

    /// Saved note: a small header (path, stamp, risk, engine) then the markdown.
    nonisolated static func load(_ path: String) -> Note? {
        guard let s = try? String(contentsOfFile: noteFile(path), encoding: .utf8) else { return nil }
        var head: [String: String] = [:]
        var body = s
        if s.hasPrefix("<!--"), let end = s.range(of: "-->") {
            for l in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { head[kv[0]] = kv[1] }
            }
            body = String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard head["path"] == path else { return nil }
        if head["by"] == "heimdall" && body.hasPrefix("_Couldn't explain") { return nil }   // old saved failures: retry them
        return Note(path: path, risk: head["risk"] ?? "unknown", markdown: body, stale: head["stamp"] != stamp(path), by: head["by"] ?? "?")
    }

    nonisolated static func save(_ path: String, risk: String, markdown: String, by: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let s = "<!--\npath: \(path)\nstamp: \(stamp(path))\nrisk: \(risk)\nby: \(by)\nwritten: \(ISO8601DateFormatter().string(from: Date()))\n-->\n\n" + markdown + "\n"
        try? s.write(toFile: noteFile(path), atomically: true, encoding: .utf8)
    }

    /// The RISK: line the model is told to end with. Anything else counts as unknown.
    nonisolated static func risk(in text: String) -> String {
        for line in text.split(separator: "\n").reversed() {
            let l = line.lowercased()
            guard let k = l.range(of: "risk:") else { continue }
            // K2: the FIRST level word after "RISK:" ("low (it is not high)" is low), not the scariest word anywhere
            let after = l[k.upperBound...]
            let hits = ["high", "medium", "low"].compactMap { r in after.range(of: r).map { (r, $0.lowerBound) } }
            if let first = hits.min(by: { $0.1 < $1.1 }) { return first.0 }
        }
        return "unknown"
    }

    /// Nearest folder above `path` with a .git in it (the repository), if any.
    nonisolated static func repoRoot(_ path: String) -> String? {
        var d = (path as NSString).deletingLastPathComponent
        while d.count > 1 {
            if FileManager.default.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Files in the repo that mention this file's name (git grep, tracked files only, max 12).
    nonisolated static func references(_ path: String, repo: String) -> [String] {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard base.count >= 3 else { return [] }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "grep", "-l", "-F", "--", base]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let rel = String(path.dropFirst(repo.count + 1))
        return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0 != rel }.prefix(12).map { $0 }
    }

    nonisolated static let system = """
    You explain code files to \(LocalConfig.owner), who owns them and is not a programmer. You are given one file from their Mac and \
    some context. Write a short markdown note about what EDITING this file will do. Use exactly this shape:

    ## What it is
    One or two plain sentences.

    ## If you edit it
    - SAFE: things that are fine to change here and what they affect
    - CAREFUL: changes that can break something, and what would break
    - BREAKS: changes that will certainly break things (only if there are any)

    ## Connected to
    - the other files or programs that use it (only ones named in the context)

    RISK: low | medium | high   (one word: how risky editing this file is overall)

    Only say what the file and context show. If you can't tell, say "not clear from the file". Keep it under 200 words.
    """

    /// The user message: path, repo, who references it, a bit of the repo's README/AGENTS, then the file.
    nonisolated static func context(_ path: String, text: String) -> String {
        var s = "File: \(path)\n"
        if let repo = repoRoot(path) {
            s += "Repository: \(repo)\n"
            let refs = references(path, repo: repo)
            s += refs.isEmpty ? "No other tracked file in the repo mentions its name.\n" : "Files in the repo that mention its name:\n" + refs.map { "- " + $0 }.joined(separator: "\n") + "\n"
            for doc in ["AGENTS.md", "README.md", "CLAUDE.md"] {
                if let d = try? String(contentsOfFile: repo + "/" + doc, encoding: .utf8) {
                    s += "\nFrom the repo's \(doc) (start):\n" + String(d.prefix(1500)) + "\n"; break
                }
            }
        } else { s += "Not inside a git repository.\n" }
        let body = text.count > maxRead ? String(text.prefix(maxRead)) + "\n… (cut at \(maxRead) characters)" : text
        s += "\n----- begin file -----\n" + body + "\n----- end file -----\n"
        return s
    }

    /// Ask the chosen AI. Local = whatever the Alexus tab's "Run on" is set to; claude = `claude -p --model haiku`.
    nonisolated static func ask(_ engine: Engine, prompt: String) async -> (String, String) {
        switch engine {
        case .claude:
            guard let exe = AITerminal.which("claude") else { return ("[claude isn't installed on this Mac]", "claude") }
            return await withCheckedContinuation { cont in
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["-p", "--model", "haiku", system + "\n\n" + prompt]
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "HEIMDALL_LAUNCHER")
                p.environment = env
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                p.terminationHandler = { _ in
                    cont.resume(returning: (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "claude haiku"))
                }
                do { try p.run() } catch { cont.resume(returning: ("[couldn't start claude: \(error.localizedDescription)]", "claude")) }
            }
        case .local:
            let b = AITerminal.localBackend()
            let label = AITerminal.backendLabel(b)
            if case .apple(let useCase) = b {
                let short = String(prompt.prefix(6000))
                let r = await LocalModels.appleReply(history: [["role": "system", "content": system], ["role": "user", "content": short]], useCase: useCase) { _ in }
                return (r, label)
            }
            do {
                let r = try await WebTools.chat(b, messages: [["role": "system", "content": system], ["role": "user", "content": prompt]], tools: false)
                return (r["content"] as? String ?? "", label)
            } catch { return ("[can't reach \(label): \(error.localizedDescription)]", label) }
        }
    }

    // MARK: running

    /// auto: true when it came from just clicking a file. Then only the local engine runs it; with claude, file
    /// contents leave the Mac, so that needs the Explain button (report item 10).
    func explain(_ paths: [String], auto: Bool = false) {
        if auto && engine == .claude { return }
        for p in paths where !queue.contains(p) && working != p && !Self.isSensitive(p) { queue.append(p) }
        guard task == nil else { return }
        let gen = generation
        task = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == gen, let next = self.queue.first {
                self.queue.removeFirst()
                self.working = next
                let engine = self.engine
                let ok = await Task.detached { () -> Bool in
                    guard let d = FileManager.default.contents(atPath: next), d.count <= WorkspaceModel.maxBytes,
                          let text = String(data: d, encoding: .utf8) else { return false }
                    // secrets inside ordinary files are scrubbed locally before anything is sent
                    let (reply, by) = await Self.ask(engine, prompt: Self.context(next, text: Scrub.clean(text)))
                    let md = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !md.isEmpty, !md.hasPrefix("[") else { return false }
                    Self.save(next, risk: Self.risk(in: md), markdown: md, by: by)
                    return true
                }.value
                guard self.generation == gen else { break }
                // report item 11: a failure is not saved as the note, so the file is tried again next time
                if ok { self.failed.remove(next) } else { self.failed.insert(next) }
                self.working = nil; self.version += 1
            }
            // report item 12: only the current run clears the slot (a stop() + explain() may have started a new one)
            if let self, self.generation == gen { self.task = nil; self.working = nil }
        }
    }

    func stop() { generation += 1; task?.cancel(); task = nil; queue = []; working = nil }

    /// Text files directly in a folder (not subfolders), same filter as the explorer.
    nonisolated static func files(in dir: String) -> [String] {
        WorkspaceModel.list(dir).filter { !$0.isDir }.map(\.path)
    }

    nonisolated static func color(_ risk: String) -> Color {
        switch risk { case "low": .green; case "medium": .orange; case "high": .red; default: .gray }
    }
}

/// Renders the note: headings bold, SAFE/CAREFUL/BREAKS lines green/orange/red, inline markdown kept.
struct ExplainNoteView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                if line.drop(while: { $0 == "#" || $0 == " " || $0 == "*" }).uppercased().hasPrefix("RISK:") {
                    let r = Explainer.risk(in: line)
                    Text("Risk: \(r)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Explainer.color(r).opacity(0.2)).foregroundStyle(Explainer.color(r)).clipShape(Capsule())
                } else if line.hasPrefix("#") {
                    Text(Self.inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.callout.bold()).padding(.top, 4)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(Self.inline(line)).font(.callout).foregroundStyle(Self.tint(line))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func tint(_ line: String) -> Color {
        let u = line.uppercased()
        if u.contains("BREAKS:") { return .red }
        if u.contains("CAREFUL:") { return .orange }
        if u.contains("SAFE:") { return .green }
        return .primary
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Bottom of the explorer: the note for the file you're on, with Explain / Re-scan / Scan folder.
