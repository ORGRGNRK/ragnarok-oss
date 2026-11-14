import Foundation

/// One part purchase the owner logged (or imported from an Amazon Business order report).
public struct PartPurchase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var item: String
    public var supplier: String
    public var cost: Double
    /// Optional link to the History record (phone) the part went into.
    public var recordId: Int?
    public var note: String?
    public static let defaultSupplier = "Amazon"
    public init(id: UUID = UUID(), date: Date, item: String, supplier: String = PartPurchase.defaultSupplier,
                cost: Double, recordId: Int? = nil, note: String? = nil) {
        self.id = id; self.date = date; self.item = item; self.supplier = supplier; self.cost = cost
        self.recordId = recordId; self.note = note
    }
}

public enum PartsLedger {
    static var monthFmt: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles"); f.dateFormat = "yyyy-MM"; return f
    }
    public static func total(_ p: [PartPurchase]) -> Double { cents(p.reduce(0) { $0 + $1.cost }) }
    /// ("2026-10", total) newest month first.
    public static func byMonth(_ p: [PartPurchase]) -> [(month: String, total: Double, count: Int)] {
        let f = monthFmt
        let g = Dictionary(grouping: p) { f.string(from: $0.date) }
        return g.keys.sorted(by: >).map { k in (month: k, total: total(g[k]!), count: g[k]!.count) }
    }
    /// Actual parts cost logged against a phone, or nil when nothing is linked (→ placeholder costs apply).
    public static func actualCost(_ p: [PartPurchase], recordId: Int?) -> Double? {
        guard let recordId else { return nil }
        let linked = p.filter { $0.recordId == recordId }
        return linked.isEmpty ? nil : total(linked)
    }
}

/// Amazon Business "Orders and shipments" / order-history CSV → part purchases (date, item title, total).
public enum AmazonBusinessCSV {
    public struct Preview: Equatable, Sendable {
        public var rows: [PartPurchase]
        public var skipped: [String]          // human-readable reasons, e.g. "line 7: no total"
        public var columns: (date: String, item: String, total: String)
        public static func == (a: Preview, b: Preview) -> Bool {
            a.rows == b.rows && a.skipped == b.skipped && a.columns.date == b.columns.date &&
            a.columns.item == b.columns.item && a.columns.total == b.columns.total
        }
    }
    public enum ParseError: LocalizedError, Equatable {
        case empty, missingColumn(String)
        public var errorDescription: String? {
            switch self {
            case .empty: return "The CSV is empty."
            case .missingColumn(let c): return "Couldn't find a \(c) column in the CSV header."
            }
        }
    }
    static let dateCols = ["order date", "date", "payment date", "shipment date"]
    static let itemCols = ["title", "item title", "product title", "item name", "product name", "description"]
    /// Item-level totals first (one row per item); order totals last.
    static let totalCols = ["item net total", "item total", "item subtotal", "item including tax", "total", "order net total", "order total", "amount"]

    /// RFC-4180-ish CSV: quoted fields, doubled quotes, commas/newlines inside quotes, BOM.
    public static func rows(_ text: String) -> [[String]] {
        var out: [[String]] = []; var row: [String] = []; var field = ""; var q = false
        var it = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)[...]
        while let c = it.popFirst() {
            if q {
                if c == "\"" { if it.first == "\"" { field.append("\""); it.removeFirst() } else { q = false } }
                else { field.append(c) }
            } else {
                switch c {
                case "\"": q = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r": row.append(field); field = ""; if !(row.count == 1 && row[0].isEmpty) { out.append(row) }; row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); out.append(row) }
        return out
    }

    static func money(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        let neg = t.hasPrefix("(") || t.hasPrefix("-")
        t = t.replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
        guard let v = Double(t) else { return nil }
        return neg ? -v : v
    }
    static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MM/dd/yy", "M/d/yy", "dd-MMM-yyyy", "MMM d, yyyy", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "America/Los_Angeles"); f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    public static func preview(_ text: String, supplier: String = PartPurchase.defaultSupplier) throws -> Preview {
        let all = rows(text)
        guard let header = all.first else { throw ParseError.empty }
        let h = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String], _ what: String) throws -> Int {
            for n in names { if let i = h.firstIndex(of: n) { return i } }
            throw ParseError.missingColumn(what)
        }
        let di = try col(dateCols, "date (Order Date)"), ii = try col(itemCols, "item title (Title)"), ti = try col(totalCols, "total (Item Net Total / Item Subtotal)")
        var out: [PartPurchase] = []; var skipped: [String] = []
        for (n, r) in all.dropFirst().enumerated() {
            let line = n + 2
            func cell(_ i: Int) -> String { i < r.count ? r[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
            guard let d = date(cell(di)) else { skipped.append("line \(line): unreadable date '\(cell(di))'"); continue }
            let item = cell(ii)
            guard !item.isEmpty else { skipped.append("line \(line): no item title"); continue }
            guard let v = money(cell(ti)) else { skipped.append("line \(line): no total"); continue }
            out.append(PartPurchase(date: d, item: item, supplier: supplier, cost: cents(v)))
        }
        return Preview(rows: out, skipped: skipped, columns: (header[di], header[ii], header[ti]))
    }
}
