import Foundation

/// The shortcut-style pipeline document (schema_version 1.x), decoded from JSON.
struct Pipeline: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        let name: String
        let platform: String?
        let description: String?
    }

    let schemaVersion: String?
    let shortcut: Info
    let actions: [Action]
    let flow: [String]?
    let notes: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case shortcut, actions, flow, notes
    }

    /// Top-level actions in run order. `flow` wins when present; otherwise document order.
    var orderedActions: [Action] {
        guard let flow else { return actions }
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return flow.compactMap { byID[$0] }
    }

    static func load(from url: URL) throws -> Pipeline {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Pipeline.self, from: data)
    }

    static func bundled() throws -> Pipeline {
        guard let url = Bundle.main.url(forResource: "cli-tools", withExtension: "json") else {
            throw PipelineError.missingBundledPipeline
        }
        return try load(from: url)
    }
}

struct Action: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let label: String?
    let description: String?
    let params: [String: JSONValue]
    let outputs: [String]?
    let branches: [String: [Action]]?

    enum CodingKeys: String, CodingKey {
        case id, type, label, description, params, outputs, branches
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs)
        branches = try c.decodeIfPresent([String: [Action]].self, forKey: .branches)
    }

    var title: String { label ?? type }

    func string(_ key: String) -> String? { params[key]?.stringValue }

    /// Branch keys in a stable, meaningful order. JSON objects are unordered once decoded,
    /// so `if` uses then/otherwise and menus use the order of their `items`.
    var orderedBranchKeys: [String] {
        guard let branches else { return [] }
        let preferred: [String]
        switch type {
        case "if": preferred = ["then", "otherwise"]
        case "choose_from_menu": preferred = params["items"]?.arrayValue?.compactMap(\.stringValue) ?? []
        default: preferred = []
        }
        let rest = branches.keys.filter { !preferred.contains($0) }.sorted()
        return preferred.filter { branches[$0] != nil } + rest
    }
}

/// Untyped JSON for `params`, whose shape differs per action type.
enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { a } else { nil }
    }
}

enum PipelineError: LocalizedError {
    case missingBundledPipeline
    case unsupportedAction(String)
    case missingParameter(action: String, name: String)
    case modelUnavailable(String)
    case unsupportedModel(String)
    case shellFailed(status: Int32, stderr: String)
    case shellTimedOut
    case notesFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledPipeline: "The bundled cli-tools.json is missing from the app."
        case .unsupportedAction(let t): "This app does not know how to run a “\(t)” action."
        case .missingParameter(let a, let n): "Action \(a) is missing the “\(n)” parameter."
        case .modelUnavailable(let r): "The on-device model is unavailable: \(r)"
        case .unsupportedModel(let m): "Only the On-Device model is supported (pipeline asked for “\(m)”)."
        case .shellFailed(let s, let e): "The shell script exited with status \(s).\n\(e)"
        case .shellTimedOut: "The shell script took longer than 30 seconds and was stopped."
        case .notesFailed(let m): "Notes could not save the note: \(m)"
        }
    }
}
