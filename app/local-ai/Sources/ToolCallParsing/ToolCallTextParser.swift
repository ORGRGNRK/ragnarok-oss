import Foundation

/// A tool call recovered from the model's plain-text reply.
public struct ParsedToolCall: Equatable, Sendable {
    public var name: String
    /// Arguments re-serialized as a JSON object string (always an object, possibly "{}").
    public var argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Arguments as a Foundation dictionary.
    public var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// Recovers tool calls that small local models emit as text instead of the
/// exact protocol mlx-swift-lm expects. Accepts:
///  * Hermes / Qwen `<tool_call>{...}</tool_call>`
///  * fenced ```json / ``` blocks
///  * bare JSON objects anywhere in the reply
/// with keys `name`+`arguments` (or `tool`/`function` + `parameters`/`args`/`input`,
/// or OpenAI style `{"function": {"name", "arguments"}}`); arguments may be a JSON
/// string. Unbalanced extra trailing braces and raw newlines inside strings are
/// tolerated. Only names in `allowedNames` count as tool calls.
public enum ToolCallTextParser {
    public struct Result: Sendable {
        public var calls: [ParsedToolCall]
        /// The reply with the tool-call JSON (and its wrappers) removed.
        public var remainingText: String
    }

    public static func parse(_ text: String, allowedNames: Set<String>) -> Result {
        // 1. Function-call syntax: run_command({"command": "..."}), read_file(path="a.py"),
        //    run_command("python3 x.py"). Removed before the JSON scan so the inner
        //    object isn't looked at twice.
        let fn = parseFunctionCalls(text, allowedNames: allowedNames)
        let json = parseJSONCalls(fn.remainingText, allowedNames: allowedNames)
        let calls = fn.calls + json.calls
        guard !calls.isEmpty else { return Result(calls: [], remainingText: text) }
        return Result(calls: calls, remainingText: cleanup(json.remainingText))
    }

    static func parseJSONCalls(_ text: String, allowedNames: Set<String>) -> Result {
        let chars = Array(text.unicodeScalars)
        var calls: [ParsedToolCall] = []
        var spans: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            guard let end = matchingBrace(chars, from: i) else { i += 1; continue }
            let candidate = String(String.UnicodeScalarView(chars[i...end]))
            if let object = parseObject(candidate) {
                let found = extractCalls(object, allowedNames: allowedNames)
                if !found.isEmpty {
                    calls.append(contentsOf: found)
                    spans.append(i ..< end + 1)
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        guard !calls.isEmpty else { return Result(calls: [], remainingText: text) }

        var kept = String.UnicodeScalarView()
        var cursor = 0
        for span in spans {
            kept.append(contentsOf: chars[cursor ..< span.lowerBound])
            cursor = span.upperBound
        }
        kept.append(contentsOf: chars[cursor...])
        return Result(calls: calls, remainingText: String(kept))
    }

    // MARK: - Function-call syntax

    /// Argument a single positional value maps to.
    public static func primaryArgument(for tool: String) -> String? {
        switch tool {
        case "run_command": return "command"
        case "read_file", "list_dir", "write_file": return "path"
        default: return nil
        }
    }

    static func parseFunctionCalls(_ text: String, allowedNames: Set<String>) -> Result {
        let chars = Array(text.unicodeScalars)
        var calls: [ParsedToolCall] = []
        var spans: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            guard let (name, open) = toolNameAndParen(chars, at: i, allowedNames: allowedNames),
                let close = matchingParen(chars, from: open)
            else { i += 1; continue }
            let inner = String(String.UnicodeScalarView(chars[(open + 1) ..< close]))
            if let args = parseCallArguments(inner, tool: name),
                let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
                let argsJSON = String(data: data, encoding: .utf8)
            {
                calls.append(ParsedToolCall(name: name, argumentsJSON: argsJSON))
                spans.append(i ..< close + 1)
                i = close + 1
                continue
            }
            i += 1
        }
        guard !calls.isEmpty else { return Result(calls: [], remainingText: text) }
        var kept = String.UnicodeScalarView()
        var cursor = 0
        for span in spans {
            kept.append(contentsOf: chars[cursor ..< span.lowerBound])
            cursor = span.upperBound
        }
        kept.append(contentsOf: chars[cursor...])
        return Result(calls: calls, remainingText: String(kept))
    }

    private static func isIdent(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "_" || c == "."
    }

    /// A registered name starting at `i` (not part of a longer identifier) followed by `(`.
    static func toolNameAndParen(_ c: [Unicode.Scalar], at i: Int, allowedNames: Set<String>)
        -> (String, Int)?
    {
        if i > 0 && isIdent(c[i - 1]) { return nil }
        for name in allowedNames {
            let n = Array(name.unicodeScalars)
            guard i + n.count < c.count, Array(c[i ..< i + n.count]) == n else { continue }
            var k = i + n.count
            if isIdent(c[k]) { continue }
            while k < c.count && (c[k] == " " || c[k] == "\t") { k += 1 }
            if k < c.count && c[k] == "(" { return (name, k) }
        }
        return nil
    }

    /// Index of the `)` closing the `(` at `start`, honoring '...' / "..." strings.
    static func matchingParen(_ c: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var quote: Unicode.Scalar? = nil
        var escaped = false
        var k = start
        while k < c.count {
            let ch = c[k]
            if let q = quote {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
            } else {
                switch ch {
                case "\"", "'": quote = ch
                case "(", "{", "[": depth += 1
                case ")", "}", "]":
                    depth -= 1
                    if depth == 0 { return ch == ")" ? k : nil }
                default: break
                }
            }
            k += 1
        }
        return nil
    }

    /// `{json}`, `key="v", k2=1`, or a single positional value.
    static func parseCallArguments(_ raw: String, tool: String) -> [String: Any]? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return [:] }
        if t.first == "{" {
            guard let end = matchingBrace(Array(t.unicodeScalars), from: 0) else { return nil }
            let tail = String(String.UnicodeScalarView(Array(t.unicodeScalars)[(end + 1)...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty || tail == "," else { return nil }
            return parseObject(String(String.UnicodeScalarView(Array(t.unicodeScalars)[0...end])))
        }
        var scanner = ArgScanner(Array(t.unicodeScalars))
        var args: [String: Any] = [:]
        var positional: [Any] = []
        while !scanner.atEnd {
            scanner.skipSpaces()
            let save = scanner.pos
            if let key = scanner.identifier(), scanner.skipSpaces(), scanner.consume("=") || scanner.consume(":") {
                scanner.skipSpaces()
                guard let v = scanner.value() else { return nil }
                args[key] = v
            } else {
                scanner.pos = save
                guard let v = scanner.value() else { return nil }
                positional.append(v)
            }
            scanner.skipSpaces()
            if scanner.atEnd { break }
            guard scanner.consume(",") else { return nil }
        }
        if !positional.isEmpty {
            guard positional.count == 1, args.isEmpty, let key = primaryArgument(for: tool) else { return nil }
            args[key] = positional[0]
        }
        return args
    }

    struct ArgScanner {
        let c: [Unicode.Scalar]
        var pos = 0
        init(_ c: [Unicode.Scalar]) { self.c = c }
        var atEnd: Bool { pos >= c.count }

        @discardableResult mutating func skipSpaces() -> Bool {
            while pos < c.count && CharacterSet.whitespacesAndNewlines.contains(c[pos]) { pos += 1 }
            return true
        }

        mutating func consume(_ s: Unicode.Scalar) -> Bool {
            if pos < c.count && c[pos] == s { pos += 1; return true }
            return false
        }

        mutating func identifier() -> String? {
            let start = pos
            while pos < c.count && (CharacterSet.alphanumerics.contains(c[pos]) || c[pos] == "_") { pos += 1 }
            return pos > start ? String(String.UnicodeScalarView(c[start ..< pos])) : nil
        }

        mutating func value() -> Any? {
            guard pos < c.count else { return nil }
            let q = c[pos]
            if q == "\"" || q == "'" {
                pos += 1
                var out = String.UnicodeScalarView()
                while pos < c.count {
                    let ch = c[pos]
                    pos += 1
                    if ch == q { return String(out) }
                    if ch == "\\" && pos < c.count {
                        let e = c[pos]
                        pos += 1
                        switch e {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        default: out.append(e)
                        }
                    } else {
                        out.append(ch)
                    }
                }
                return nil  // unterminated
            }
            let start = pos
            while pos < c.count && c[pos] != "," && !CharacterSet.whitespacesAndNewlines.contains(c[pos]) {
                pos += 1
            }
            let word = String(String.UnicodeScalarView(c[start ..< pos]))
            switch word {
            case "true", "True": return true
            case "false", "False": return false
            case "null", "None": return NSNull()
            default:
                if let i = Int(word) { return i }
                if let d = Double(word) { return d }
                return nil
            }
        }
    }

    // MARK: - Unexecuted tool-call detection

    /// True when the reply is (essentially) only a tool call written in a form the
    /// app did not execute, e.g. a fenced `run_command(...)` that failed to parse,
    /// or `<tool_call>` with broken JSON. Such a reply must never be a final answer.
    public static func isOnlyToolSnippet(_ text: String, allowedNames: Set<String>) -> Bool {
        guard looksLikeToolCall(text, allowedNames: allowedNames) else { return false }
        var rest = text.replacingOccurrences(of: #"```[A-Za-z0-9_-]*"#, with: " ", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"</?tool_call>"#, with: " ", options: .regularExpression)
        // Drop lines that mention a tool name or look like JSON / call syntax.
        let prose = rest.split(whereSeparator: \.isNewline).filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { return false }
            if allowedNames.contains(where: { l.contains($0) }) { return false }
            if let f = l.first, "{}[]()\"',".contains(f) { return false }
            return true
        }.joined(separator: " ")
        return prose.count < 80
    }

    public static func looksLikeToolCall(_ text: String, allowedNames: Set<String>) -> Bool {
        if text.contains("<tool_call>") { return true }
        for name in allowedNames {
            if text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#,
                options: .regularExpression) != nil { return true }
            if text.range(of: #""(?:name|tool)"\s*:\s*""# + NSRegularExpression.escapedPattern(for: name) + "\"",
                options: .regularExpression) != nil { return true }
        }
        return false
    }

    // MARK: - Scanning

    /// Index of the `}` closing the `{` at `start`, honoring JSON strings/escapes.
    static func matchingBrace(_ c: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var k = start
        while k < c.count {
            let ch = c[k]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return k }
                default: break
                }
            }
            k += 1
        }
        return nil
    }

    static func parseObject(_ s: String) -> [String: Any]? {
        if let o = jsonObject(s) as? [String: Any] { return o }
        // Models often put raw newlines/tabs inside string values.
        if let o = jsonObject(escapeControlCharsInStrings(s)) as? [String: Any] { return o }
        return nil
    }

    private static func jsonObject(_ s: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    static func escapeControlCharsInStrings(_ s: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for ch in s.unicodeScalars {
            if inString {
                if escaped { escaped = false; out.unicodeScalars.append(ch); continue }
                switch ch {
                case "\\": escaped = true; out.unicodeScalars.append(ch)
                case "\"": inString = false; out.unicodeScalars.append(ch)
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                    else { out.unicodeScalars.append(ch) }
                }
            } else {
                if ch == "\"" { inString = true }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: - Normalizing

    static func extractCalls(_ object: [String: Any], allowedNames: Set<String>) -> [ParsedToolCall] {
        // {"tool_calls": [ ... ]}
        if let list = object["tool_calls"] as? [[String: Any]] {
            return list.compactMap { normalize($0, allowedNames: allowedNames) }
        }
        if let call = normalize(object, allowedNames: allowedNames) { return [call] }
        return []
    }

    static func normalize(_ object: [String: Any], allowedNames: Set<String>) -> ParsedToolCall? {
        var obj = object
        // OpenAI style: {"type":"function","function":{"name":..,"arguments":..}}
        if let fn = obj["function"] as? [String: Any] { obj = fn }
        let name = (obj["name"] as? String) ?? (obj["tool"] as? String)
            ?? (obj["function"] as? String) ?? (obj["tool_name"] as? String)
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedNames.contains(name)
        else { return nil }

        var rawArgs: Any? = nil
        for key in ["arguments", "parameters", "args", "input"] where obj[key] != nil {
            rawArgs = obj[key]
            break
        }
        var args: [String: Any] = [:]
        switch rawArgs {
        case let d as [String: Any]: args = d
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { args = [:] }
            else if let d = parseObject(t) { args = d }
            else if let end = t.first == "{" ? matchingBrace(Array(t.unicodeScalars), from: 0) : nil,
                let d = parseObject(String(String.UnicodeScalarView(Array(t.unicodeScalars)[0...end])))
            { args = d }
            else { return nil }
        case nil, is NSNull: args = [:]
        default: return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return ParsedToolCall(name: name, argumentsJSON: json)
    }

    // MARK: - Display cleanup

    static func cleanup(_ text: String) -> String {
        var t = text
        let patterns = [
            #"<tool_call>\s*</tool_call>"#,  // emptied Hermes wrapper
            #"</?tool_call>"#,
            #"```[A-Za-z0-9_-]*\s*[}\s]*```"#,  // emptied fence (maybe with stray braces)
            #"(?m)^\s*\}+\s*$"#,  // lines of stray closing braces
            #"(?m)^\s*ALEXUS:\s*$"#,  // bare persona prefix
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
