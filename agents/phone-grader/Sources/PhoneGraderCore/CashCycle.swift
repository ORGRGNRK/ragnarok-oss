import Foundation

/// The economic cash conversion cycle for one phone: days from the first dollar out (parts bought ahead, or the
/// phone itself) to the day the sale money lands, plus what that cash earned while it was tied up.
///
///     cycle  = first cash out → cash in          (economic CCC; cash buys mean nothing is paid later, so DPO ≤ 0)
///     held   = bought → sold                     (DIO: days in inventory)
///     payout = sold → paid                       (DSO: 0 for Marketplace cash; eBay/Swappa payouts lag)
///     parts lead = first part paid → bought      (parts paid for before the phone lengthen the cycle)
///     cash tied = paid + parts + gas · return on cash = profit ÷ cash tied · annualized = × 365 ÷ cycle days
///
/// Nothing is guessed: no buy date → no cycle. A missing payout date uses the sold date and says so.
public struct CashCycle: Equatable, Sendable {
    public var recordId: Int
    public var boughtAt: Date?
    public var firstCashOut: Date?
    public var listedAt: Date?
    public var soldAt: Date?
    public var cashInAt: Date?
    /// true when cashInAt is the sold date because no payout was logged.
    public var cashInAssumed: Bool
    public var cashTied: Double?
    public var profit: Double?
    /// true when parts cost comes from the max-buy placeholder, not the parts log.
    public var partsEstimated: Bool
    public var daysToList: Int?
    public var daysHeld: Int?
    public var daysToCash: Int?
    public var partsLeadDays: Int?
    /// Closed: first cash out → cash in. Open (unsold): first cash out → now, so far.
    public var cycleDays: Int?
    public var isOpen: Bool
    /// What is missing, in plain words, with the command that fills it.
    public var unknowns: [String]

    /// parts: (date, cost) logged against this phone in the parts log. placeholderParts / gas: from the deal breakdown.
    public init(recordId: Int, sale: SaleTracking, parts: [(date: Date, cost: Double)], placeholderParts: Double?,
                gas: Double?, now: Date = Date(), calendar: Calendar = .current) {
        func days(_ a: Date?, _ b: Date?) -> Int? {
            guard let a, let b else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day
        }
        self.recordId = recordId
        boughtAt = sale.boughtAt; listedAt = sale.listedAt; soldAt = sale.soldAt
        cashInAt = sale.paidAt ?? sale.soldAt
        cashInAssumed = sale.paidAt == nil && sale.soldAt != nil
        isOpen = sale.soldAt == nil
        firstCashOut = sale.boughtAt.map { b in ([b] + parts.map(\.date)).min()! }

        let partsCost: Double? = parts.isEmpty ? placeholderParts : parts.reduce(0) { $0 + $1.cost }
        partsEstimated = parts.isEmpty && (placeholderParts ?? 0) > 0
        cashTied = sale.purchasePrice.map { cents($0 + (partsCost ?? 0) + (gas ?? 0)) }
        profit = sale.actualProfit(partsCost: partsCost, gasCost: gas).map(cents)

        daysToList = days(boughtAt, listedAt)
        daysHeld = days(boughtAt, soldAt)
        daysToCash = days(soldAt, cashInAt)
        partsLeadDays = days(firstCashOut, boughtAt)
        cycleDays = days(firstCashOut, isOpen ? now : cashInAt)

        var u: [String] = []
        if sale.boughtAt == nil { u.append("no buy date — pgctl history bought \(recordId) PRICE --at DATE") }
        if sale.purchasePrice == nil { u.append("no purchase price — pgctl history bought \(recordId) PRICE") }
        if cashInAssumed { u.append("payout not logged — cash in taken as the sold date (pgctl history paid \(recordId) --at DATE)") }
        if partsEstimated { u.append("parts cost is the max-buy placeholder, not the parts log") }
        unknowns = u
    }

    public var returnOnCash: Double? {
        guard !isOpen, let p = profit, let c = cashTied, c > 0 else { return nil }
        return p / c
    }
    /// Return on cash scaled to a year at this cycle length (a same-day flip counts as 1 day).
    public var annualizedReturn: Double? {
        guard let r = returnOnCash, let d = cycleDays else { return nil }
        return r * 365 / Double(max(d, 1))
    }
    public var profitPerDay: Double? {
        guard !isOpen, let p = profit, let d = cycleDays else { return nil }
        return p / Double(max(d, 1))
    }
    /// Cash × days it was tied up (the capital cost of the flip).
    public var dollarDays: Double? {
        guard let c = cashTied, let d = cycleDays else { return nil }
        return c * Double(max(d, 1))
    }

    public var lines: [String] {
        func d(_ v: Int?) -> String { v.map { "\($0)d" } ?? "unknown" }
        func usd(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "unknown" }
        var l = [isOpen ? "Cycle so far: \(d(cycleDays)) (unsold — cash still out)" : "Cash cycle: \(d(cycleDays)) first cash out → cash in"]
        l.append("  bought → listed \(d(daysToList)) · held (bought → sold) \(d(daysHeld)) · payout (sold → paid) \(isOpen ? "–" : d(daysToCash))\(cashInAssumed ? " (assumed)" : "")")
        if let p = partsLeadDays, p > 0 { l.append("  parts paid \(p)d before the phone") }
        l.append("  cash tied \(usd(cashTied))\(partsEstimated ? " (parts estimated)" : "") · profit \(isOpen ? "–" : usd(profit))")
        if let r = returnOnCash {
            l.append(String(format: "  return on cash %.1f%% · annualized %.0f%% · $%.2f/day", r * 100, (annualizedReturn ?? 0) * 100, profitPerDay ?? 0))
        }
        l += unknowns.map { "  UNKNOWN: \($0)" }
        return l
    }
}

/// History-wide cash cycle over phones you actually bought (a purchase price or buy date is logged).
public struct CashCycleSummary: Equatable, Sendable {
    public var closed: [CashCycle]
    public var open: [CashCycle]
    /// Bought phones whose cycle cannot be computed (no buy date or no purchase price).
    public var unknown: [CashCycle]

    public init(_ cycles: [CashCycle]) {
        let complete = cycles.filter { $0.cycleDays != nil && $0.cashTied != nil }
        closed = complete.filter { !$0.isOpen }
        open = complete.filter(\.isOpen)
        unknown = cycles.filter { $0.cycleDays == nil || $0.cashTied == nil }
    }

    func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    public var avgCycleDays: Double? { avg(closed.compactMap { $0.cycleDays.map(Double.init) }) }
    /// Cycle length weighted by cash tied: an expensive phone sitting counts for more than a cheap one.
    public var cashWeightedCycleDays: Double? {
        let cash = closed.compactMap(\.cashTied).reduce(0, +)
        guard cash > 0 else { return nil }
        return closed.compactMap(\.dollarDays).reduce(0, +) / cash
    }
    public var avgDaysHeld: Double? { avg(closed.compactMap { $0.daysHeld.map(Double.init) }) }
    public var avgDaysToCash: Double? { avg(closed.compactMap { $0.daysToCash.map(Double.init) }) }
    /// How many times a dollar goes round in a year at the cash-weighted cycle.
    public var turnsPerYear: Double? { cashWeightedCycleDays.map { 365 / max($0, 1) } }
    public var totalProfit: Double { cents(closed.compactMap(\.profit).reduce(0, +)) }
    /// Pooled: total profit ÷ total dollar-days × 365 — the yearly return on the cash the flips actually used.
    public var annualizedReturn: Double? {
        let dd = closed.compactMap(\.dollarDays).reduce(0, +)
        return dd > 0 ? totalProfit / dd * 365 : nil
    }
    public var cashOutNow: Double { cents(open.compactMap(\.cashTied).reduce(0, +)) }
    public var oldestOpenDays: Int? { open.compactMap(\.cycleDays).max() }
    public var assumedPayouts: Int { closed.filter(\.cashInAssumed).count }

    public var lines: [String] {
        func f(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "unknown" }
        var l = ["Closed cycles \(closed.count) · open \(open.count) · can't compute \(unknown.count)"]
        if closed.isEmpty {
            l.append("Cash cycle: unknown — no sold phone has a buy date and purchase price yet")
        } else {
            l.append("Cash cycle: avg \(f(avgCycleDays, "%.1f"))d · cash-weighted \(f(cashWeightedCycleDays, "%.1f"))d · \(f(turnsPerYear, "%.1f")) turns/yr")
            l.append("  held (bought → sold) avg \(f(avgDaysHeld, "%.1f"))d · payout (sold → paid) avg \(f(avgDaysToCash, "%.1f"))d\(assumedPayouts > 0 ? " (\(assumedPayouts) assumed same-day)" : "")")
            l.append("  profit $\(String(format: "%.2f", totalProfit)) · annualized return on cash \(f(annualizedReturn.map { $0 * 100 }, "%.0f%%"))")
        }
        if !open.isEmpty { l.append("Cash out now $\(String(format: "%.2f", cashOutNow)) in \(open.count) unsold · oldest \(oldestOpenDays.map { "\($0)d" } ?? "unknown")") }
        for c in unknown { l.append("  #\(c.recordId) UNKNOWN: " + c.unknowns.filter { !$0.hasPrefix("payout") && !$0.hasPrefix("parts") }.joined(separator: "; ")) }
        return l
    }
    /// One line for the History header.
    public var text: String {
        guard let w = cashWeightedCycleDays else {
            return unknown.isEmpty && open.isEmpty ? "Cash cycle: no bought phones logged" :
                "Cash cycle: unknown (\(closed.count) closed · \(open.count) open · \(unknown.count) missing buy data)"
        }
        var b = [String(format: "Cash cycle %.0fd", w)]
        if let t = turnsPerYear { b.append(String(format: "%.1f turns/yr", t)) }
        if let r = annualizedReturn { b.append(String(format: "%.0f%%/yr on cash", r * 100)) }
        if !open.isEmpty { b.append(String(format: "$%.0f out in %d unsold", cashOutNow, open.count)) }
        return b.joined(separator: " · ")
    }
}
