import Foundation

/// Port of resale-op-mcp/price-mcp/server.py `get_atlas_floor` + helpers.
///
/// owner, 2026-08-01: "atlas is my floor everything else is fair game".
/// This returns the FLOOR only. Three non-number answers protect money:
/// in_family (read the live sheet), off_ladder (no Atlas floor), and an
/// expired anchor (reference only, never quotable).
public struct PriceResult: Equatable, Sendable {
    public var model: String
    public var modelResolved: String?
    public var modelMatch: String?
    public var storage: Int
    public var grade: String
    public var lock: String
    public var anchoredDate: String
    public var deliveryFriday: String
    public var tabHeader: String
    public var status: String = ""
    public var floor: Double?
    public var floorQuotable = false
    public var warnings: [String] = []
    public var blockingDisclosures: [String] = []
    public var retailGuidance = "Above the floor is the owner's call — this tool does not suggest a list price."
    public var note: String?
    public var quoteSource: String?
    public var quoteDate: String?
    public var matchedRow: String?
    public var ladderFull: [(column: String, value: Double)]?

    public static func == (a: PriceResult, b: PriceResult) -> Bool {
        a.model == b.model && a.modelResolved == b.modelResolved && a.modelMatch == b.modelMatch &&
        a.status == b.status && a.floor == b.floor && a.floorQuotable == b.floorQuotable &&
        a.warnings == b.warnings && a.blockingDisclosures == b.blockingDisclosures && a.note == b.note
    }
}

public struct LadderStatus: Sendable {
    public let anchoredDate: String
    public let deliveryFriday: String
    public let tabHeader: String
    public let daysPastDelivery: Int
    public let quotable: Bool
    public let rowsCached: Int
    public let verdict: String
    public let sourceOfTruth: String
}

/// Pass-4 interpreter: pick one of `candidates` for `typed`, or nil. Returns (guess, how).
public typealias ModelInterpreter = (_ candidates: [String], _ typed: String) -> (String?, String)

public struct PriceEngine: Sendable {
    public let ladder: AtlasLadder
    public let quotes: QuoteBook

    /// Atlas column order. F is NOT D: an F is a dead phone = DOA money.
    public static let gradeToColumn: [String: Int] = ["SWAP": 0, "A": 1, "B": 2, "C": 3, "D": 4, "F": 5, "DOA": 5]

    /// Words that can sit around a model name without changing WHICH phone it is.
    static let noiseWords = [
        "apple", "iphone", "unlocked", "locked", "carrier", "factory", "clean",
        "att", "atandt", "tmobile", "verizon", "sprint", "cricket", "boost",
        "gb", "tb", "gen", "new", "used", "mint", "refurb", "refurbished",
    ]

    public init(ladder: AtlasLadder, quotes: QuoteBook) {
        self.ladder = ladder
        self.quotes = quotes
    }

    public static func todayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current            // Python date.today() is local
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: helpers (ported 1:1)

    func findQuote(model: String, storage: Int, lock: String, conditions: [String: Bool]) -> BuyerQuote? {
        for q in quotes.quotes {
            if !pyNorm(model).contains(q.match) { continue }
            if let s = q.storage, s != storage { continue }
            if let l = q.lock, pyNorm(l) != pyNorm(lock) { continue }
            if !q.requiresCondition.isEmpty && !q.requiresCondition.contains(where: { conditions[$0] == true }) {
                continue   // the damage this quote priced isn't present on this unit
            }
            return q
        }
        return nil
    }

    func advisories(for model: String) -> [String] {
        quotes.advisories.filter { pyNorm(model).contains($0.match) }.map { $0.text }
    }

    public static func residueIsNoise(_ squashedInput: String, _ matchedSquash: String) -> Bool {
        var residue = squashedInput
        if let r = residue.range(of: matchedSquash) { residue.replaceSubrange(r, with: "") }
        residue = String(residue.filter { !$0.isNumber })
        // sorted by length desc, stable (Python sorted is stable)
        let words = noiseWords.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map { $0.element }
        for w in words { residue = residue.replacingOccurrences(of: w, with: "") }
        return residue.isEmpty
    }

    /// `_canonicalize_model`: exact, squashed, embedded, interpreted.
    public func canonicalizeModel(_ model: String, interpreter: ModelInterpreter?) -> (String?, String?, String?) {
        let names = ladder.canonicalModels
        let raw = pyNorm(model)
        if names.contains(raw) { return (raw, "exact", nil) }

        var forms = [model]
        if !pySquash(model).contains("iphone") { forms.append("iphone " + model) }
        for form in forms {
            let squashed = pySquash(form)
            if squashed.isEmpty { continue }
            for c in names where pySquash(c) == squashed { return (c, "squashed", nil) }
            let hits = names.filter { !pySquash($0).isEmpty && squashed.contains(pySquash($0)) }
                .filter { PriceEngine.residueIsNoise(squashed, pySquash($0)) }
            if !hits.isEmpty {
                // Python max() returns the FIRST maximal element
                var best = hits[0]
                for h in hits.dropFirst() where pySquash(h).count > pySquash(best).count { best = h }
                return (best, "embedded", nil)
            }
        }
        let (guess, how): (String?, String)
        if let interpreter {
            let (g, h) = interpreter(names, model)
            // validated back against the list: a hallucinated name can never pass
            if let g, names.contains(pyNorm(g)) { (guess, how) = (pyNorm(g), h) } else { (guess, how) = (nil, h) }
        } else {
            (guess, how) = (nil, "disabled")
        }
        if let guess { return (guess, "interpreted", how) }
        return (nil, nil, how)
    }

    func lookupRow(model: String, storage: Int, lock: String) -> (LadderRow, Bool)? {
        let key = "\(pyNorm(model))|\(storage)|\(pyNorm(lock))"
        if let i = ladder.rowIndex[key] { return (ladder.rows[i], true) }
        let prefix = "\(pyNorm(model))|\(storage)|"
        if let row = ladder.rows.first(where: { $0.key.hasPrefix(prefix) }) { return (row, false) }
        return nil
    }

    // MARK: get_atlas_floor

    public func getAtlasFloor(
        model: String,
        storage: Int = 0,
        grade: String = "B",
        lock: String = "unlocked",
        battery: String? = nil,
        imeiClean: Bool? = nil,
        aftermarketScreen: Bool = false,
        crackedBack: Bool = false,
        today: String = PriceEngine.todayString(),
        interpreter: ModelInterpreter? = nil
    ) -> PriceResult {
        let gradeKey = grade.trimmingCharacters(in: .whitespaces).isEmpty ? "B" : grade.trimmingCharacters(in: .whitespaces).uppercased()
        let column = PriceEngine.gradeToColumn[gradeKey]
        let (resolved, how, interp) = canonicalizeModel(model, interpreter: interpreter)
        let matchModel = resolved ?? model

        var out = PriceResult(model: model, modelResolved: resolved, modelMatch: how, storage: storage,
                              grade: gradeKey, lock: lock, anchoredDate: ladder.anchoredDate,
                              deliveryFriday: ladder.deliveryFriday, tabHeader: ladder.tabHeader)

        if how == "interpreted" {
            out.blockingDisclosures.append(
                "model name INTERPRETED from \(pyRepr(model)) as \(pyRepr(resolved ?? "")) by \(interp ?? "") — " +
                "confirm the model before quoting this floor")
        } else if how == "squashed" || how == "embedded" {
            out.warnings.append("read \(pyRepr(model)) as \(pyRepr(resolved ?? "")) (\(how!) match against the ladder's own model list)")
        } else if how == nil, let interp, !interp.isEmpty {
            out.warnings.append("model interpreter did not resolve this: \(interp)")
        }

        guard let column else {
            out.status = "bad_grade"
            out.note = "Unknown grade \(pyRepr(grade)). Expected A/B/C/D/F."
            return out
        }

        // Anchor freshness. Gate card line 2: stale date = no number = no buy.
        let expired = ladder.isExpired(today: today)
        if expired {
            out.warnings.append(
                "ANCHOR EXPIRED: this ladder priced items DELIVERED by \(ladder.deliveryFriday), " +
                "which has passed. Anything shipping now falls to a later tab. Re-anchor from the " +
                "live sheet before quoting (Reminder \(ladder.reanchorReminder)).")
        }

        out.warnings.append(contentsOf: advisories(for: matchModel))

        if aftermarketScreen && ["SWAP", "A", "B"].contains(gradeKey) {
            out.warnings.append(
                "Grade \(gradeKey) claimed, but aftermarket screen = Bad LCD by Atlas's rules, " +
                "which caps this at D (DOA if untestable). Atlas will re-grade it down.")
        }

        // A real quote outranks everything below.
        let conditions = ["aftermarket_screen": aftermarketScreen, "cracked_back": crackedBack]
        if let q = findQuote(model: matchModel, storage: storage, lock: lock, conditions: conditions), q.supersedesLadder {
            out.status = "actual_quote"
            out.floor = q.quoted
            out.floorQuotable = true
            out.quoteSource = q.buyer
            out.quoteDate = q.dateApprox + (q.dateExactRecorded ? "" : " (exact date not recorded)")
            out.note = "REAL QUOTE from \(q.buyer): $\(dollars(q.quoted)). This beats the published " +
                "ladder and the ladder is not consulted. \(q.note)"
            if !q.units.isEmpty { out.warnings.append("Applies to: " + q.units.joined(separator: ", ")) }
            return out
        }

        // Off-ladder: RAW input wins (either raw or resolved closes the gate).
        for entry in ladder.notOnLadder where pyNorm(model).contains(entry.match) || pyNorm(matchModel).contains(entry.match) {
            out.status = "off_ladder"
            out.floor = nil
            out.note = "NO ATLAS FLOOR EXISTS for this device. Gate card line 6: not in the ladder = " +
                "research item, not a purchase. Route to Brett, retail, or parts. " + entry.note
            return out
        }

        guard let (row, exact) = lookupRow(model: matchModel, storage: storage, lock: lock) else {
            if let family = ladder.quotableFamilies.first(where: { pyNorm(matchModel).contains($0) }) {
                out.status = "in_family"
                out.note = "Atlas still buys the \(family) family (all storages, both lock states), but this " +
                    "exact row was never transcribed into the cache. Read the live sheet for " +
                    "\(model) \(storage)GB \(lock). Deliberately NOT guessed — a made-up floor is worse " +
                    "than no floor."
            } else {
                out.status = "off_ladder"
                out.note = "\(model) is not in the cached ladder and not in a known-quotable family. " +
                    "Treat as off-ladder (gate card line 6) until the live sheet says otherwise."
            }
            return out
        }

        let floor = row.ladder[column]
        out.status = "on_ladder"
        out.matchedRow = row.label
        out.ladderFull = Array(zip(ladder.columns, row.ladder)).map { (column: $0.0, value: $0.1) }
        out.floor = floor
        out.floorQuotable = !expired

        if !exact {
            out.warnings.append(
                "Lock state \(pyRepr(lock)) not matched exactly — used row \(pyRepr(row.label)). Lock status is " +
                "worth ~7.75x a storage upgrade on this sheet; confirm before quoting.")
        }
        if gradeKey == "F" {
            out.blockingDisclosures.append("grade F — priced at Atlas DOA, not D")
            out.warnings.append("Dead/non-functional units usually do better at Parts than Atlas DOA.")
        }
        if let b = pyIntPercent(battery), b < 80 {
            out.warnings.append(
                "Battery \(b)% — \(ladder.deductionFlags["battery_under_80"] ?? "") " +
                "The \(dollars(floor)) above does NOT include it.")
        }
        if imeiClean == false {
            out.blockingDisclosures.append("IMEI not clean — " + (ladder.deductionFlags["bad_esn"] ?? ""))
        }
        if expired {
            out.note = "Reference only: $\(dollars(floor)) was the Grade \(gradeKey) number on an EXPIRED tab. " +
                "Not quotable until re-anchored."
        } else {
            out.note = "Atlas floor $\(dollars(floor)) at Grade \(gradeKey). Sell above this or send it to Atlas — " +
                "what you ask above it is your call."
        }
        return out
    }

    public func ladderStatus(today: String = PriceEngine.todayString()) -> LadderStatus {
        let days = ladder.daysPastDelivery(today: today)
        let verdict = days <= 0 ? "FRESH — quotable." :
            "EXPIRED \(days)d past its delivery Friday. Gate card line 2: stale date = no number. " +
            "Re-anchor from the live sheet (Reminder \(ladder.reanchorReminder), " +
            "Exit Profile \(ladder.exitProfileRecord))."
        return LadderStatus(anchoredDate: ladder.anchoredDate, deliveryFriday: ladder.deliveryFriday,
                            tabHeader: ladder.tabHeader, daysPastDelivery: days, quotable: days <= 0,
                            rowsCached: ladder.rows.count, verdict: verdict, sourceOfTruth: ladder.sourceOfTruth)
    }
}
