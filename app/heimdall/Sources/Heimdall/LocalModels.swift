import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Models that run on this Mac: LM Studio (its local server) and Apple's on-device model.
@MainActor
final class LocalModels: ObservableObject {
    @Published var lmModels: [String] = []
    @Published var lmStatus = "Checking the server…"
    @Published var appleStatus = "Checking Apple Intelligence…"

    nonisolated static let lmStudio = "http://127.0.0.1:1234"

    /// Same rule as LocalAI's ServerAPI.normalizedBase: "127.0.0.1:1234", ".../v1", ".../api/tags" -> scheme://host:port
    nonisolated static func base(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = lmStudio }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/v1/models", "/v1", "/api/tags", "/api"] where s.hasSuffix(suffix) { s.removeLast(suffix.count); break }
        return s
    }
    nonisolated static let lmDisk = ("~/.lmstudio/models" as NSString).expandingTildeInPath
    /// Apple's on-device model comes in two kinds; "general" is the chat one.
    static let appleModels = [("general", "Apple on-device — general"), ("contentTagging", "Apple on-device — tagging")]

    /// Works out what the server is the way LocalAI does: Ollama answers /api/tags, OpenAI-style servers
    /// (LM Studio, llama.cpp, vLLM…) answer /v1/models. Chat then goes to /v1/chat/completions, which both serve.
    func refresh(server: String = LocalModels.lmStudio) {
        let b = Self.base(server)
        Task.detached {
            func get(_ path: String) -> [String: Any]? {
                let (c, out, _) = Gate.run("/usr/bin/curl", ["-sS", "-m", "4", b + path])
                return c == 0 ? (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] : nil
            }
            var kind = "", served: [String] = []
            if let tags = get("/api/tags"), let list = tags["models"] as? [[String: Any]] {
                kind = "Ollama"; served = list.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
            } else if let models = get("/v1/models"), let list = models["data"] as? [[String: Any]] {
                kind = "OpenAI-style"; served = list.compactMap { $0["id"] as? String }
            }
            served = served.filter { !$0.contains("embed") }.sorted()
            let code: Int32 = kind.isEmpty ? 1 : 0
            // downloaded models on disk: ~/.lmstudio/models/<publisher>/<model>
            let fm = FileManager.default
            let disk = ((try? fm.contentsOfDirectory(atPath: Self.lmDisk)) ?? []).flatMap { pub in
                ((try? fm.contentsOfDirectory(atPath: Self.lmDisk + "/" + pub)) ?? []).filter { !$0.hasPrefix(".") }.map { "\(pub)/\($0)" }
            }.sorted()
            let status: String
            if code == 0 { status = "Connected to \(kind) server at \(b) · \(served.count) model\(served.count == 1 ? "" : "s")" }
            else if disk.isEmpty { status = "Nothing answering at \(b)." }
            else { status = "Nothing answering at \(b). Showing the \(disk.count) LM Studio model\(disk.count == 1 ? "" : "s") on disk, which can't answer until LM Studio's server is running. (Your LocalAI app can run them without LM Studio.)" }
            let list = served.isEmpty ? disk : served
            let apple = Self.appleAvailability()
            await MainActor.run { self.lmModels = list; self.lmStatus = status; self.appleStatus = apple }
        }
    }

    nonisolated static func appleAvailability() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple's on-device model is ready. It runs on this Mac and nothing leaves it."
            case .unavailable(let why): return "Apple's on-device model isn't available: \(why)"
            }
        }
        #endif
        return "Apple's on-device model needs macOS 26 or later."
    }

    /// Added to the instructions when the model has the web_search tool.
    /// Two passes, because with the chat persona in its instructions the on-device model doesn't call the tool: it
    /// writes a pretend "web_search{query:…}" as text, or says it isn't allowed to browse (11-08, a drive-time
    /// question). Pass 1 is a plain session that only has the tool and decides whether to search; pass 2 is the persona,
    /// with no tools, answering from what pass 1 found.
    static let appleSearchPass = "You decide whether a question needs the web, and if so you search it. If the question is about anything current or real-world (travel times, prices, hours, news, versions, places, products, people) or \(LocalConfig.owner) asks to look something up, call web_search with good search words, then reply with only the facts the results give that answer it, each with its URL. If the question does not need the web (chat, opinions, code they pasted), reply with exactly: NONE"
    static let appleWebNote = "\n\nWeb results for \(LocalConfig.owner)'s question are below; Heimdall searched the web for you just now. Answer their question from them, in character, and end with Sources: and the URLs you used. If they don't answer it, say you couldn't find it. Don't say you can't browse or need an API key: the search already happened."

    /// One streamed reply from Apple's on-device model. `update` gets the text so far.
    /// webSearch: give the model the web_search tool (DuckDuckGo, then Bing; the search words leave this Mac).
    /// The searches it made are listed under the reply, so you can see what the answer rests on.
    static func appleReply(history: [[String: String]], useCase: String, webSearch: Bool = false,
                           update: @escaping (String) -> Void) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            var system = history.first { $0["role"] == "system" }?["content"] ?? ""
            let turns = history.filter { $0["role"] != "system" }
            guard let last = turns.last?["content"] else { return "" }
            // the model keeps no memory between calls here, so earlier turns go in as plain text
            let earlier = turns.dropLast().suffix(12).map { ($0["role"] == "user" ? "\(LocalConfig.owner): " : "Alexus: ") + ($0["content"] ?? "") }
            let prompt = earlier.isEmpty ? last : "Conversation so far:\n" + earlier.joined(separator: "\n") + "\n\n\(LocalConfig.owner): " + last
            let model = SystemLanguageModel(useCase: useCase == "contentTagging" ? .contentTagging : .general)
            let log = AppleToolLog()
            if webSearch && useCase != "contentTagging" {
                update("[checking whether this needs a web search…]")
                let finder = LanguageModelSession(model: model, tools: [AppleWebSearchTool(log: log)], instructions: appleSearchPass)
                let found = (try? await finder.respond(to: last).content) ?? ""
                if !log.entries.isEmpty {
                    let raw = log.results.joined(separator: "\n\n")
                    system += appleWebNote + "\n\nWhat the search found:\n" + String(found.prefix(1200)) +
                              "\n\nSearch results:\n" + String(raw.prefix(1500))
                }
                update("")
            }
            let session = LanguageModelSession(model: model, instructions: system)
            var text = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    text = snapshot.content
                    update(text)
                }
            } catch { text += "\n[Apple's model couldn't answer: \(error.localizedDescription)]" }
            let searched = log.entries
            if !searched.isEmpty {
                text += "\n\n[searched the web: " + searched.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
                update(text)
            } else if webSearch {
                text += "\n\n[no web search for this answer]"
                update(text)
            }
            return text
        }
        #endif
        return "[Apple's on-device model needs macOS 26 or later.]"
    }
}

/// The searches one Apple reply made, so they can be shown under it.
final class AppleToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = [], outs: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    func result(_ s: String) { lock.lock(); outs.append(s); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return list }
    var results: [String] { lock.lock(); defer { lock.unlock() }; return outs }
}

#if canImport(FoundationModels)
/// web_search for Apple's on-device model, using the same search as the Room terminal's local model (WebTools.search).
/// Results are cut short because the on-device model has a small context window.
@available(macOS 26.0, *)
struct AppleWebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current information. Returns titles, URLs and short snippets."
    let log: AppleToolLog

    @Generable
    struct Arguments {
        @Guide(description: "the search words")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let q = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "error: no search words" }
        log.add(q)
        let r = await WebTools.search(q)
        let out = r.count > 2000 ? String(r.prefix(2000)) + "\n…" : r
        log.result(out)
        return out
    }
}
#endif
