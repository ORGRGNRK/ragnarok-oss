import Foundation
import PhoneGraderCore

enum AIBackend: String, CaseIterable, Identifiable, Codable {
    case claudeCLI, appleOnDevice, openAICompatible, anthropicAPI, ollama
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropicAPI: return "Claude API key (Anthropic Messages API, key in Keychain)"
        case .claudeCLI: return "Claude CLI (claude -p, your subscription)"
        case .appleOnDevice: return "Apple on-device model (Apple Intelligence, text-only)"
        case .openAICompatible: return "Local server, OpenAI-compatible (LM Studio / Ollama /v1)"
        case .ollama: return "Ollama native API (legacy)"
        }
    }
    /// For "Grade with …" buttons.
    var shortName: String {
        switch self {
        case .anthropicAPI: return "Claude API"
        case .claudeCLI: return "Claude CLI"
        case .appleOnDevice: return "Apple model"
        case .openAICompatible: return "local server"
        case .ollama: return "Ollama"
        }
    }
    static let cliNames = allCases.map(\.rawValue).joined(separator: ", ")
    /// Backends offered in Settings. iPhone/iPad can't run the claude CLI.
    static var available: [AIBackend] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .claudeCLI }
        #endif
    }
}

struct GradeRequest {
    var photos: [Data]
    var checklist: [ChecklistEntry]
    var phoneModel: String?
    var notes: String?
    var rubric: String
}
extension GradeRequest {
    init(_ i: GradeInput) { self.init(photos: i.photos, checklist: i.checklist, phoneModel: i.phoneModel, notes: i.notes, rubric: i.rubric) }
}

struct ClosureBackend: GradingBackend {
    let label: String
    var seesPhotos: Bool { true }
    let run: @Sendable (GradeInput) async throws -> GradeResult
    init(label: String, _ run: @escaping @Sendable (GradeInput) async throws -> GradeResult) { self.label = label; self.run = run }
    func grade(_ input: GradeInput) async throws -> GradeResult { try await run(input) }
}

struct BackendConfig {
    var anthropicModel: String
    var claudePath: String?
    var claudeModel: String
    var ollamaHost: String
    var ollamaVisionModel: String
    var openAIBaseURL: String = OpenAICompat.lmStudioBase
    var openAIModel: String = ""
    var openAIVision: String = "auto"     // auto | yes | no
    var deviceInfo: String?
}

enum AIClient {
    /// Dispatch to the chosen backend; optionally fall back to Ollama on failure.
    static func grade(_ req: GradeRequest, backend: AIBackend, config: BackendConfig,
                      ollamaFallback: Bool) async throws -> (GradeResult, String) {
        guard !req.photos.isEmpty else { throw GradingError.noPhotos }
        var input = GradeInput(photos: req.photos, checklist: req.checklist, phoneModel: req.phoneModel, notes: req.notes,
                               rubric: req.rubric, deviceInfo: config.deviceInfo)
        let primary = makeBackend(backend, config)
        if !primary.seesPhotos { input.photoText = await PhotoOCR.text(req.photos) }
        let fb: GradingBackend? = (ollamaFallback && backend != .ollama) ? makeBackend(.ollama, config) : nil
        do { return try await GradeDispatcher.run(input, primary: primary, fallback: fb) }
        catch { throw GradingError.backend(friendly(error)) }
    }

    static func makeBackend(_ b: AIBackend, _ c: BackendConfig) -> GradingBackend {
        switch b {
        case .anthropicAPI: return ClosureBackend(label: "anthropic:\(c.anthropicModel)") { try await anthropic(GradeRequest($0), c) }
        case .claudeCLI: return ClosureBackend(label: "claude-cli") { try await claudeCLI(GradeRequest($0), c) }
        case .ollama: return ClosureBackend(label: "ollama:\(c.ollamaVisionModel)") { try await ollama(GradeRequest($0), c) }
        case .appleOnDevice: return AppleModelBackend()
        case .openAICompatible:
            let vision = c.openAIVision == "yes" || (c.openAIVision == "auto" && OpenAICompat.looksVisionCapable(c.openAIModel))
            return OpenAICompatBackend(baseURL: c.openAIBaseURL, model: c.openAIModel, vision: vision)
        }
    }

    // MARK: Anthropic Messages API — same request shape as grader.js

    static func anthropic(_ req: GradeRequest, _ cfg: BackendConfig) async throws -> GradeResult {
        guard let key = Keychain.get(.anthropicAPIKey), !key.isEmpty else {
            throw GradingError.backend("No Anthropic API key saved. Add one in Settings → AI backend.")
        }
        var content: [[String: Any]] = req.photos.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": Grader.promptText(checklist: req.checklist, phoneModel: req.phoneModel, notes: req.notes)])
        let body: [String: Any] = [
            "model": cfg.anthropicModel,
            "max_tokens": Grader.maxTokens,
            "system": req.rubric,
            "output_config": ["format": ["type": "json_schema", "schema": Grader.schemaObject]],
            "messages": [["role": "user", "content": content]],
        ]
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GradingError.noText }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw GradingError.noText
        }
        if obj["stop_reason"] as? String == "max_tokens" { throw GradingError.truncated }
        return try Grader.parseGrade(text)
    }

    // MARK: claude CLI (`claude -p`) — uses the logged-in Claude subscription

    static func findClaude(custom: String?) -> String? {
        #if os(iOS)
        return nil      // no local programs on iPhone/iPad
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let c = custom, !c.isEmpty { candidates.append((c as NSString).expandingTildeInPath) }
        candidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                       "/usr/local/bin/claude", "\(home)/.local/node/bin/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        #endif
    }

    #if os(macOS)
    static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "\(home)/.local/node/bin", "\(home)/.local/platform-tools", "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        // Make sure the CLI uses the subscription login, not a stray API key.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env["PYTHONWARNINGS"] = "ignore"; env["NO_COLOR"] = "1"; env["TERM"] = "dumb"
        return env
    }
    #endif

    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval) async throws -> (Int32, String, String) {
        #if os(iOS)
        throw GradingError.backend("Running local programs (\((exe as NSString).lastPathComponent)) isn't possible on iPhone/iPad — use the Claude API key or a local server backend.")
        #else
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = cliEnvironment()
                if let cwd { p.currentDirectoryURL = cwd }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                p.standardInput = FileHandle.nullDevice
                var outData = Data(), errData = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit(); timer.cancel(); g.wait()
                cont.resume(returning: (p.terminationStatus, String(data: outData, encoding: .utf8) ?? "",
                                        String(data: errData, encoding: .utf8) ?? ""))
            }
        }
        #endif
    }

    static func claudeCLI(_ req: GradeRequest, _ cfg: BackendConfig) async throws -> GradeResult {
        guard let exe = findClaude(custom: cfg.claudePath) else {
            throw GradingError.backend("claude CLI not found. Install Claude Code or set its path in Settings.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phonegrader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var paths: [String] = []
        for (i, d) in req.photos.enumerated() {
            let u = dir.appendingPathComponent("photo-\(i + 1).jpg"); try d.write(to: u); paths.append(u.path)
        }
        let prompt = "Phone photos (\(paths.count)) — open and look at EVERY one with the Read tool before grading:\n" +
            paths.map { "- \($0)" }.joined(separator: "\n") + "\n\n" +
            Grader.promptText(checklist: req.checklist, phoneModel: req.phoneModel, notes: req.notes) +
            "\n\nRespond with ONLY the JSON object matching the schema."
        var args = ["-p", prompt, "--system-prompt", req.rubric, "--json-schema", Grader.schemaJSON,
                    "--output-format", "json", "--tools", "Read", "--allowedTools", "Read", "--add-dir", dir.path]
        if !cfg.claudeModel.isEmpty { args += ["--model", cfg.claudeModel] }
        let (code, out, err) = try await run(exe, args, cwd: dir, timeout: 300)
        guard code == 0 else { throw GradingError.backend(ClaudeCLIOutput.reason(exitCode: code, stdout: out, stderr: err)) }
        if let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] {
            if obj["is_error"] as? Bool == true { throw GradingError.backend(ClaudeCLIOutput.reason(exitCode: code, stdout: out, stderr: err)) }
            if let so = obj["structured_output"], JSONSerialization.isValidJSONObject(so),
               let d = try? JSONSerialization.data(withJSONObject: so) {
                return try Grader.parseGrade(String(data: d, encoding: .utf8)!)
            }
            if let text = obj["result"] as? String { return try Grader.parseGrade(text) }
        }
        return try Grader.parseGrade(out)
    }

    // MARK: Ollama

    static func ollama(_ req: GradeRequest, _ cfg: BackendConfig) async throws -> GradeResult {
        guard let url = URL(string: cfg.ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat") else {
            throw GradingError.backend("Bad Ollama host")
        }
        let body: [String: Any] = [
            "model": cfg.ollamaVisionModel,
            "stream": false,
            "format": Grader.schemaObject,
            "options": ["num_predict": Grader.maxTokens],
            "messages": [
                ["role": "system", "content": req.rubric],
                ["role": "user", "content": Grader.promptText(checklist: req.checklist, phoneModel: req.phoneModel, notes: req.notes),
                 "images": req.photos.map { $0.base64EncodedString() }],
            ],
        ]
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = (obj?["message"] as? [String: Any])?["content"] as? String else { throw GradingError.noText }
        if obj?["done_reason"] as? String == "length" { throw GradingError.truncated }
        return try Grader.parseGrade(text)
    }

    /// price-mcp pass-4 interpreter (`_interpret_model`), same prompt + fences. Synchronous;
    /// call off the main thread. Any failure returns (nil, reason) — never blocks a grade.
    static func ollamaInterpreter(host: String, model: String, timeout: TimeInterval = 12) -> ModelInterpreter {
        return { candidates, typed in
            let prompt = "Match the phone a reseller typed to exactly one name from this list.\n\n" +
                "LIST:\n" + candidates.joined(separator: "\n") + "\n\n" +
                "TYPED: " + typed + "\n\n" +
                "Reply with one line: the matching name copied exactly from the LIST, " +
                "or the single word NONE if it does not clearly match one of them. " +
                "No explanation."
            let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false,
                                       "options": ["temperature": 0, "num_predict": 24]]
            guard let url = URL(string: host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate"),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, "unavailable (bad host)") }
            var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = data; r.timeoutInterval = timeout
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let sem = DispatchSemaphore(value: 0)
            var answer: String?; var failure: String?
            URLSession.shared.dataTask(with: r) { d, _, e in
                if let e { failure = "unavailable (\(type(of: e)))" }
                else if let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { answer = o["response"] as? String ?? "" }
                else { failure = "unavailable (bad JSON)" }
                sem.signal()
            }.resume()
            if sem.wait(timeout: .now() + timeout + 1) == .timedOut { return (nil, "unavailable (timeout)") }
            if let failure { return (nil, failure) }
            let first = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
            let guess = pyNorm(first)
            if candidates.contains(guess) { return (guess, "\(model)@\(host)") }
            return (nil, "no match from \(model)")
        }
    }

    // scenes.js friendlyGradeError, adapted for the Mac
    static func friendly(_ error: Error) -> String {
        if let h = error as? HTTPStatusError {
            let plain: String
            if h.status == 429 { plain = "Rate-limited or out of credit right now — wait a minute before retrying." }
            else if h.status == 529 || h.status >= 500 { plain = "The AI server is having a moment (server error on their side, HTTP \(h.status))." }
            else if h.status == 401 || h.status == 403 { plain = "The API key isn't working (auth error) — check Settings." }
            else { plain = "Grading failed: HTTP \(h.status)." }
            return plain + "\n\nFull response:\n" + (h.body.isEmpty ? "(empty)" : h.body)
        }
        if let u = error as? URLError {
            return u.code == .cannotConnectToHost ? "Couldn't connect (is the server/Ollama running?)." : "Network problem: \(u.localizedDescription)"
        }
        return error.localizedDescription
    }
}

struct HTTPStatusError: Error, LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "HTTP \(status)" }
}
