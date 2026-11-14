import Foundation

// MARK: - Market comps (pure: parsing + math, no network)
//
// Rule of the house: the Atlas buyback is the FLOOR. Everything above it is fair
// game, and comps tell us how far above. Comps are never invented: no data means
// "no comps", and the range falls back to floor + margin only.

public enum CompKind: String, Codable, Sendable { case ask, sold, avgList }

/// One set of comparable prices from one source, e.g. "Swappa sold (Mint/Good, unlocked 128GB)".
public struct CompSet: Codable, Equatable, Sendable {
    public var source: String          // "Swappa listings", "Swappa sold", "Swappa price guide", "Marketplace (manual)"…
    public var kind: CompKind
    public var prices: [Double]        // individual prices (for avgList: the single average)
    public var count: Int              // how many listings/sales the number represents
    public var fetchedAt: Date
    public var url: String?
    public var note: String?
    public init(source: String, kind: CompKind, prices: [Double], count: Int? = nil, fetchedAt: Date,
                url: String? = nil, note: String? = nil) {
        self.source = source; self.kind = kind; self.prices = prices; self.count = count ?? prices.count
        self.fetchedAt = fetchedAt; self.url = url; self.note = note
    }
    public var stats: CompStats? { CompStats(prices) }
}

public struct CompStats: Codable, Equatable, Sendable {
    public var n: Int, min: Double, max: Double, mean: Double, median: Double, p25: Double, p75: Double
    public init?(_ xs: [Double]) {
        let s = xs.filter { $0 > 0 }.sorted()
        guard !s.isEmpty else { return nil }
        n = s.count; min = s.first!; max = s.last!
        mean = s.reduce(0, +) / Double(s.count)
        median = CompStats.percentile(s, 0.5); p25 = CompStats.percentile(s, 0.25); p75 = CompStats.percentile(s, 0.75)
    }
    /// Linear interpolation between closest ranks (same as numpy's default). `s` must be sorted.
    public static func percentile(_ s: [Double], _ p: Double) -> Double {
        guard s.count > 1 else { return s.first ?? 0 }
        let r = p * Double(s.count - 1), lo = Int(r.rounded(.down)), hi = Swift.min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }
}

/// Result of a comps lookup: every set that came back, plus failures (shown as "no comps").
public struct CompsReport: Codable, Equatable, Sendable {
    public var query: CompsQuery
    public var sets: [CompSet]
    public var errors: [String]
    public init(query: CompsQuery, sets: [CompSet], errors: [String]) { self.query = query; self.sets = sets; self.errors = errors }
    public func first(_ kind: CompKind, sourcePrefix: String) -> CompSet? {
        sets.first { $0.kind == kind && $0.source.hasPrefix(sourcePrefix) && !$0.prices.isEmpty }
    }
    public var localAsks: [Double] { sets.filter { $0.kind == .ask && $0.source.contains("manual") }.flatMap(\.prices) }
    public var isEmpty: Bool { sets.allSatisfy { $0.prices.isEmpty } }
}

public struct CompsQuery: Codable, Equatable, Sendable {
    public var model: String
    public var storage: Int
    public var carrier: String         // CarrierLock raw value
    public var grade: String
    public var zip: String
    public var city: String
    public var radiusMiles: Int
    public init(model: String, storage: Int, carrier: String, grade: String,
                zip: String = LocalPlace.zip, city: String = LocalPlace.city, radiusMiles: Int = 25) {
        self.model = model; self.storage = storage; self.carrier = carrier; self.grade = grade.uppercased()
        self.zip = zip; self.city = city; self.radiusMiles = radiusMiles
    }
    /// Key used for the manual local-ask store (location-independent on purpose: you paste what you saw).
    public var deviceKey: String { "\(pyNorm(model))|\(storage)|\(carrier)" }
}

// MARK: - Swappa

public enum Swappa {
    public static let base = "https://swappa.com"

    /// "iPhone 16 Pro" -> "apple-iphone-16-pro";  "iPhone SE (2022)" -> "apple-iphone-se-2022".
    public static func slug(_ model: String) -> String {
        var s = model.lowercased()
        s = s.replacingOccurrences(of: #"\b\d{2,4}\s*(gb|tb)\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "+", with: " plus ")
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.hasPrefix("iphone") || s.hasPrefix("ipad") { s = "apple-" + s }
        return s
    }
    /// Swappa's carrier filter value. Locked/unknown phones compare against the carrier they're on.
    public static func carrierParam(_ carrier: String) -> String? {
        switch carrier {
        case "unlocked", "unknown": return "unlocked"
        case "att_clean": return "att"
        case "verizon_locked": return "verizon"
        case "tmobile_locked": return "t-mobile"
        default: return nil
        }
    }
    public static func storageParam(_ gb: Int) -> String? {
        guard gb > 0 else { return nil }
        return gb >= 1024 && gb % 1024 == 0 ? "\(gb / 1024)tb" : "\(gb)gb"
    }
    /// PhoneGrader grade -> Swappa condition names that are comparable.
    public static func conditions(forGrade g: String) -> [String] {
        switch g.uppercased() {
        case "A": return ["Mint", "New"]
        case "B": return ["Good"]
        default: return ["Fair"]
        }
    }

    public static func query(_ q: CompsQuery) -> String {
        var items: [String] = []
        if let c = carrierParam(q.carrier) { items.append("carrier=\(c)") }
        if let s = storageParam(q.storage) { items.append("storage=\(s)") }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
    }
    public static func listingsURL(_ q: CompsQuery) -> String { "\(base)/listings/\(slug(q.model))\(query(q))" }
    public static func pricesURL(_ q: CompsQuery) -> String { "\(base)/prices/\(slug(q.model))" }
    public static func salesURL(_ q: CompsQuery) -> String { "\(base)/xui/product/\(slug(q.model))/sales\(query(q))" }

    // --- parsing (HTML fixtures in tests; no network here) ---

    public struct Listing: Equatable, Sendable { public var code: String; public var price: Double; public var condition: String? }
    public struct Sale: Equatable, Sendable { public var date: String; public var condition: String; public var carrier: String; public var storage: String; public var price: Double }
    public struct PriceRow: Equatable, Sendable { public var carrier: String; public var storage: String; public var listings: Int; public var avg: Double }

    static func text(_ html: String) -> String {
        var t = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&nbsp;", " "), ("&#39;", "'"), ("&quot;", "\"")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    static func matches(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    static func money(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }

    /// Listing cards on /listings/<slug>?carrier=…&storage=…: `data-code="X" data-price="603"` + "Fair condition".
    public static func parseListings(_ html: String) -> [Listing] {
        let parts = html.components(separatedBy: "xui_card_wrapper")
        var out: [Listing] = [], seen = Set<String>()
        for p in parts.dropFirst() {
            guard let m = matches(#"data-code="([A-Z0-9]+)"\s+data-price="([0-9.,]+)""#, p).first,
                  let price = money(m[2]), price > 0, !seen.contains(m[1]) else { continue }
            seen.insert(m[1])
            let cond = matches(#"\b(New|Mint|Good|Fair)\s+condition\b"#, text(p)).first?[1]
            out.append(Listing(code: m[1], price: price, condition: cond))
        }
        return out
    }

    /// "Sampling of recent sales" table from /xui/product/<slug>/sales: Date | Condition | Carrier | Storage | $price.
    public static func parseSales(_ html: String) -> [Sale] {
        matches(#"<tr>(.*?)</tr>"#, html).compactMap { row in
            let cells = matches(#"<td[^>]*>(.*?)</td>"#, row[1]).map { text($0[1]) }
            guard cells.count >= 5, let price = money(cells[cells.count - 1]), price > 0 else { return nil }
            return Sale(date: cells[0], condition: cells[1], carrier: cells[2], storage: cells[3], price: price)
        }
    }

    /// "Current Prices" table on /prices/<slug>: # | Carrier | Storage | Listings | Avg Price | Trade-In.
    public static func parsePriceGuide(_ html: String) -> [PriceRow] {
        matches(#"<tr>(.*?)</tr>"#, html).compactMap { row in
            let cells = matches(#"<td[^>]*>(.*?)</td>"#, row[1]).map { text($0[1]) }
            guard cells.count >= 5, let n = Int(cells[3]), let avg = money(cells[4]) else { return nil }
            return PriceRow(carrier: cells[1], storage: cells[2], listings: n, avg: avg)
        }
    }

    static func storageMatches(_ label: String, _ gb: Int) -> Bool {
        guard gb > 0 else { return true }
        let l = label.lowercased().replacingOccurrences(of: " ", with: "")
        return l == "\(gb)gb" || (gb % 1024 == 0 && l == "\(gb / 1024)tb")
    }
    static func carrierMatches(_ label: String, _ carrier: String) -> Bool {
        guard let p = carrierParam(carrier) else { return true }
        let l = label.lowercased()
        switch p {
        case "att": return l.contains("at&t") || l == "att"
        case "t-mobile": return l.contains("t-mobile")
        default: return l.contains(p)
        }
    }

    /// Turn the three parsed pages into CompSets. Grade-matched samples are used when there
    /// are at least 3; otherwise all conditions, with a note saying so.
    public static func compSets(query q: CompsQuery, listingsHTML: String?, salesHTML: String?, pricesHTML: String?,
                                fetchedAt: Date) -> [CompSet] {
        let conds = conditions(forGrade: q.grade)
        let condLabel = conds.joined(separator: "/")
        var sets: [CompSet] = []
        func pick<T>(_ all: [T], _ cond: (T) -> String?) -> (String?, [T]) {
            let matched = all.filter { cond($0).map { conds.contains($0) } ?? false }
            if matched.count >= 3 { return ("\(condLabel) condition only (grade \(q.grade))", matched) }
            return (all.isEmpty ? nil : "all conditions (only \(matched.count) \(condLabel) for grade \(q.grade))", all)
        }
        if let h = listingsHTML {
            let all = parseListings(h)
            let (note, use) = pick(all, { $0.condition })
            sets.append(CompSet(source: "Swappa listings", kind: .ask, prices: use.map(\.price), fetchedAt: fetchedAt,
                                url: listingsURL(q), note: note ?? "no listings parsed"))
        }
        if let h = salesHTML {
            let all = parseSales(h).filter { storageMatches($0.storage, q.storage) && carrierMatches($0.carrier, q.carrier) }
            let (note, use) = pick(all, { $0.condition })
            let dates = use.map(\.date)
            let span = dates.isEmpty ? "" : " · \(dates.last!)–\(dates.first!)"
            sets.append(CompSet(source: "Swappa sold", kind: .sold, prices: use.map(\.price), fetchedAt: fetchedAt,
                                url: salesURL(q), note: (note ?? "no recent sales parsed") + span))
        }
        if let h = pricesHTML {
            let rows = parsePriceGuide(h).filter { storageMatches($0.storage, q.storage) && carrierMatches($0.carrier, q.carrier) }
            if let r = rows.first {
                sets.append(CompSet(source: "Swappa price guide", kind: .avgList, prices: [r.avg], count: r.listings,
                                    fetchedAt: fetchedAt, url: pricesURL(q), note: "avg asking, \(r.carrier) \(r.storage), all conditions"))
            } else {
                sets.append(CompSet(source: "Swappa price guide", kind: .avgList, prices: [], count: 0, fetchedAt: fetchedAt,
                                    url: pricesURL(q), note: "no row for this carrier/storage"))
            }
        }
        return sets
    }
}

// MARK: - Manual local asks (Marketplace / OfferUp — never scraped)

public enum LocalAsks {
    /// "640, $699 / 650.50\n$1,050" -> [640, 699, 650.5, 1050]. Ignores anything that isn't a plausible price
    /// (e.g. "128GB", "16 Pro", "00000"): only $-prefixed numbers, or bare numbers 50–5000 not followed by GB/TB.
    public static func parse(_ text: String) -> [Double] {
        let re = try! NSRegularExpression(pattern: #"(\$)?\s*(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?(\s*(?:gb|tb|g\b|%|mi\b|miles))?"#, options: [.caseInsensitive])
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let dollar = m.range(at: 1).location != NSNotFound
            let unit = m.range(at: 4).location != NSNotFound
            if unit { return nil }
            let num = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ",", with: "")
            let frac = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            guard let v = Double(num + frac) else { return nil }
            if dollar { return v > 0 ? v : nil }
            return (50...5000).contains(v) ? v : nil
        }
    }
}

public struct LocalAskEntry: Codable, Equatable, Sendable {
    public var source: String          // "Marketplace" | "OfferUp" | "Other"
    public var prices: [Double]
    public var enteredAt: Date
    public var note: String?
    public init(source: String, prices: [Double], enteredAt: Date, note: String? = nil) {
        self.source = source; self.prices = prices; self.enteredAt = enteredAt; self.note = note
    }
    public func compSet(location: String) -> CompSet {
        CompSet(source: "\(source) (manual)", kind: .ask, prices: prices, fetchedAt: enteredAt, url: nil,
                note: "local asks you entered · \(location)" + (note.map { " · \($0)" } ?? ""))
    }
}

// MARK: - Suggested range

public struct RangeSettings: Codable, Equatable, Sendable {
    public var marginOverFloor: Double     // $ you want above the Atlas floor at minimum
    public var discount: Double            // $ under the market anchor so yours is the one that sells
    public var roundTo: Double
    public init(marginOverFloor: Double = 40, discount: Double = 25, roundTo: Double = 5) {
        self.marginOverFloor = marginOverFloor; self.discount = discount; self.roundTo = roundTo
    }
}

public struct SuggestedRange: Codable, Equatable, Sendable {
    public var floor: Double?
    public var low: Double?
    public var high: Double?
    public var anchorLow: String           // what the low end was based on
    public var anchorHigh: String
    public var explanation: [String]
    public var profitLow: Double?
    public var profitHigh: Double?
    public var buyPrice: Double?
    public var floorBound: Bool            // low end was pushed up to floor + margin
}

public enum PriceRange {
    static func round(_ v: Double, _ step: Double) -> Double { step > 0 ? (v / step).rounded() * step : v.rounded() }

    /// low  = max(floor + margin, anchor − discount)
    ///        anchor = local-ask p25 if you entered local asks, else Swappa sold average, else Swappa listing p25
    /// high = local median ask, else Swappa sold median, else Swappa listing median (never below low)
    /// No floor and no comps -> no range. Comps but no floor -> range without the floor guard (said so).
    public static func compute(floor: Double?, comps: CompsReport?, buyPrice: Double?,
                               settings s: RangeSettings = RangeSettings()) -> SuggestedRange {
        var why: [String] = []
        let local = CompStats(comps?.localAsks ?? [])
        let sold = comps?.first(.sold, sourcePrefix: "Swappa")?.stats
        let listed = comps?.first(.ask, sourcePrefix: "Swappa")?.stats

        var anchor: Double?, anchorLow = "none", anchorHigh = "none", highV: Double?
        if let l = local { anchor = l.p25; anchorLow = "local ask p25 $\(dollars(round(l.p25, 1))) (\(l.n) asks)" }
        else if let so = sold { anchor = so.mean; anchorLow = "Swappa sold avg $\(dollars(round(so.mean, 1))) (\(so.n) sales)" }
        else if let li = listed { anchor = li.p25; anchorLow = "Swappa listing p25 $\(dollars(round(li.p25, 1))) (\(li.n) listings)" }
        if let l = local { highV = l.median; anchorHigh = "local median ask $\(dollars(round(l.median, 1)))" }
        else if let so = sold { highV = so.median; anchorHigh = "Swappa sold median $\(dollars(round(so.median, 1)))" }
        else if let li = listed { highV = li.median; anchorHigh = "Swappa listing median $\(dollars(round(li.median, 1)))" }

        let guardV = floor.map { $0 + s.marginOverFloor }
        var low: Double?, floorBound = false
        if let a = anchor {
            let m = a - s.discount
            if let g = guardV, g > m { low = g; floorBound = true } else { low = m }
            why.append("Low = max(floor + $\(dollars(s.marginOverFloor)), \(anchorLow) − $\(dollars(s.discount)))\(floor == nil ? " — no Atlas floor, so no floor guard" : "").")
        } else if let g = guardV {
            low = g; floorBound = true
            why.append("No comps — low is just Atlas floor + $\(dollars(s.marginOverFloor)). No high end without market data.")
        } else {
            why.append("No Atlas floor and no comps — nothing to base a price on.")
        }
        var high = highV
        if high != nil { why.append("High = \(anchorHigh).") }
        if let l = low { low = round(l, s.roundTo) }
        if let h = high { high = round(h, s.roundTo) }
        if let l = low, let h = high, h < l {
            high = l
            why.append("Market is at or below your minimum — high clamped to low. Consider wholesaling at the floor instead.")
        }
        if floorBound, anchor != nil { why.append("Low end was raised to floor + margin (the market anchor minus discount is under it).") }
        if local == nil, anchor != nil { why.append("No local Marketplace/OfferUp asks entered — Swappa is a national, shipped market; local cash usually sells a bit lower.") }
        var pl: Double?, ph: Double?
        if let b = buyPrice { pl = low.map { $0 - b }; ph = high.map { $0 - b } }
        return SuggestedRange(floor: floor, low: low, high: high, anchorLow: anchorLow, anchorHigh: anchorHigh,
                              explanation: why, profitLow: pl, profitHigh: ph, buyPrice: buyPrice, floorBound: floorBound)
    }
}

// MARK: - Simple Marketplace / OfferUp listing template

public struct ListingTemplate: Codable, Equatable, Sendable {
    public var title: String
    public var body: String

    /// Only states what it's given: no battery line without a battery number, lock status as entered.
    /// Never mentions buyback/Atlas prices.
    public static func make(model: String, storage: Int, grade: String, gradeNotes: String?, battery: Int?,
                            carrier: String, price: Double?, location: String) -> ListingTemplate {
        let st = storage > 0 ? (storage >= 1024 && storage % 1024 == 0 ? " \(storage / 1024)TB" : " \(storage)GB") : ""
        let lock: String? = {
            switch carrier {
            case "unlocked": return "Unlocked (works on any carrier)"
            case "att_clean": return "AT&T, clean IMEI"
            case "verizon_locked": return "Verizon locked"
            case "tmobile_locked": return "T-Mobile locked"
            case "other_locked": return "Carrier locked"
            default: return nil
            }
        }()
        let shortLock: String? = carrier == "unlocked" ? "Unlocked" : (carrier == "att_clean" ? "AT&T" : nil)
        var t = "\(model)\(st)"
        if let s = shortLock { t += " \(s)" }
        if let b = battery { t += " – \(b)% Battery" }
        if let p = price { t += " – $\(dollars(p))" }
        var lines: [String] = ["\(model)\(st)"]
        lines.append("Condition: \(MarketplaceCopy.plainCondition[grade.uppercased()] ?? "see photos")")
        if let n = gradeNotes.map(MarketplaceCopy.clean), !n.isEmpty { lines.append("Notes: \(n.prefix(1).uppercased() + n.dropFirst())") }
        if let b = battery { lines.append("Battery health: \(b)%") }
        if let l = lock { lines.append("Carrier: \(l)") }
        if let p = price { lines.append("Price: $\(dollars(p))") }
        lines.append("")
        lines.append("Cash or Zelle, local pickup in \(location). Meet at a public place; test it before you pay.")
        lines.append("Message me if it's still listed — it's available.")
        return ListingTemplate(title: t, body: lines.joined(separator: "\n"))
    }
}
