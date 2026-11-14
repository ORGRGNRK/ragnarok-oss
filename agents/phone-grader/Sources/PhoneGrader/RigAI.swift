import Foundation
import PhoneGraderCore

/// Real backends for the rig's three model roles. Only constructed when the operator
/// presses a button in the Rig tab — build and tests never touch these.
struct AnthropicJSONModel: RigModel {
    let model: String
    var label: String { "anthropic:\(model)" }
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String {
        guard let key = Keychain.get(.anthropicAPIKey), !key.isEmpty else {
            throw GradingError.backend("No Anthropic API key saved (Settings → AI backend).")
        }
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = ["model": model, "max_tokens": Grader.maxTokens, "system": system,
                                   "output_config": ["format": ["type": "json_schema", "schema": schema]],
                                   "messages": [["role": "user", "content": content]]]
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"; r.timeoutInterval = 180
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if obj?["stop_reason"] as? String == "max_tokens" { throw GradingError.truncated }
        guard let text = (obj?["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw GradingError.noText }
        return text
    }
}

/// `claude -p` (Claude Code / Agent SDK on the logged-in subscription), Read-only tool access to the frames.
struct ClaudeCLIJSONModel: RigModel {
    let path: String?
    let model: String
    let role: String
    var label: String { "claude-cli(\(role))" }
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String {
        guard let exe = AIClient.findClaude(custom: path) else { throw GradingError.backend("claude CLI not found.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phonegrader-rig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var paths: [String] = []
        for (i, d) in images.enumerated() { let u = dir.appendingPathComponent("photo-\(i + 1).jpg"); try d.write(to: u); paths.append(u.path) }
        let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8)!
        let full = "Photos (\(paths.count)) — open and look at EVERY one with the Read tool first, in order (photo 1 = first listed):\n" +
            paths.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + prompt
        var args = ["-p", full, "--system-prompt", system, "--json-schema", schemaText, "--output-format", "json",
                    "--tools", "Read", "--allowedTools", "Read", "--add-dir", dir.path]
        if !model.isEmpty { args += ["--model", model] }
        let (code, out, err) = try await AIClient.run(exe, args, cwd: dir, timeout: 300)
        guard code == 0 else { throw GradingError.backend(ClaudeCLIOutput.reason(exitCode: code, stdout: out, stderr: err)) }
        if let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] {
            if obj["is_error"] as? Bool == true { throw GradingError.backend(ClaudeCLIOutput.reason(exitCode: code, stdout: out, stderr: err)) }
            if let so = obj["structured_output"], JSONSerialization.isValidJSONObject(so),
               let d = try? JSONSerialization.data(withJSONObject: so) { return String(data: d, encoding: .utf8)! }
            if let t = obj["result"] as? String { return t }
        }
        return out
    }
}

struct OllamaJSONModel: RigModel {
    let host: String
    let model: String
    var label: String { "ollama:\(model)" }
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String {
        guard let url = URL(string: host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat") else {
            throw GradingError.backend("Bad Ollama host")
        }
        let body: [String: Any] = ["model": model, "stream": false, "format": schema,
                                   "options": ["temperature": 0.0, "num_predict": 1024],
                                   "messages": [["role": "system", "content": system],
                                                ["role": "user", "content": prompt, "images": images.map { $0.base64EncodedString() }]]]
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let t = (obj?["message"] as? [String: Any])?["content"] as? String else { throw GradingError.noText }
        return t
    }
}

/// OpenAI-compatible local server (LM Studio / Ollama /v1) with image_url parts. Used by the rig only for vision models.
struct OpenAICompatJSONModel: RigModel {
    let baseURL: String
    let model: String
    var label: String { "local:\(model)" }
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String {
        try await OpenAICompatBackend.chat(baseURL: baseURL, model: model, system: system, prompt: prompt, images: images, schema: schema)
    }
}
