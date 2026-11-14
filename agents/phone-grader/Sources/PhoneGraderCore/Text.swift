import Foundation

/// Python `_norm`: lowercase, collapse all whitespace runs to one space, trim.
public func pyNorm(_ text: String?) -> String {
    (text ?? "").lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

/// Python `_squash`: `_norm` with spaces removed.
public func pySquash(_ text: String?) -> String {
    pyNorm(text).replacingOccurrences(of: " ", with: "")
}

/// Python `repr()` of a str, close enough for the warning strings ('...').
func pyRepr(_ s: String) -> String {
    if s.contains("'") && !s.contains("\"") { return "\"\(s)\"" }
    return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
}

/// Python `int(str(x).strip().rstrip("%"))`, returning nil on failure.
public func pyIntPercent(_ value: String?) -> Int? {
    guard let value else { return nil }
    var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("%") { s.removeLast() }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)   // int() tolerates surrounding whitespace
    if s.hasPrefix("+") { s.removeFirst() }
    guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { return nil }
    return Int(s)
}

/// Format a dollar amount like Python would print an int (or float) floor.
public func dollars(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return String(v)
}
