import Foundation

/// Which API flavour to talk to. `.auto` probes the server.
enum ServerAPIKind: String, CaseIterable, Identifiable {
    case auto
    case openai
    case ollama

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .openai: return "OpenAI-compatible (LM Studio, llama.cpp, vLLM…)"
        case .ollama: return "Ollama"
        }
    }
}

enum DetectedServerKind: String, Equatable, Sendable {
    case openai
    case ollama

    var label: String { self == .ollama ? "Ollama" : "OpenAI-compatible" }
}

struct ServerModel: Identifiable, Hashable, Sendable {
    let id: String
    var detail: String?
}

enum ServerError: LocalizedError {
    case badURL(String)
    case offline(String)
    case http(Int, String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid server URL: \(s)"
        case .offline(let s): return "Server not reachable at \(s). Is LM Studio / Ollama running?"
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Server returned HTTP \(code)" + (trimmed.isEmpty ? "" : ": \(trimmed.prefix(400))")
        case .protocolError(let s): return s
        }
    }
}

/// One parsed piece of a streamed chat completion.
enum ChatStreamEvent: Sendable {
    case content(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case usage(prompt: Int, completion: Int)
}

/// Thin HTTP client for OpenAI-compatible servers (`/v1/models`, `/v1/chat/completions`)
/// and Ollama (`/api/tags`, `/api/pull`, `/api/show`). Chat always goes through the
/// OpenAI-compatible endpoint, which Ollama also serves at `/v1`.
enum ServerAPI {
    /// "127.0.0.1:1234", "http://localhost:11434/", ".../v1" → scheme://host:port[/prefix]
    static func normalizedBase(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/v1/models", "/v1", "/api/tags", "/api"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    static func url(_ base: URL, _ path: String) -> URL {
        URL(string: base.absoluteString + path) ?? base
    }

    private static func mapTransport(_ error: Error, base: URL) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                .notConnectedToInternet, .dnsLookupFailed, .badServerResponse:
                return ServerError.offline(base.absoluteString)
            default: break
            }
        }
        return error
    }

    private static func send(_ request: URLRequest, base: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw ServerError.http(code, String(decoding: data.prefix(2000), as: UTF8.self))
            }
            return data
        } catch let error as ServerError {
            throw error
        } catch {
            throw mapTransport(error, base: base)
        }
    }

    private static func getJSON(_ base: URL, _ path: String, timeout: TimeInterval = 4) async throws
        -> [String: Any]
    {
        var request = URLRequest(url: url(base, path))
        request.timeoutInterval = timeout
        let data = try await send(request, base: base)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.protocolError("Unexpected (non-JSON) response from \(path)")
        }
        return obj
    }

    /// Detect Ollama (`GET /api/tags` → {"models": [...]}) vs OpenAI-compatible
    /// (`GET /v1/models` → {"data": [...]}).
    static func detect(base: URL, preference: ServerAPIKind) async throws -> DetectedServerKind {
        switch preference {
        case .openai: return .openai
        case .ollama: return .ollama
        case .auto:
            var firstError: Error?
            do {
                let tags = try await getJSON(base, "/api/tags")
                if tags["models"] is [Any] { return .ollama }
            } catch {
                firstError = error
                if case ServerError.offline? = error as? ServerError { throw error }
            }
            do {
                let models = try await getJSON(base, "/v1/models")
                if models["data"] is [Any] { return .openai }
            } catch {
                throw firstError ?? error
            }
            throw ServerError.protocolError(
                "Server at \(base.absoluteString) answered, but neither /api/tags nor /v1/models looked right.")
        }
    }

    static func listModels(base: URL, kind: DetectedServerKind) async throws -> [ServerModel] {
        switch kind {
        case .ollama:
            let obj = try await getJSON(base, "/api/tags")
            let list = obj["models"] as? [[String: Any]] ?? []
            return list.compactMap { m in
                guard let name = (m["name"] as? String) ?? (m["model"] as? String) else { return nil }
                var parts: [String] = []
                if let details = m["details"] as? [String: Any] {
                    if let p = details["parameter_size"] as? String { parts.append(p) }
                    if let q = details["quantization_level"] as? String { parts.append(q) }
                }
                if let size = m["size"] as? Int64 ?? (m["size"] as? NSNumber)?.int64Value {
                    parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                return ServerModel(id: name, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
            }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        case .openai:
            let obj = try await getJSON(base, "/v1/models")
            let list = obj["data"] as? [[String: Any]] ?? []
            return list.compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return ServerModel(id: id, detail: m["owned_by"] as? String)
            }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
    }

    /// Ollama ≥0.6 reports e.g. ["completion","vision","tools"] from /api/show.
    static func ollamaCapabilities(base: URL, model: String) async -> [String]? {
        var request = URLRequest(url: url(base, "/api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let data = try? await send(request, base: base),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["capabilities"] as? [String]
    }

    /// `POST /api/pull` with NDJSON progress lines.
    static func pull(
        base: URL, model: String,
        progress: @escaping @Sendable (_ status: String, _ fraction: Double?) async -> Void
    ) async throws {
        var request = URLRequest(url: url(base, "/api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true,
        ])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 2000 { break }
                }
                throw ServerError.http(code, body)
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let error = obj["error"] as? String {
                    throw ServerError.protocolError("Pull failed: \(error)")
                }
                let status = obj["status"] as? String ?? ""
                var fraction: Double?
                if let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0 {
                    let done = (obj["completed"] as? NSNumber)?.doubleValue ?? 0
                    fraction = min(max(done / total, 0), 1)
                }
                await progress(status, fraction)
                if status == "success" { return }
            }
        } catch let error as ServerError {
            throw error
        } catch {
            throw mapTransport(error, base: base)
        }
    }

    /// `POST /v1/chat/completions` with `stream: true` (Server-Sent Events).
    static func streamChat(base: URL, body: Data) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url(base, "/v1/chat/completions"))
                    request.httpMethod = "POST"
                    // Generous: the server may need to load the model before the first token.
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = body
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(code) {
                        var text = ""
                        for try await line in bytes.lines {
                            text += line + "\n"
                            if text.count > 2000 { break }
                        }
                        throw ServerError.http(code, text)
                    }
                    for try await rawLine in bytes.lines {
                        let line = rawLine.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        for event in try parseChunk(obj) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch let error as ServerError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: mapTransport(error, base: base))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseChunk(_ obj: [String: Any]) throws -> [ChatStreamEvent] {
        if let err = obj["error"] {
            let message =
                (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "\(err)"
            throw ServerError.protocolError("Server error: \(message)")
        }
        var events: [ChatStreamEvent] = []
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
            let delta = first["delta"] as? [String: Any]
        {
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.content(text))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for (offset, call) in calls.enumerated() {
                    let fn = call["function"] as? [String: Any]
                    var args: String?
                    if let s = fn?["arguments"] as? String {
                        args = s
                    } else if let o = fn?["arguments"],
                        let d = try? JSONSerialization.data(withJSONObject: o)
                    {
                        args = String(decoding: d, as: UTF8.self)
                    }
                    events.append(
                        .toolCallDelta(
                            index: (call["index"] as? Int) ?? offset,
                            id: call["id"] as? String,
                            name: fn?["name"] as? String,
                            arguments: args))
                }
            }
        }
        if let usage = obj["usage"] as? [String: Any] {
            let p = (usage["prompt_tokens"] as? Int) ?? 0
            let c = (usage["completion_tokens"] as? Int) ?? 0
            if p > 0 || c > 0 { events.append(.usage(prompt: p, completion: c)) }
        }
        return events
    }

    /// Name-based guess when the server can't tell us (OpenAI-compatible servers).
    static func looksLikeVisionModel(_ name: String) -> Bool {
        let n = name.lowercased()
        let markers = [
            "vision", "-vl", "_vl", "vl-", "vl:", "llava", "bakllava", "moondream", "minicpm-v",
            "pixtral", "gemma3", "gemma-3", "llama3.2-vision", "llama-3.2-11b", "llama4",
            "mistral-small3.1", "mistral-small-3.1", "qwen2.5vl", "qwen2.5-vl", "qwen3-vl",
            "qwen2-vl", "granite3.2-vision", "smolvlm", "idefics", "internvl", "phi-3.5-vision",
            "phi-4-multimodal", "-omni", "gpt-4o",
        ]
        return markers.contains { n.contains($0) }
    }
}

/// Server status, model list (+ persisted selection) and Ollama pulls.
@MainActor
final class ServerManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case checking
        case online(DetectedServerKind)
        case offline(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var models: [ServerModel] = []
    @Published private(set) var isPulling = false
    @Published private(set) var pullStatus: String?
    @Published private(set) var pullFraction: Double?
    /// model id → true/false from Ollama /api/show (absent = unknown).
    @Published private(set) var visionCapability: [String: Bool] = [:]
    @Published var selectedModel: String = AppSettings.serverModel {
        didSet {
            if selectedModel != oldValue {
                AppSettings.serverModel = selectedModel
                Task { await refreshCapabilities(for: selectedModel) }
            }
        }
    }

    private var pullTask: Task<Void, Never>?

    var detectedKind: DetectedServerKind? {
        if case .online(let kind) = status { return kind }
        return nil
    }

    var base: URL? { ServerAPI.normalizedBase(AppSettings.serverURL) }

    var isReady: Bool { detectedKind != nil && !selectedModel.isEmpty }

    func refresh() async {
        guard let base else {
            status = .offline(ServerError.badURL(AppSettings.serverURL).localizedDescription)
            models = []
            return
        }
        status = .checking
        do {
            let kind = try await ServerAPI.detect(base: base, preference: AppSettings.serverAPIKind)
            let list = try await ServerAPI.listModels(base: base, kind: kind)
            models = list
            status = .online(kind)
            if !list.isEmpty && !list.contains(where: { $0.id == selectedModel }) {
                // Keep a manually remembered selection only if the server still has it.
                selectedModel = list[0].id
            }
            await refreshCapabilities(for: selectedModel)
        } catch {
            models = []
            status = .offline(error.localizedDescription)
        }
    }

    func refreshCapabilities(for model: String) async {
        guard !model.isEmpty, detectedKind == .ollama, let base else { return }
        if let caps = await ServerAPI.ollamaCapabilities(base: base, model: model) {
            visionCapability[model] = caps.contains("vision")
        }
    }

    /// true / false / nil (unknown).
    func supportsVision(_ model: String) -> Bool {
        if let known = visionCapability[model] { return known }
        return ServerAPI.looksLikeVisionModel(model)
    }

    func pull(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isPulling, detectedKind == .ollama, let base else { return }
        isPulling = true
        pullStatus = "Starting pull of \(name)…"
        pullFraction = nil
        pullTask = Task { [weak self] in
            do {
                try await ServerAPI.pull(base: base, model: name) { status, fraction in
                    await MainActor.run {
                        self?.pullStatus = status.isEmpty ? "Pulling \(name)…" : "\(name): \(status)"
                        self?.pullFraction = fraction
                    }
                }
                guard let self else { return }
                self.pullStatus = "Pulled \(name)."
                self.pullFraction = nil
                self.isPulling = false
                await self.refresh()
                if self.models.contains(where: { $0.id == name || $0.id == name + ":latest" }) {
                    self.selectedModel =
                        self.models.first(where: { $0.id == name })?.id ?? name + ":latest"
                }
            } catch {
                guard let self else { return }
                self.isPulling = false
                self.pullFraction = nil
                self.pullStatus =
                    error is CancellationError
                    ? "Pull cancelled." : "Pull failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelPull() {
        pullTask?.cancel()
    }
}
