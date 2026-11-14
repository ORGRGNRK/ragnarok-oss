import Foundation
import Security

/// Cloud models for the chat tab, called straight over HTTPS (no `claude -p`, no CLI in between).
/// Keys live in this Mac's keychain (service "ragnarok-chat", one item per provider); they are sent only to that
/// provider, never logged, and never put on a command line. Everything else in a chat (the persona, Alexus's boot
/// notes, matching notes from the owner's files) goes to whichever provider is picked — the chat tab says so.
enum CloudChat {
    struct Provider: Identifiable, Hashable {
        let id: String, name: String, base: String
        let anthropic: Bool          // Anthropic's Messages API; everything else speaks the OpenAI chat format
        let suggested: [String]      // shown before "Load models" has run
        let keyHelp: String
    }

    nonisolated static let providers: [Provider] = [
        Provider(id: "anthropic", name: "Anthropic (Claude)", base: "https://api.anthropic.com", anthropic: true,
                 suggested: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"],
                 keyHelp: "platform.claude.com → API keys"),
        Provider(id: "openai", name: "OpenAI", base: "https://api.openai.com/v1", anthropic: false, suggested: [],
                 keyHelp: "platform.openai.com → API keys"),
        Provider(id: "xai", name: "xAI (Grok)", base: "https://api.x.ai/v1", anthropic: false, suggested: [],
                 keyHelp: "console.x.ai → API keys"),
        Provider(id: "gemini", name: "Google Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", anthropic: false,
                 suggested: [], keyHelp: "aistudio.google.com → Get API key"),
        Provider(id: "openrouter", name: "OpenRouter (many models)", base: "https://openrouter.ai/api/v1", anthropic: false,
                 suggested: [], keyHelp: "openrouter.ai → Keys"),
    ]
    nonisolated static func provider(_ id: String) -> Provider { providers.first { $0.id == id } ?? providers[0] }

    nonisolated static let anthropicVersion = "2026-10-21"
    /// Models that take Anthropic's server-side fallback ("default" routing when a safety check declines a request).
    nonisolated static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"]

    // MARK: keys (keychain)

    nonisolated static let keyService = "ragnarok-chat"

    nonisolated static func key(_ id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyService,
                                kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    nonisolated static func setKey(_ id: String, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return false }
        removeKey(id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyService,
                                kSecAttrAccount as String: id, kSecAttrLabel as String: "Ragnarok chat: \(provider(id).name)",
                                kSecValueData as String: Data(v.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func removeKey(_ id: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyService,
                                kSecAttrAccount as String: id]
        SecItemDelete(q as CFDictionary)
    }

    /// An error text from a provider, with the key taken out in case the provider echoed it back.
    nonisolated static func clean(_ s: String, key: String) -> String {
        var t = s
        if key.count >= 8 { t = t.replacingOccurrences(of: key, with: "[key]") }
        return Scrub.clean(t)
    }

    // MARK: requests

    /// Anthropic wants the system text on its own and turns that start with the user and alternate.
    nonisolated static func anthropicMessages(_ history: [[String: String]]) -> (system: String, messages: [[String: String]]) {
        var system: [String] = [], msgs: [[String: String]] = []
        for m in history {
            let role = m["role"] ?? "user", text = m["content"] ?? ""
            if role == "system" { if !text.isEmpty { system.append(text) }; continue }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let r = role == "assistant" ? "assistant" : "user"
            if let last = msgs.last, last["role"] == r { msgs[msgs.count - 1]["content"] = (last["content"] ?? "") + "\n\n" + text }
            else { msgs.append(["role": r, "content": text]) }
        }
        if msgs.first?["role"] == "assistant" { msgs.insert(["role": "user", "content": "(chat started)"], at: 0) }
        return (system.joined(separator: "\n\n"), msgs)
    }

    nonisolated static func request(_ p: Provider, model: String, key: String, history: [[String: String]]) throws -> URLRequest {
        var body: [String: Any]
        var req: URLRequest
        if p.anthropic {
            guard let u = URL(string: p.base + "/v1/messages") else { throw err("bad address") }
            req = URLRequest(url: u)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            let (system, msgs) = anthropicMessages(history)
            body = ["model": model, "max_tokens": 64000, "stream": true, "messages": msgs]
            if !system.isEmpty { body["system"] = system }
            if fallbackModels.contains(model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        } else {
            guard let u = URL(string: p.base + "/chat/completions") else { throw err("bad address") }
            req = URLRequest(url: u)
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body = ["model": model, "stream": true, "messages": history]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    nonisolated static func err(_ s: String) -> NSError { NSError(domain: "cloud", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// One streamed SSE line → text to add, or an error/notice to show.
    enum Piece: Equatable { case text(String), error(String), note(String), done, skip }

    nonisolated static func parse(line: String, anthropic: Bool) -> Piece {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let d = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return .skip }
        if let e = d["error"] {
            let m = (e as? [String: Any])?["message"] as? String ?? "\(e)"
            return .error(m)
        }
        if anthropic {
            switch d["type"] as? String {
            case "content_block_delta":
                let delta = d["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String { return .text(t) }
            case "message_delta":
                if (d["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { return .note("[The model declined this one.]") }
                if (d["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" { return .note("[Reply cut off at the length limit.]") }
            case "message_stop": return .done
            default: break
            }
            return .skip
        }
        if let t = ((d["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String { return .text(t) }
        return .skip
    }

    /// Streams one reply. `onText` gets each piece as it arrives. Returns nil when it went fine, else what went wrong.
    static func stream(_ p: Provider, model: String, history: [[String: String]], onText: @escaping @MainActor (String) -> Void) async -> String? {
        guard let key = key(p.id) else { return "No \(p.name) key on this Mac yet: click \"Set key…\" (\(p.keyHelp))." }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return "Pick or type a \(p.name) model first." }
        do {
            let req = try request(p, model: model, key: key, history: history)
            let (stream, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                var body = ""
                for try await line in stream.lines { body += line; if body.count > 4000 { break } }
                let msg = ((try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                return "\(p.name) said HTTP \(code): " + clean(msg ?? String(body.prefix(300)), key: key)
            }
            for try await line in stream.lines {
                try Task.checkCancellation()
                switch parse(line: line, anthropic: p.anthropic) {
                case .text(let t): await onText(t)
                case .note(let n): await onText("\n" + n)
                case .error(let e): return "\(p.name): " + clean(e, key: key)
                case .done: return nil
                case .skip: continue
                }
            }
            return nil
        } catch is CancellationError {
            return "[stopped]"
        } catch {
            AppLog.error("cloud-chat-\(p.id)", error)
            return "Couldn't reach \(p.name): " + clean(error.localizedDescription, key: key)
        }
    }

    /// The provider's model list (GET /models). Empty when there's no key or it can't be read.
    static func models(_ p: Provider) async -> [String] {
        guard let key = key(p.id), let u = URL(string: p.base + (p.anthropic ? "/v1/models?limit=100" : "/models")) else { return [] }
        var req = URLRequest(url: u); req.timeoutInterval = 20
        if p.anthropic { req.setValue(key, forHTTPHeaderField: "x-api-key"); req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version") }
        else { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let arr = o["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.sorted()
    }
}
