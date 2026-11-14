import Foundation

public struct LadderRow: Equatable, Sendable {
    public let key: String
    public let label: String
    public let ladder: [Double]
}

/// atlas-ladder.json, the same file resale-op-mcp/price-mcp reads.
/// Row ORDER is preserved from the file because server.py's inexact-lock
/// fallback (`_lookup_row` prefix scan) returns the FIRST matching row in
/// dict (= file) order. Swift dictionaries are unordered, so we recover the order
/// from the raw JSON text.
public struct AtlasLadder: Sendable {
    public let anchoredDate: String
    public let deliveryFriday: String
    public let tabHeader: String
    public let reanchorReminder: String
    public let exitProfileRecord: String
    public let sourceOfTruth: String
    public let columns: [String]
    public let rows: [LadderRow]
    public let rowIndex: [String: Int]
    public let quotableFamilies: [String]
    public let notOnLadder: [(match: String, note: String)]
    public let deductionFlags: [String: String]
    public let sheetAnomalies: [String]

    public enum LoadError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let m): return "Not a valid Atlas ladder file: \(m)" }
        }
    }

    public init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.invalid("top level is not an object")
        }
        func str(_ k: String, required: Bool = true) throws -> String {
            if let v = obj[k] as? String { return v }
            if required { throw LoadError.invalid("missing \"\(k)\"") }
            return ""
        }
        anchoredDate = try str("anchored_date")
        deliveryFriday = try str("delivery_friday")
        guard deliveryFriday.count == 10, deliveryFriday.dropFirst(4).first == "-" else {
            throw LoadError.invalid("delivery_friday must be YYYY-MM-DD")
        }
        tabHeader = try str("tab_header_verbatim", required: false)
        reanchorReminder = try str("reanchor_reminder", required: false)
        exitProfileRecord = try str("exit_profile_record", required: false)
        sourceOfTruth = try str("_SOURCE_OF_TRUTH", required: false)
        guard let cols = obj["columns"] as? [String], cols.count == 6 else {
            throw LoadError.invalid("\"columns\" must list 6 grades (SWAP, A, B, C, D, DOA)")
        }
        columns = cols
        guard let rawRows = obj["rows"] as? [String: Any], !rawRows.isEmpty else {
            throw LoadError.invalid("missing \"rows\"")
        }
        let order = AtlasLadder.keyOrder(in: data, keys: Set(rawRows.keys))
        var built: [LadderRow] = []
        for k in order {
            guard let r = rawRows[k] as? [String: Any],
                  let ladder = r["ladder"] as? [NSNumber], ladder.count == 6 else {
                throw LoadError.invalid("row \(k) has no 6-value ladder")
            }
            built.append(LadderRow(key: k, label: (r["label"] as? String) ?? k, ladder: ladder.map { $0.doubleValue }))
        }
        rows = built
        var idx: [String: Int] = [:]
        for (i, r) in built.enumerated() where idx[r.key] == nil { idx[r.key] = i }
        rowIndex = idx
        quotableFamilies = (obj["quotable_families"] as? [String]) ?? []
        notOnLadder = ((obj["not_on_current_ladder"] as? [[String: Any]]) ?? []).compactMap {
            guard let m = $0["match"] as? String else { return nil }
            return (m, ($0["note"] as? String) ?? "")
        }
        var flags: [String: String] = [:]
        for (k, v) in (obj["deduction_flags"] as? [String: Any]) ?? [:] { if let s = v as? String { flags[k] = s } }
        deductionFlags = flags
        sheetAnomalies = (obj["_SHEET_ANOMALIES"] as? [String]) ?? []
    }

    /// Recover the file order of the `rows` keys ("model|storage|lock").
    static func keyOrder(in data: Data, keys: Set<String>) -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*\|(?:[^"\\]|\\.)*)"\s*:\s*\{"#) else {
            return keys.sorted()
        }
        var seen = Set<String>(), out: [String] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            if keys.contains(k), !seen.contains(k) { seen.insert(k); out.append(k) }
        }
        // Anything the scan missed (escaped keys etc.) goes last, sorted.
        out += keys.subtracting(seen).sorted()
        return out
    }

    /// `_canonical_models`: sorted set of the model part of every row key.
    public var canonicalModels: [String] {
        Array(Set(rows.map { String($0.key.split(separator: "|", omittingEmptySubsequences: false)[0]) })).sorted()
    }

    /// days since delivery Friday (positive = expired). `today` is YYYY-MM-DD.
    public func daysPastDelivery(today: String) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let a = f.date(from: deliveryFriday), let b = f.date(from: today) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86400).rounded())
    }
    public func isExpired(today: String) -> Bool { today > deliveryFriday }
}

public struct BuyerQuote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var match: String
    public var storage: Int?
    public var lock: String?
    public var buyer: String
    public var quoted: Double
    public var dateApprox: String
    public var dateExactRecorded: Bool
    public var units: [String]
    public var requiresCondition: [String]
    public var supersedesLadder: Bool
    public var note: String

    public init(match: String, storage: Int?, lock: String?, buyer: String, quoted: Double,
                dateApprox: String, dateExactRecorded: Bool, units: [String] = [],
                requiresCondition: [String] = [], supersedesLadder: Bool = true, note: String = "") {
        self.match = match; self.storage = storage; self.lock = lock; self.buyer = buyer
        self.quoted = quoted; self.dateApprox = dateApprox; self.dateExactRecorded = dateExactRecorded
        self.units = units; self.requiresCondition = requiresCondition
        self.supersedesLadder = supersedesLadder; self.note = note
    }
}

/// actual-quotes.json: real buyer quotes (beat the ladder) + per-model advisories.
public struct QuoteBook: Sendable {
    public var quotes: [BuyerQuote]
    public var advisories: [(match: String, text: String)]

    public init(quotes: [BuyerQuote] = [], advisories: [(match: String, text: String)] = []) {
        self.quotes = quotes; self.advisories = advisories
    }

    public init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AtlasLadder.LoadError.invalid("quotes file is not an object")
        }
        quotes = ((obj["quotes"] as? [[String: Any]]) ?? []).compactMap { q in
            guard let match = q["match"] as? String, let quoted = q["quoted"] as? NSNumber else { return nil }
            return BuyerQuote(
                match: match,
                storage: (q["storage"] as? NSNumber)?.intValue,
                lock: q["lock"] as? String,
                buyer: (q["buyer"] as? String) ?? "unknown buyer",
                quoted: quoted.doubleValue,
                dateApprox: (q["date_approx"] as? String) ?? "",
                dateExactRecorded: (q["date_exact_recorded"] as? Bool) ?? false,
                units: (q["units"] as? [String]) ?? [],
                requiresCondition: (q["requires_condition"] as? [String]) ?? [],
                supersedesLadder: (q["supersedes_ladder"] as? Bool) ?? false,
                note: (q["note"] as? String) ?? "")
        }
        advisories = ((obj["advisories"] as? [[String: Any]]) ?? []).compactMap {
            guard let m = $0["match"] as? String, let t = $0["text"] as? String else { return nil }
            return (m, t)
        }
    }

    /// User-entered quotes are checked FIRST (newest evidence wins), then bundled ones.
    public func merged(withUserQuotes user: [BuyerQuote]) -> QuoteBook {
        QuoteBook(quotes: user + quotes, advisories: advisories)
    }
}
