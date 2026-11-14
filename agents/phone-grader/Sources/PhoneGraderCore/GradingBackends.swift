import Foundation

// Backend-independent grading plumbing: inputs, a protocol every backend implements
// (so tests can mock them — no paid API/CLI calls in tests), text-only prompting for
// models that can't see photos, OpenAI-compatible request/response shapes, and
// plain-English error reasons from the claude CLI's JSON.

public struct GradeInput: Sendable {
    public var photos: [Data]
    public var checklist: [ChecklistEntry]
    public var phoneModel: String?
    public var notes: String?
    public var rubric: String
    /// Text read off the photos with Apple Vision (Settings screens etc.), one entry per photo.
    public var photoText: [String]
    /// Auto-filled device info (USB/Wi-Fi read), e.g. "Model: iPhone 16 Pro; Battery: 91%".
    public var deviceInfo: String?
    public init(photos: [Data], checklist: [ChecklistEntry], phoneModel: String?, notes: String?, rubric: String,
                photoText: [String] = [], deviceInfo: String? = nil) {
        self.photos = photos; self.checklist = checklist; self.phoneModel = phoneModel; self.notes = notes
        self.rubric = rubric; self.photoText = photoText; self.deviceInfo = deviceInfo
    }
}

public protocol GradingBackend: Sendable {
    var label: String { get }
    /// false = text-only (can't look at photos); the result is marked as such.
    var seesPhotos: Bool { get }
    func grade(_ input: GradeInput) async throws -> GradeResult
}

public enum GradeDispatcher {
    /// Run `primary`; on failure try `fallback` (if any). Text-only results get an honest concern added.
    public static func run(_ input: GradeInput, primary: GradingBackend, fallback: GradingBackend? = nil) async throws -> (GradeResult, String) {
        do { return (try await finish(primary, input), primary.label) }
        catch let first {
            guard let fb = fallback else { throw first }
            do { return (try await finish(fb, input), fb.label + " (fallback)") }
            catch { throw GradingError.backend("\(first.localizedDescription)\n\n(\(fb.label) fallback also failed: \(error.localizedDescription))") }
        }
    }
    static func finish(_ b: GradingBackend, _ input: GradeInput) async throws -> GradeResult {
        let g = try await b.grade(input)
        return b.seesPhotos ? g : TextOnlyGrading.markTextOnly(g)
    }
}

public enum TextOnlyGrading {
    public static let disclaimer = "Text-only grade: this model cannot see photos, so cosmetic damage was NOT visually judged — it is based on the checklist, device info, notes and text read from the photos."

    public static func prompt(_ i: GradeInput) -> String {
        var s = Grader.promptText(checklist: i.checklist, phoneModel: i.phoneModel, notes: i.notes)
        var extra: [String] = ["", "IMPORTANT: you cannot see the photos. Do not claim to have inspected the screen, back or frame visually.",
                               "Grade cosmetic categories only from the human checklist and notes; if they say nothing, grade conservatively (B at best) and list the photos a human should review in photos_needed."]
        if let d = i.deviceInfo, !d.isEmpty { extra.append("Auto-read device info: \(d)") }
        let texts = i.photoText.enumerated().compactMap { (n, t) -> String? in
            let c = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? nil : "Photo \(n + 1) on-screen text (OCR): \(String(c.prefix(1500)))"
        }
        extra += texts.isEmpty ? ["No readable on-screen text was found in the photos."] : texts
        s += "\n" + extra.joined(separator: "\n")
        return s
    }

    public static func markTextOnly(_ g: GradeResult) -> GradeResult {
        var o = g
        if !o.concerns.contains(disclaimer) { o.concerns.insert(disclaimer, at: 0) }
        if o.photos_needed.isEmpty { o.photos_needed = ["Human review of all photos for cracks, scratches and dents (model could not see them)"] }
        return o
    }
}

// MARK: - Checklist rules apply whatever graded the phone

public enum ChecklistGate {
    /// Unknown or failed iCloud / IMEI = no buy number. A model grade never overrides this.
    public static func blockers(_ checklist: [ChecklistEntry]) -> [String] {
        let f = ListingPipeline.deriveVerifiedFacts(checklist)
        var b: [String] = []
        switch f.icloudClear {
        case .some(true): break
        case .some(false): b.append("iCloud / Activation Lock is ON — do not buy.")
        case .none: b.append("iCloud / Activation Lock not verified — check it before a buy number.")
        }
        switch f.imeiClean {
        case .some(true): break
        case .some(false): b.append("IMEI is not clean (blacklisted/financed) — do not buy.")
        case .none: b.append("IMEI not verified — check it before a buy number.")
        }
        return b
    }
}

// MARK: - OpenAI-compatible local servers (LM Studio, Ollama /v1)

public enum OpenAICompat {
    public static let lmStudioBase = "http://127.0.0.1:1234/v1"
    public static let ollamaBase = "http://127.0.0.1:11434/v1"

    public static func endpoint(_ base: String, _ path: String) -> URL? {
        URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + path)
    }

    /// GET /models -> ids.
    public static func parseModels(_ data: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = o["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    /// Name heuristic — OpenAI-compatible /models doesn't say whether a model takes images.
    public static func looksVisionCapable(_ id: String) -> Bool {
        let s = id.lowercased()
        return ["vision", "-vl", "vl:", "vl-", "_vl", "2.5vl", "2vl", "llava", "pixtral", "minicpm-v", "moondream", "gemma-3", "gemma3",
                "bakllava", "internvl", "smolvlm", "idefics", "mllama", "llama-4", "llama4", "qwen3-vl", "granite-vision", "mistral-small-3"]
            .contains { s.contains($0) }
    }

    public static func chatBody(model: String, system: String, prompt: String, images: [Data], schema: Any?, maxTokens: Int) -> [String: Any] {
        let user: Any
        if images.isEmpty { user = prompt }
        else {
            var parts: [[String: Any]] = images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
            parts.append(["type": "text", "text": prompt])
            user = parts
        }
        var b: [String: Any] = ["model": model, "temperature": 0, "max_tokens": maxTokens, "stream": false,
                                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        if let schema { b["response_format"] = ["type": "json_schema", "json_schema": ["name": "phone_grade", "strict": true, "schema": schema]] }
        return b
    }

    public struct Reply: Equatable { public var text: String; public var truncated: Bool }
    public static func parseChat(_ data: Data) throws -> Reply {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GradingError.backend("Local server returned non-JSON: \(String(data: data, encoding: .utf8) ?? "")")
        }
        if let e = o["error"] {
            let m = (e as? [String: Any])?["message"] as? String ?? String(describing: e)
            throw GradingError.backend("Local server error: \(m)")
        }
        guard let c = (o["choices"] as? [[String: Any]])?.first,
              let msg = c["message"] as? [String: Any], let t = msg["content"] as? String, !t.isEmpty else { throw GradingError.noText }
        return Reply(text: t, truncated: c["finish_reason"] as? String == "length")
    }
}

// MARK: - claude CLI errors in plain English

public enum ClaudeCLIOutput {
    /// Turn a failed `claude -p --output-format json` run into a readable reason, keeping the full raw text.
    public static func reason(exitCode: Int32, stdout: String, stderr: String) -> String {
        var raw = [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        var detail: String?
        for line in [stdout] + stdout.split(separator: "\n").map(String.init) {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let parts = [o["result"], o["error"], (o["error"] as? [String: Any])?["message"], o["subtype"], o["message"]]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { detail = parts.joined(separator: " — "); break }
        }
        if raw.isEmpty { raw = "(no output)" }
        let hay = ((detail ?? "") + " " + raw).lowercased()
        let plain: String
        if hay.contains("credit balance") { plain = "Your Claude account is out of credit." }
        else if hay.contains("usage limit") || hay.contains("limit reached") || hay.contains("rate limit") || hay.contains("5-hour limit") || hay.contains("weekly limit") {
            plain = "Claude usage limit reached for your plan."
        } else if hay.contains("subscription") || hay.contains("no active") || hay.contains("upgrade") || hay.contains("plan") && hay.contains("expired") {
            plain = "Your Claude subscription isn't active (lapsed or not on a paid plan)."
        } else if hay.contains("not logged in") || hay.contains("/login") || hay.contains("invalid api key") || hay.contains("oauth") || hay.contains("authentication") {
            plain = "The claude CLI isn't logged in (run `claude` once and /login)."
        } else if hay.contains("overloaded") || hay.contains("529") { plain = "Claude is overloaded right now — try again shortly." }
        else { plain = "claude CLI failed (exit \(exitCode))." }
        return plain + "\n\nDetails: " + (detail ?? "exit \(exitCode)") + "\n\nFull output:\n" + raw
    }
}
