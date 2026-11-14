import Foundation

/// Port of ORGRGNRK/crew domain/phone.schema.json v0.4 (Resources/phone.schema.json).
/// The field table is READ from that file, so the vocabulary stays the schema's,
/// not a hand copy. Rules enforced here (schema description, numbered as there):
///  (1) a claim traces to an observation (ref) or is inference (confidence)
///  (2) a claim from a channel that cannot observe the field is invalid
///  (3) capture is staged: UNKNOWN is PENDING until its x-pass is in passesDone, TERMINAL after
///  (4) values are typed: per-field enum / pattern / range, never bare strings
///  (5) merge precedence: human and pull are immovable by camera/voice/inference
///  (6) x-7b: only `keep` fields may be held from the local 7B model
public enum CapturePass: String, Codable, CaseIterable, Sendable, Comparable {
    case exterior, screen
    public static func < (a: Self, b: Self) -> Bool { a == .exterior && b == .screen }
    public var label: String { self == .exterior ? "Pass 1 — exterior (screen off)" : "Pass 2 — screen on (About page)" }
}

public enum ClaimSource: String, Codable, CaseIterable, Sendable {
    case human, voice, camera, pull, inference, derived
    /// Rule (5): human/pull outrank the observing channels; inference is weakest.
    public var rank: Int {
        switch self {
        case .human, .pull: return 3
        case .derived: return 2
        case .camera, .voice: return 1
        case .inference: return 0
        }
    }
    public var needsRef: Bool { [.voice, .camera, .pull, .derived].contains(self) }
}

public enum SevenB: String, Codable, Sendable { case keep, triggerOnly = "trigger-only", escalate }
public enum Visibility: String, Codable, Sendable { case surface, stated, never }

/// A claim value: text, integer, or UNKNOWN (the legal "not observed" state).
public enum ClaimValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case text(String), int(Int), unknown
    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .unknown }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let b = try? c.decode(Bool.self) { self = .text(b ? "true" : "false") }
        else { let s = try c.decode(String.self); self = ClaimValue.isUnknownWord(s) ? .unknown : .text(s) }
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .text(let s): try c.encode(s); case .int(let i): try c.encode(i); case .unknown: try c.encode("UNKNOWN") }
    }
    public var description: String {
        switch self { case .text(let s): return s; case .int(let i): return String(i); case .unknown: return "UNKNOWN" }
    }
    public var isUnknown: Bool { self == .unknown }
    /// Model-speak for "can't see it" (probe-002 finding 3) collapses to UNKNOWN.
    public static func isUnknownWord(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty || ["unknown", "n/a", "none visible", "not visible", "not specified in the image", "not specified", "null"].contains(t)
    }
}

public struct Claim: Codable, Equatable, Sendable {
    public var value: ClaimValue
    public var candidates: [String]?
    public var source: ClaimSource
    public var ref: String?
    public var confidence: Double?
    public var note: String?
    public init(_ value: ClaimValue, source: ClaimSource, ref: String? = nil, confidence: Double? = nil,
                note: String? = nil, candidates: [String]? = nil) {
        self.value = value; self.source = source; self.ref = ref; self.confidence = confidence
        self.note = note; self.candidates = candidates
    }
}

public struct FieldSpec: Equatable, Sendable {
    public var name: String
    public var visibility: Visibility
    public var pass: CapturePass?
    public var sources: Set<ClaimSource>
    public var sevenB: SevenB?
    public var enumValues: [String]?
    public var pattern: String?
    public var range: ClosedRange<Int>?
    public var isInteger: Bool
    public var airtable: String?
}

public enum ClaimRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownField(String)
    case sourceNotAllowed(String, ClaimSource)
    case missingRef(String)
    case missingConfidence(String)
    case badValue(String, String)
    case outranked(String, existing: ClaimSource)
    case sevenBNotKeep(String)
    public var description: String {
        switch self {
        case .unknownField(let f): return "\(f): not in the phone vocabulary"
        case .sourceNotAllowed(let f, let s): return "\(f): \(s.rawValue) cannot observe this field"
        case .missingRef(let f): return "\(f): observation claim without a ref"
        case .missingConfidence(let f): return "\(f): inference without a confidence"
        case .badValue(let f, let v): return "\(f): '\(v)' is not a legal value"
        case .outranked(let f, let s): return "\(f): already held by \(s.rawValue), which outranks this claim"
        case .sevenBNotKeep(let f): return "\(f): the local 7B model may not hold this field"
        }
    }
}

public enum UnknownState: String, Sendable { case known, pending, terminal }

public struct DomainSchema: Sendable {
    public let version: String
    public let fields: [String: FieldSpec]
    public let order: [String]

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = (((root["properties"] as? [String: Any])?["claims"] as? [String: Any])?["properties"]) as? [String: Any]
        else { throw GradingError.badJSON("phone.schema.json: no properties.claims.properties") }
        version = root["$id"] as? String ?? "?"
        // keep file order for display
        let ordered = DomainSchema.keyOrder(data)
        var out: [String: FieldSpec] = [:]
        for (name, raw) in props {
            guard let p = raw as? [String: Any] else { continue }
            let range = (p["x-value-range"] as? [Int]).flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
            out[name] = FieldSpec(
                name: name,
                visibility: Visibility(rawValue: p["x-visibility"] as? String ?? "never") ?? .never,
                pass: (p["x-pass"] as? String).flatMap(CapturePass.init(rawValue:)),
                sources: Set((p["x-sources"] as? [String] ?? []).compactMap(ClaimSource.init(rawValue:))),
                sevenB: (p["x-7b"] as? String).flatMap(SevenB.init(rawValue:)),
                enumValues: p["x-enum"] as? [String],
                pattern: p["x-value-pattern"] as? String,
                range: range,
                isInteger: (p["x-value-type"] as? String) == "integer" || range != nil,
                airtable: p["x-airtable"] as? String)
        }
        fields = out
        order = ordered.filter { out[$0] != nil } + out.keys.filter { !ordered.contains($0) }.sorted()
    }

    private static func keyOrder(_ data: Data) -> [String] {
        // cheap ordered scan of `"name": {` keys inside claims.properties
        guard let s = String(data: data, encoding: .utf8), let r = s.range(of: "\"claims\"") else { return [] }
        let tail = s[r.upperBound...]
        guard let pr = tail.range(of: "\"properties\"") else { return [] }
        let re = try! NSRegularExpression(pattern: #"\n\s{8}"([^"]+)"\s*:\s*\{"#)
        let body = String(tail[pr.upperBound...])
        return re.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    public func fields(for pass: CapturePass) -> [FieldSpec] { order.compactMap { fields[$0] }.filter { $0.pass == pass } }
    /// Fields the local 7B model may hold from the screen pass (x-7b keep, x-pass screen).
    public var screenKeepFields: [FieldSpec] { fields(for: .screen).filter { $0.sevenB == .keep } }

    /// Normalise + type-check a value for a field (rule 4). Returns nil if illegal.
    public func normalize(_ v: ClaimValue, for f: FieldSpec) -> ClaimValue? {
        if v.isUnknown { return .unknown }
        let raw = v.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = f.enumValues {
            if let hit = e.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
                return hit == "UNKNOWN" ? .unknown : .text(hit)
            }
            return nil
        }
        if f.isInteger {
            let digits = raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let n = Int(digits) else { return nil }
            if let r = f.range, !r.contains(n) { return nil }
            return .int(n)
        }
        if let p = f.pattern {
            let compact = raw.replacingOccurrences(of: " ", with: "")
            guard compact.range(of: p, options: .regularExpression) != nil else { return nil }
            return .text(compact)
        }
        return .text(raw)
    }
}

/// One physical phone, as a set of claims with provenance.
public struct PhoneRecord: Codable, Equatable, Sendable {
    public var identity: String?
    public var passesDone: [CapturePass]
    public var claims: [String: Claim]
    /// Every rejected merge, kept so the operator can see what was refused and why.
    public var rejected: [String]
    public init(identity: String? = nil) { self.identity = identity; passesDone = []; claims = [:]; rejected = [] }

    public mutating func markDone(_ p: CapturePass) { if !passesDone.contains(p) { passesDone.append(p); passesDone.sort() } }

    /// Merge one claim under the schema rules. Returns nil on success, else the rejection.
    @discardableResult
    public mutating func merge(_ field: String, _ claim: Claim, schema: DomainSchema, fromLocal7B: Bool = false) -> ClaimRejection? {
        func reject(_ r: ClaimRejection) -> ClaimRejection { rejected.append(r.description); return r }
        guard let f = schema.fields[field] else { return reject(.unknownField(field)) }
        guard f.sources.contains(claim.source) else { return reject(.sourceNotAllowed(field, claim.source)) }
        if fromLocal7B, f.sevenB != .keep { return reject(.sevenBNotKeep(field)) }
        if claim.source.needsRef, (claim.ref ?? "").isEmpty { return reject(.missingRef(field)) }
        if claim.source == .inference, claim.confidence == nil { return reject(.missingConfidence(field)) }
        guard let v = schema.normalize(claim.value, for: f) else { return reject(.badValue(field, claim.value.description)) }
        var c = claim; c.value = v
        if let existing = claims[field], !existing.value.isUnknown {
            if v.isUnknown { return nil }                         // UNKNOWN never erases a known value
            if existing.source.rank >= 3, c.source.rank < 3 { return reject(.outranked(field, existing: existing.source)) }
            if existing.source.rank > c.source.rank { return reject(.outranked(field, existing: existing.source)) }
        }
        claims[field] = c
        return nil
    }

    /// Rule (3). Fields with no x-pass (human/pull only) are pending until every pass has run.
    public func state(of field: String, schema: DomainSchema) -> UnknownState {
        if let c = claims[field], !c.value.isUnknown { return .known }
        guard let f = schema.fields[field] else { return .terminal }
        if let p = f.pass { return passesDone.contains(p) ? .terminal : .pending }
        return Set(passesDone) == Set(CapturePass.allCases) ? .terminal : .pending
    }

    public func value(_ field: String) -> ClaimValue { claims[field]?.value ?? .unknown }

    /// Auditor disagreement: the claim stays in the record as UNKNOWN with the reason (rule: never guessed through).
    public mutating func demoteToUnknown(_ field: String, reason: String) {
        guard var c = claims[field] else { return }
        let old = c.value.description
        c.candidates = (c.candidates ?? []) + [old]
        c.value = .unknown
        c.note = "Auditor disagreed (was '\(old)'): \(reason)"
        claims[field] = c
    }
}

/// Human checklist → claims (source: human). These are the immovable facts.
public enum ChecklistClaims {
    public static func claims(from checklist: [ChecklistEntry]) -> [(String, Claim)] {
        var out: [(String, Claim)] = []
        func v(_ k: String) -> String? { checklist.first { $0.label == k }?.value.uppercased() }
        if let s = v(Checklist.imei) {
            out.append(("IMEI Status", Claim(.text(s == "PASS" ? "Clean" : s == "FAIL" ? "Flagged" : "Unknown"), source: .human, ref: "checklist")))
        }
        if let s = v(Checklist.icloud), s == "PASS" || s == "FAIL" {
            out.append(("icloud_lock", Claim(.text(s == "PASS" ? "clean" : "Activation Locked"), source: .human, ref: "checklist")))
        }
        if let b = checklist.first(where: { $0.label == Checklist.battery })?.value,
           let n = Int(b.replacingOccurrences(of: "%", with: "")) {
            out.append(("Battery %", Claim(.int(n), source: .human, ref: "checklist")))
        }
        return out
    }
}

/// Max-buy blockers: terminal UNKNOWNs (or bad values) on the fields a buyer cannot price around.
public enum RigBlockers {
    public static let fields = ["IMEI Status", "icloud_lock"]
    public static func blockers(_ r: PhoneRecord, schema: DomainSchema) -> [String] {
        var out: [String] = []
        for f in fields {
            let v = r.value(f)
            switch r.state(of: f, schema: schema) {
            case .terminal: out.append("\(f) is UNKNOWN after every pass ran — verify it before buying")
            case .pending: out.append("\(f) not yet established (capture not finished)")
            case .known:
                let s = v.description
                if (f == "IMEI Status" && s != "Clean") || (f == "icloud_lock" && s != "clean") {
                    out.append("\(f) = \(s)")
                }
            }
        }
        if case .text(let m) = r.value("mdm_lock"), m == "MDM locked" { out.append("mdm_lock = MDM locked") }
        return out
    }
}
