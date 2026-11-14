import Foundation
import Vision
import ImageIO
import PhoneGraderCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - On-screen text from photos (Apple Vision, on-device)

enum PhotoOCR {
    /// One string per photo (empty when nothing readable). Accurate mode, en-US, language correction on.
    static func text(_ photos: [Data]) async -> [String] {
        await Task.detached(priority: .userInitiated) { photos.map(recognize) }.value
    }
    static func recognize(_ data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        do { try h.perform([req]) } catch { return "" }
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - Apple on-device model (FoundationModels, macOS 26+)

enum AppleModelStatus {
    /// (available, human reason). Never throws.
    static func check() -> (available: Bool, reason: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, "Apple on-device model is available.")
            case .unavailable(let r):
                switch r {
                case .appleIntelligenceNotEnabled:
                    return (false, "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri, then wait for the model to download.")
                case .deviceNotEligible:
                    return (false, "This Mac isn't eligible for Apple Intelligence.")
                case .modelNotReady:
                    return (false, "The Apple model is still downloading or getting ready. Leave the Mac on Wi-Fi and power and try again later.")
                @unknown default:
                    return (false, "Apple model unavailable: \(r)")
                }
            @unknown default:
                return (false, "Apple model availability unknown.")
            }
        }
        #if os(macOS)
        return (false, "Needs macOS 26 or later (this Mac runs \(ProcessInfo.processInfo.operatingSystemVersionString)).")
        #else
        return (false, "Needs iOS 26 or later on an Apple Intelligence iPhone/iPad (this device runs \(ProcessInfo.processInfo.operatingSystemVersionString)).")
        #endif
        #else
        return (false, "This build has no FoundationModels framework (built with an older SDK).")
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct AppleGradeCategory {
    @Guide(description: "Category, e.g. Screen, Back glass, Frame, Battery, Function")
    var name: String
    @Guide(description: "Letter grade", .anyOf(["A", "B", "C", "D", "F"]))
    var grade: String
    @Guide(description: "Short reason, citing the checklist/notes/on-screen text it came from")
    var notes: String
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct AppleGrade {
    @Guide(description: "Overall letter grade", .anyOf(["A", "B", "C", "D", "F"]))
    var overall_grade: String
    var categories: [AppleGradeCategory]
    @Guide(description: "Problems or unknowns a buyer must check")
    var concerns: [String]
    @Guide(description: "Photos or checks a human should still do")
    var photos_needed: [String]
    var summary: String
}
#endif

/// Text-only: sees the checklist, device info, notes and OCR'd on-screen text — NOT the photos.
struct AppleModelBackend: GradingBackend {
    var label: String { "apple-on-device" }
    var seesPhotos: Bool { false }
    func grade(_ input: GradeInput) async throws -> GradeResult {
        let st = AppleModelStatus.check()
        guard st.available else { throw GradingError.backend("Apple model unavailable: \(st.reason)") }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let prompt = TextOnlyGrading.prompt(input)
            // ~4K-token context: keep the rubric compact, retry shorter if it still overflows.
            for limit in [3500, 1500] {
                let rubric = String(input.rubric.prefix(limit))
                let session = LanguageModelSession(instructions: "You grade used phones for resale. Rubric (may be abridged):\n\(rubric)")
                do {
                    let r = try await session.respond(to: prompt, generating: AppleGrade.self,
                                                      options: GenerationOptions(temperature: 0))
                    let g = r.content
                    let out = GradeResult(overall_grade: g.overall_grade,
                                          categories: g.categories.map { GradeCategory(name: $0.name, grade: $0.grade, notes: $0.notes) },
                                          concerns: g.concerns, photos_needed: g.photos_needed, summary: g.summary)
                    // Same validation as every other backend.
                    let d = try JSONEncoder().encode(out)
                    return try Grader.parseGrade(String(data: d, encoding: .utf8)!)
                } catch let e as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = e, limit > 1500 { continue }
                    throw GradingError.backend("Apple model error: \(e.localizedDescription)\n\(String(describing: e))")
                }
            }
        }
        #endif
        throw GradingError.backend("Apple model unavailable.")
    }
}

// MARK: - OpenAI-compatible local server

struct OpenAICompatBackend: GradingBackend {
    let baseURL: String
    let model: String
    let vision: Bool
    var label: String { "local:\(model)\(vision ? "" : " (text-only)")" }
    var seesPhotos: Bool { vision }

    func grade(_ input: GradeInput) async throws -> GradeResult {
        guard !model.isEmpty else { throw GradingError.backend("No local-server model chosen. Pick one in Settings → Local server (or pgctl config set openAIModel NAME).") }
        let prompt = vision ? Grader.promptText(checklist: input.checklist, phoneModel: input.phoneModel, notes: input.notes)
                            : TextOnlyGrading.prompt(input)
        let text = try await OpenAICompatBackend.chat(baseURL: baseURL, model: model, system: input.rubric, prompt: prompt,
                                                      images: vision ? input.photos : [], schema: Grader.schemaObject)
        return try Grader.parseGrade(text)
    }

    static func models(baseURL: String) async throws -> [String] {
        guard let u = OpenAICompat.endpoint(baseURL, "models") else { throw GradingError.backend("Bad base URL: \(baseURL)") }
        var r = URLRequest(url: u); r.timeoutInterval = 5
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw HTTPStatusError(status: code, body: String(data: d, encoding: .utf8) ?? "") }
        return OpenAICompat.parseModels(d)
    }

    /// POST /chat/completions. Retries once without response_format if the server rejects structured output.
    static func chat(baseURL: String, model: String, system: String, prompt: String, images: [Data], schema: Any?) async throws -> String {
        guard let u = OpenAICompat.endpoint(baseURL, "chat/completions") else { throw GradingError.backend("Bad base URL: \(baseURL)") }
        func send(_ schema: Any?) async throws -> (Int, Data) {
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 600
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: OpenAICompat.chatBody(
                model: model, system: system, prompt: prompt + (schema == nil ? "\n\nRespond with ONLY a JSON object matching this schema:\n\(Grader.schemaJSON)" : ""),
                images: images, schema: schema, maxTokens: Grader.maxTokens))
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d)
        }
        var (code, data) = try await send(schema)
        if code == 400, schema != nil { (code, data) = try await send(nil) }
        guard code == 200 else { throw HTTPStatusError(status: code, body: String(data: data, encoding: .utf8) ?? "") }
        let reply = try OpenAICompat.parseChat(data)
        if reply.truncated { throw GradingError.truncated }
        return reply.text
    }
}
