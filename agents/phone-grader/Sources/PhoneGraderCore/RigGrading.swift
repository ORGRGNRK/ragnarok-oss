import Foundation

// MARK: - The three model roles, per the crew probes
//
//  1. Local Qwen (Ollama qwen2.5vl) — ONLY x-7b:keep screen-text fields. probe-002 finding 1:
//     grounded OCR is its real strength. Never damage, never identity (finding 6, probe-001 #3).
//  2. Anthropic grader + rubric.md — damage, identity and per-category A–F, ONE call per finished pass.
//  3. Claude auditor — verifies/rejects each claim and category; disagreement stays UNKNOWN + concern.

/// One AI call: system prompt, user text, images (JPEG), JSON schema. Returns raw text.
/// The app wires real backends; tests wire fixtures. Nothing in Core touches the network.
public protocol RigModel: Sendable {
    var label: String { get }
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String
}

public struct PassClaim: Codable, Equatable, Sendable {
    public var field: String
    public var value: ClaimValue
    public var confidence: Double?
    public var frame: String?          // frame hash ref
    public var note: String?
}

/// Grader output for one pass: rubric categories + typed claims.
public struct PassGrade: Codable, Equatable, Sendable {
    public var categories: [GradeCategory]
    public var claims: [PassClaim]
    public var concerns: [String]
    public var photos_needed: [String]
    public var summary: String
}

public struct AuditVerdict: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case verify, reject, unsure }
    public var target: String          // a claim field name, or "category:<name>"
    public var verdict: Verdict
    public var reason: String
}

public struct AuditResult: Codable, Equatable, Sendable {
    public var verdicts: [AuditVerdict]
    public var concerns: [String]
}

public enum RigPrompts {
    static let grades = ["A", "B", "C", "D", "F"]

    // ---- Qwen screen-text ----
    public static func screenTextSchema(_ s: DomainSchema) -> [String: Any] {
        var props: [String: Any] = [:]
        for f in s.screenKeepFields {
            if let e = f.enumValues { props[f.name] = ["type": "string", "enum": e] }
            else if f.isInteger { props[f.name] = ["type": ["integer", "string"]] }
            else { props[f.name] = ["type": "string"] }
        }
        return ["type": "object", "properties": props, "required": Array(props.keys).sorted(), "additionalProperties": false]
    }

    public static func screenTextPrompt(_ s: DomainSchema) -> String {
        let lines = s.screenKeepFields.map { f -> String in
            if let e = f.enumValues { return "- \(f.name): one of \(e.joined(separator: " | "))" }
            if f.isInteger { return "- \(f.name): integer" + (f.range.map { " \($0.lowerBound)-\($0.upperBound)" } ?? "") }
            return "- \(f.name): text exactly as shown"
        }
        return """
        Transcribe ONLY text that is visibly on the phone's screen in these photos (Settings → General → About, \
        Battery Health, Parts and Service History, *#06#). For each field below give the value exactly as shown, or \
        UNKNOWN if that text is not in any photo. Do not guess, do not infer from the phone's appearance, do not \
        describe damage. Carrier lock and IMEI blacklist status are different facts — never put one in the other.
        \(lines.joined(separator: "\n"))
        Reply with only the JSON object.
        """
    }

    // ---- Anthropic pass grader ----
    public static func passFields(_ s: DomainSchema, _ pass: CapturePass) -> [FieldSpec] {
        s.fields(for: pass).filter { $0.sources.contains(.camera) && $0.sevenB != .keep }
    }

    public static func passGradeSchema(_ s: DomainSchema, _ pass: CapturePass) -> [String: Any] {
        let names = passFields(s, pass).map(\.name)
        let cat: [String: Any] = ["type": "object", "properties": ["name": ["type": "string"], "grade": ["type": "string", "enum": grades],
                                  "notes": ["type": "string"]], "required": ["name", "grade", "notes"], "additionalProperties": false]
        let claim: [String: Any] = ["type": "object", "properties": [
            "field": ["type": "string", "enum": names], "value": ["type": "string"],
            "confidence": ["type": "number"], "frame": ["type": "string"], "note": ["type": "string"]],
            "required": ["field", "value", "confidence", "frame", "note"], "additionalProperties": false]
        return ["type": "object", "properties": [
            "categories": ["type": "array", "items": cat], "claims": ["type": "array", "items": claim],
            "concerns": ["type": "array", "items": ["type": "string"]],
            "photos_needed": ["type": "array", "items": ["type": "string"]], "summary": ["type": "string"]],
            "required": ["categories", "claims", "concerns", "photos_needed", "summary"], "additionalProperties": false]
    }

    public static func passGradePrompt(_ s: DomainSchema, pass: CapturePass, frames: [RigFrame],
                                       record: PhoneRecord, checklist: [ChecklistEntry]) -> String {
        let fields = passFields(s, pass).map { f in "- \(f.name)" + (f.enumValues.map { " (one of \($0.joined(separator: " | ")))" } ?? "") }
        let known = record.claims.filter { !$0.value.value.isUnknown }.sorted { $0.key < $1.key }
            .map { "- \($0.key) = \($0.value.value) [\($0.value.source.rawValue)]" }
        let frameList = frames.enumerated().map { "photo \($0.offset + 1): frame \($0.element.hashRef), camera \($0.element.slot)" }
        let checklistText = checklist.isEmpty ? "(none)" : checklist.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
        let passNote = pass == .exterior
            ? "These are turntable frames of the exterior with the screen OFF, from fixed cameras at different angles so light hits every surface. Grade the physical categories (screen glass, back glass/housing, frame/edges, cameras, authenticity red flags). A line that follows the rig across angles is a reflection, not a crack — only claim damage you can see on the device itself."
            : "These are frames with the screen ON showing the About page / Battery Health / Parts and Service. Grade display-related categories (display/authenticity, True Tone, parts history) and settle identity (model_exact) ONLY from the Model Name row being in frame."
        return """
        RIG \(pass.label). \(passNote)
        \(frameList.joined(separator: "\n"))
        Already established (do not contradict human/pull facts):
        \(known.isEmpty ? "(nothing yet)" : known.joined(separator: "\n"))
        Human checklist results (verified in person by the buyer, ground truth):
        \(checklistText)

        Return per-category grades per the rubric, and a claim for each of these fields you can actually see \
        (value UNKNOWN if you cannot; `frame` = the frame hash you read it from):
        \(fields.joined(separator: "\n"))
        Respond with ONLY the JSON object.
        """
    }

    // ---- Claude auditor ----
    public static let auditSchema: [String: Any] = [
        "type": "object", "properties": [
            "verdicts": ["type": "array", "items": ["type": "object", "properties": [
                "target": ["type": "string"], "verdict": ["type": "string", "enum": ["verify", "reject", "unsure"]],
                "reason": ["type": "string"]], "required": ["target", "verdict", "reason"], "additionalProperties": false]],
            "concerns": ["type": "array", "items": ["type": "string"]]],
        "required": ["verdicts", "concerns"], "additionalProperties": false]

    public static let auditSystem = """
    You are the AUDITOR for a used-phone grading rig. A different model produced the claims and category grades \
    below from the same photos. Your job is to try to break them, not to agree: look for reflections read as cracks, \
    identity read from a row that is not in frame, aftermarket screens graded as OEM, camera lens spots missed, \
    and any value that looks like a prior rather than a reading (stereotyped 85% / AT&T / Space Gray / 256GB). \
    For EVERY claim field and every "category:<name>" give verify, reject or unsure with a one-line reason. \
    Human checklist facts are ground truth and are not yours to audit. Respond with only the JSON object.
    """

    public static func auditPrompt(record: PhoneRecord, categories: [GradeCategory], frames: [RigFrame]) -> String {
        let claims = record.claims.filter { $0.value.source == .camera && !$0.value.value.isUnknown }.sorted { $0.key < $1.key }
            .map { "- \($0.key) = \($0.value.value) (ref \($0.value.ref ?? "-"))" }
        let cats = categories.map { "- category:\($0.name) = \($0.grade) — \($0.notes)" }
        return """
        Photos: \(frames.map(\.hashRef).joined(separator: ", "))
        Claims to audit:
        \(claims.isEmpty ? "(none)" : claims.joined(separator: "\n"))
        Category grades to audit:
        \(cats.isEmpty ? "(none)" : cats.joined(separator: "\n"))
        """
    }
}

public enum RigParse {
    static func body(_ text: String) -> Data {
        var b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.hasPrefix("```") { b = b.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "") }
        if let s = b.firstIndex(of: "{"), let e = b.lastIndex(of: "}"), s < e { b = String(b[s...e]) }
        return Data(b.utf8)
    }

    /// Qwen screen text → camera claims, merged under x-7b keep only. Returns rejections.
    @discardableResult
    public static func applyScreenText(_ text: String, frameRef: String, into r: inout PhoneRecord,
                                       schema: DomainSchema, aliases: [String: String] = defaultAliases) -> [ClaimRejection] {
        guard let obj = try? JSONSerialization.jsonObject(with: body(text)) as? [String: Any] else {
            r.rejected.append("screen text: unparseable model output"); return []
        }
        var rej: [ClaimRejection] = []
        for (k, raw) in obj.sorted(by: { $0.key < $1.key }) {
            let field = aliases[k] ?? k
            let v: ClaimValue
            if let i = raw as? Int { v = .int(i) } else if let s = raw as? String { v = ClaimValue.isUnknownWord(s) ? .unknown : .text(s) } else { continue }
            if v.isUnknown { continue }
            if let e = r.merge(field, Claim(v, source: .camera, ref: frameRef, note: "local 7B OCR"), schema: schema, fromLocal7B: true) { rej.append(e) }
        }
        return rej
    }

    /// Probe-vocabulary names → schema names (so the crew probe JSON doubles as a fixture).
    public static let defaultAliases: [String: String] = [
        "battery_pct": "Battery %", "battery_health_pct": "Battery %", "imei": "IMEI", "imei2": "IMEI2",
        "serial": "serial_number", "os_version": "firmware_ios", "category": "Category",
    ]

    public static func passGrade(_ text: String) throws -> PassGrade {
        let g: PassGrade
        do { g = try JSONDecoder().decode(PassGrade.self, from: body(text)) }
        catch { throw GradingError.badJSON(String(describing: error).prefix(200).description) }
        guard g.categories.allSatisfy({ RigPrompts.grades.contains($0.grade) }) else { throw GradingError.badJSON("grade outside A-F") }
        return g
    }

    public static func audit(_ text: String) throws -> AuditResult {
        do { return try JSONDecoder().decode(AuditResult.self, from: body(text)) }
        catch { throw GradingError.badJSON(String(describing: error).prefix(200).description) }
    }
}

// MARK: - Grade aggregation (rubric.md "Overall grade")

public struct RigCategory: Codable, Equatable, Sendable {
    public var name: String
    public var grade: String?          // nil = UNKNOWN (auditor disagreed, or not graded)
    public var notes: String
    public var pass: CapturePass
    public init(name: String, grade: String?, notes: String, pass: CapturePass) {
        self.name = name; self.grade = grade; self.notes = notes; self.pass = pass
    }
}

public struct AggregateGrade: Equatable, Sendable {
    public var overall: String?        // nil = needs a human grade
    public var reasons: [String]
    public var concerns: [String]
}

public enum GradeAggregator {
    static let order = ["A", "B", "C", "D", "F"]
    static func worse(_ a: String, _ b: String) -> String { (order.firstIndex(of: a) ?? 4) >= (order.firstIndex(of: b) ?? 4) ? a : b }

    /// Overall = LOWEST category, adjusted per rubric:
    ///  - one C on an otherwise A/B phone → B, if that C is the screen-glass category and the display checks out
    ///    (cracked glass on a healthy display is exactly the rubric's Grade C definition)
    ///  - any F caps at F; battery < 80% caps at C; failed human-checklist items are concerns and cap at C
    ///  - any UNKNOWN category → no overall (manual review), never a guess
    public static func overall(_ cats: [RigCategory], checklist: [ChecklistEntry]) -> AggregateGrade {
        var reasons: [String] = [], concerns: [String] = []
        let unknown = cats.filter { $0.grade == nil }
        if cats.isEmpty { return AggregateGrade(overall: nil, reasons: ["no categories graded — grade by hand"], concerns: []) }
        for e in checklist where e.value.uppercased() == "FAIL" { concerns.append("Checklist FAIL: \(e.label)") }
        if !unknown.isEmpty {
            return AggregateGrade(overall: nil, reasons: unknown.map { "\($0.name) is UNKNOWN (\($0.notes)) — grade by hand" }, concerns: concerns)
        }
        let grades = cats.compactMap(\.grade)
        var g = grades.reduce("A", worse)
        reasons.append("lowest category = \(g)")
        let cs = cats.filter { $0.grade == "C" }
        let rest = cats.filter { $0.grade != "C" }
        if g == "C", cs.count == 1, rest.allSatisfy({ ["A", "B"].contains($0.grade!) }),
           isScreenGlass(cs[0].name), !displayBad(cats) {
            g = "B"; reasons.append("single cosmetic C (\(cs[0].name)) on an otherwise A/B phone → B")
        }
        if grades.contains("F") { g = "F"; reasons.append("an F category caps the overall at F") }
        if let b = checklist.first(where: { $0.label == Checklist.battery }).flatMap({ Int($0.value.replacingOccurrences(of: "%", with: "")) }), b < 80 {
            if worse(g, "C") == "C" && g != "C" { g = "C" }
            reasons.append("battery \(b)% < 80 caps at C"); concerns.append("Battery health \(b)% (Service)")
        }
        if checklist.contains(where: { $0.value.uppercased() == "FAIL" }), worse(g, "C") == "C", g != "C" {
            g = "C"; reasons.append("failed checklist item pulls the overall to C")
        }
        return AggregateGrade(overall: g, reasons: reasons, concerns: concerns)
    }

    static func isScreenGlass(_ n: String) -> Bool { let l = n.lowercased(); return l.contains("screen") && !l.contains("display") }
    static func displayBad(_ cats: [RigCategory]) -> Bool {
        cats.contains { $0.name.lowercased().contains("display") && ["D", "F"].contains($0.grade ?? "F") }
    }
}

// MARK: - Session pipeline

public struct RigOutcome: Equatable, Sendable {
    public var record: PhoneRecord
    public var categories: [RigCategory]
    public var concerns: [String]
    public var photosNeeded: [String]
    public var summaries: [String]
    public var log: [String]
    public init() { record = PhoneRecord(); categories = []; concerns = []; photosNeeded = []; summaries = []; log = [] }
}

public enum RigPipeline {
    /// Local 7B OCR of the screen-pass frames (one call per frame, frames are few and local).
    public static func screenText(_ o: inout RigOutcome, frames: [(RigFrame, Data)], qwen: RigModel, schema: DomainSchema) async {
        for (f, jpeg) in frames {
            do {
                let t = try await qwen.call(system: "You transcribe phone screens.", prompt: RigPrompts.screenTextPrompt(schema),
                                            images: [jpeg], schema: RigPrompts.screenTextSchema(schema))
                let rej = RigParse.applyScreenText(t, frameRef: "frame:\(f.hashRef)", into: &o.record, schema: schema)
                o.log.append("\(qwen.label) read frame \(f.hashRef): \(rej.count) value(s) refused")
            } catch { o.log.append("\(qwen.label) unavailable for frame \(f.hashRef): \(error.localizedDescription)") }
        }
    }

    /// One grader call for a finished pass.
    public static func gradePass(_ o: inout RigOutcome, pass: CapturePass, frames: [(RigFrame, Data)], grader: RigModel,
                                 rubric: String, schema: DomainSchema, checklist: [ChecklistEntry]) async throws {
        let prompt = RigPrompts.passGradePrompt(schema, pass: pass, frames: frames.map(\.0), record: o.record, checklist: checklist)
        let text = try await grader.call(system: rubric, prompt: prompt, images: frames.map(\.1),
                                         schema: RigPrompts.passGradeSchema(schema, pass))
        let g = try RigParse.passGrade(text)
        apply(g, pass: pass, to: &o, schema: schema, by: grader.label)
    }

    public static func apply(_ g: PassGrade, pass: CapturePass, to o: inout RigOutcome, schema: DomainSchema, by label: String) {
        o.categories.removeAll { $0.pass == pass }
        o.categories += g.categories.map { RigCategory(name: $0.name, grade: $0.grade, notes: $0.notes, pass: pass) }
        for c in g.claims where !c.value.isUnknown {
            let ref = c.frame.flatMap { $0.isEmpty ? nil : "frame:\($0)" } ?? "pass:\(pass.rawValue)"
            o.record.merge(c.field, Claim(c.value, source: .camera, ref: ref, confidence: c.confidence, note: c.note), schema: schema)
        }
        o.concerns += g.concerns; o.photosNeeded += g.photos_needed; o.summaries.append("\(pass.rawValue): \(g.summary)")
        o.log.append("\(label) graded \(pass.rawValue): \(g.categories.count) categories, \(g.claims.count) claims")
    }

    /// Auditor: reject/unsure → claim demoted to UNKNOWN (kept as a candidate) and a concern; category → UNKNOWN grade.
    public static func applyAudit(_ a: AuditResult, to o: inout RigOutcome, by label: String) {
        for v in a.verdicts where v.verdict != .verify {
            if v.target.hasPrefix("category:") {
                let name = String(v.target.dropFirst("category:".count))
                for i in o.categories.indices where o.categories[i].name.caseInsensitiveCompare(name) == .orderedSame {
                    let old = o.categories[i].grade ?? "?"
                    o.categories[i].grade = nil
                    o.categories[i].notes = "auditor \(v.verdict.rawValue) on \(old): \(v.reason)"
                }
            } else if let c = o.record.claims[v.target], c.source == .camera {   // human/pull are not the auditor's to move
                o.record.demoteToUnknown(v.target, reason: v.reason)
            } else { continue }
            o.concerns.append("Auditor \(v.verdict.rawValue)s \(v.target): \(v.reason)")
        }
        o.concerns += a.concerns
        o.log.append("\(label) audited: \(a.verdicts.filter { $0.verdict == .verify }.count) verified, \(a.verdicts.filter { $0.verdict != .verify }.count) disputed")
    }

    public static func audit(_ o: inout RigOutcome, frames: [(RigFrame, Data)], auditor: RigModel) async throws {
        let text = try await auditor.call(system: RigPrompts.auditSystem,
                                          prompt: RigPrompts.auditPrompt(record: o.record, categories: o.categories.map {
                                              GradeCategory(name: $0.name, grade: $0.grade ?? "?", notes: $0.notes) }, frames: frames.map(\.0)),
                                          images: frames.map(\.1), schema: RigPrompts.auditSchema)
        applyAudit(try RigParse.audit(text), to: &o, by: auditor.label)
    }

    /// Convert to the app's existing GradeResult so Price / Listing / History keep working unchanged.
    public static func gradeResult(_ o: RigOutcome, checklist: [ChecklistEntry], schema: DomainSchema) -> (GradeResult?, AggregateGrade) {
        let agg = GradeAggregator.overall(o.categories, checklist: checklist)
        guard let overall = agg.overall else { return (nil, agg) }
        var concerns = o.concerns + agg.concerns + RigBlockers.blockers(o.record, schema: schema)
        concerns = concerns.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let g = GradeResult(overall_grade: overall,
                            categories: o.categories.map { GradeCategory(name: $0.name, grade: $0.grade ?? "F", notes: $0.notes) },
                            concerns: concerns, photos_needed: o.photosNeeded,
                            summary: (o.summaries + ["Overall: " + agg.reasons.joined(separator: "; ")]).joined(separator: " "))
        return (g, agg)
    }
}

extension DealRule {
    /// Rig gate: terminal UNKNOWN IMEI status / iCloud (or a bad value) means no buy number at all.
    public static func applyRigBlockers(_ d: DealResult, blockers: [String]) -> DealResult {
        guard !blockers.isEmpty else { return d }
        var out = d
        out.actionable = false
        out.headline = "BLOCKED — no buy number"
        out.detail = blockers.joined(separator: "\n") + (d.maxBuy.map { "\n(reference: \(d.detail), $\(dollars($0)))" } ?? "")
        return out
    }
}

extension DealRule {
    /// Checklist rules (unknown/failed iCloud or IMEI) + rig blockers -> no buy number.
    public static func applyChecklistGate(_ d: DealResult, checklist: [ChecklistEntry], rigBlockers: [String] = []) -> DealResult {
        applyRigBlockers(d, blockers: ChecklistGate.blockers(checklist) + rigBlockers)
    }
}
