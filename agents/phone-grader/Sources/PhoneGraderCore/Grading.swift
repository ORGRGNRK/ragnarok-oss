import Foundation

/// Port of phone-grader-bot/grader.js: GRADE_SCHEMA, prompt text, guards.
public struct GradeCategory: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var grade: String
    public var notes: String
    public init(name: String, grade: String, notes: String) { self.name = name; self.grade = grade; self.notes = notes }
}

public struct GradeResult: Codable, Equatable, Sendable {
    public var overall_grade: String
    public var categories: [GradeCategory]
    public var concerns: [String]
    public var photos_needed: [String]
    public var summary: String
    public init(overall_grade: String, categories: [GradeCategory], concerns: [String], photos_needed: [String], summary: String) {
        self.overall_grade = overall_grade; self.categories = categories; self.concerns = concerns
        self.photos_needed = photos_needed; self.summary = summary
    }
}

public enum GradingError: Error, LocalizedError {
    case noPhotos, noText, truncated, badJSON(String), backend(String)
    public var errorDescription: String? {
        switch self {
        case .noPhotos: return "At least one photo is required."
        case .noText: return "Model returned no text content."
        case .truncated: return "Grade response was cut off (too long). Try again with fewer photos."
        case .badJSON(let m): return "Grader returned JSON that doesn't match the schema: \(m)"
        case .backend(let m): return m
        }
    }
}

public enum Grader {
    public static let maxPhotos = 8          // scenes.js MAX_PHOTOS
    public static let maxTokens = 8192       // do not lower (grader.js)
    public static let defaultModel = "claude-sonnet-5"

    /// GRADE_SCHEMA, verbatim.
    public static let schemaJSON = #"""
    {"type":"object","properties":{"overall_grade":{"type":"string","enum":["A","B","C","D","F"]},"categories":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"grade":{"type":"string","enum":["A","B","C","D","F"]},"notes":{"type":"string"}},"required":["name","grade","notes"],"additionalProperties":false}},"concerns":{"type":"array","items":{"type":"string"}},"photos_needed":{"type":"array","items":{"type":"string"},"description":"Angles/shots that would improve confidence, if any"},"summary":{"type":"string"}},"required":["overall_grade","categories","concerns","photos_needed","summary"],"additionalProperties":false}
    """#

    public static var schemaObject: Any {
        try! JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
    }

    /// grader.js promptText, line for line.
    public static func promptText(checklist: [ChecklistEntry], phoneModel: String?, notes: String?) -> String {
        let checklistText = checklist.isEmpty
            ? "(no checklist items provided yet)"
            : checklist.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
        var lines: [String] = []
        if let m = phoneModel, !m.isEmpty { lines.append("Phone model: \(m)") }
        lines.append("Human checklist results (verified in person by the buyer):")
        lines.append(checklistText)
        if let n = notes, !n.isEmpty { lines.append("Buyer notes: \(n)") }
        lines.append("")
        lines.append("Grade this phone per the rubric.")
        return lines.joined(separator: "\n")
    }

    /// Parse + validate a grade JSON (enforces the schema's enums/required keys).
    public static func parseGrade(_ text: String) throws -> GradeResult {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {   // tolerate fenced output from CLI/Ollama backends
            body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        if let s = body.firstIndex(of: "{"), let e = body.lastIndex(of: "}"), s < e {
            body = String(body[s...e])
        }
        let g: GradeResult
        do { g = try JSONDecoder().decode(GradeResult.self, from: Data(body.utf8)) }
        catch { throw GradingError.badJSON(String(describing: error).prefix(200).description) }
        let ok = Set(["A", "B", "C", "D", "F"])
        guard ok.contains(g.overall_grade), g.categories.allSatisfy({ ok.contains($0.grade) }) else {
            throw GradingError.badJSON("grade outside A-F")
        }
        return g
    }
}
