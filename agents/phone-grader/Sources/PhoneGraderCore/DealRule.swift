import Foundation

/// The owner's buy rule — ONE formula (Oct 16 2026; replaces the $35/$50 buffers, the fixed $6
/// driving cost and the separate profit-floor subtraction from 52c53a4):
///
///   max buy = floor − gas − repair parts − profit target
///   gas     = round-trip miles ÷ MPG × $/gal
///
/// `breakEven` (walk-away) = floor − gas − parts: pay more than this and you lose money.
/// The floor is a buyer quote (beats the ladder) or the Atlas ladder floor.
/// An expired ladder floor is a REFERENCE ONLY (gate card line 2: stale date =
/// no number = no buy) — the app shows it, labelled, but never as a buy number.
public struct DealResult: Equatable, Sendable {
    public enum Source: String, Sendable, Codable { case buyerQuote, atlasLadder, none }
    public var floor: Double?
    public var source: Source
    public var costs: DealCosts
    /// floor − gas − parts (walk-away), when a floor exists.
    public var breakEven: Double?
    /// floor − gas − parts − profit, when a floor exists (may be ≤ 0).
    public var maxBuy: Double?
    /// true only when maxBuy is safe to act on (fresh ladder or a real quote, > 0, not blocked).
    public var actionable: Bool
    public var headline: String
    public var detail: String

    public var gasCost: Double { costs.gasCost }
    public var partsCost: Double { costs.partsCost }
    public var profitTarget: Double { costs.profitTarget }
}

public enum DealRule {
    public static func formula(floor: Double, costs c: DealCosts) -> String {
        let mb = cents(floor - c.gasCost - c.partsCost - c.profitTarget)
        return "$\(usd(floor)) floor − $\(usd(c.gasCost)) gas (\(c.gas.explanation)) − $\(usd(c.partsCost)) parts − $\(usd(c.profitTarget)) profit = $\(usd(mb)) max buy"
    }

    public static func compute(floor: Double?, floorQuotable: Bool, source: DealResult.Source,
                               costs: DealCosts) -> DealResult {
        guard let floor, source != .none else {
            return DealResult(floor: nil, source: .none, costs: costs, breakEven: nil, maxBuy: nil,
                              actionable: false, headline: "No max buy — no floor",
                              detail: "No Atlas floor or buyer quote for this device. Not on the ladder = research item, not a purchase. Get a buyer quote first.")
        }
        let be = cents(floor - costs.costsBeforeProfit)
        let maxBuy = cents(be - costs.profitTarget)
        let math = formula(floor: floor, costs: costs)
        var r = DealResult(floor: floor, source: source, costs: costs, breakEven: be, maxBuy: maxBuy,
                           actionable: false, headline: "", detail: math)
        if !floorQuotable {
            r.headline = "STALE — no buy number"
            r.detail = "Reference only (expired Atlas tab): \(math). Import a fresh price list or add a buyer quote before buying."
        } else if maxBuy <= 0 {
            r.headline = "PASS — no profitable buy"
        } else {
            r.actionable = true
            r.headline = "Max buy $\(usd(maxBuy))"
        }
        return r
    }

    /// Convenience: derive from a price-gate result, or a one-off buyer quote that beats it.
    public static func compute(gate: PriceResult?, manualQuote: Double?, costs: DealCosts) -> DealResult {
        if let q = manualQuote, q > 0 {
            return compute(floor: q, floorQuotable: true, source: .buyerQuote, costs: costs)
        }
        guard let gate, let f = gate.floor else {
            return compute(floor: nil, floorQuotable: false, source: .none, costs: costs)
        }
        return compute(floor: f, floorQuotable: gate.floorQuotable,
                       source: gate.status == "actual_quote" ? .buyerQuote : .atlasLadder, costs: costs)
    }
}

/// Snapshot of the whole calculation, saved on History records (private — never in a QR receipt).
public struct DealBreakdown: Codable, Equatable, Sendable {
    public var floor: Double?
    public var source: DealResult.Source
    public var gas: GasInputs
    public var gasCost: Double
    public var parts: RepairParts
    public var partCosts: PartCosts
    public var partsCost: Double
    /// Set when partsCost came from the Parts log (actual purchases linked to this phone).
    public var partsActualFromLog: Double?
    public var profitTarget: Double
    public var breakEven: Double?
    public var maxBuy: Double?
    public var actionable: Bool
    public var headline: String
    public var formula: String
    /// What you clear if you pay max buy and Atlas pays the floor (= profit target).
    public var youMakeAtFloor: Double?
    public var asking: Double?
    public var netProfitAtAsking: Double?
    public var verdict: String?
    public var computedAt: Date

    public init(_ d: DealResult, analysis: DealAnalysis? = nil, at: Date = Date()) {
        floor = d.floor; source = d.source; gas = d.costs.gas; gasCost = d.gasCost; parts = d.costs.parts
        partCosts = d.costs.partCosts; partsCost = d.partsCost; partsActualFromLog = d.costs.actualPartsCost; profitTarget = d.profitTarget
        breakEven = d.breakEven; maxBuy = d.maxBuy; actionable = d.actionable; headline = d.headline
        formula = d.floor.map { DealRule.formula(floor: $0, costs: d.costs) } ?? d.detail
        youMakeAtFloor = d.maxBuy.map { _ in d.profitTarget }
        asking = analysis?.asking; netProfitAtAsking = analysis?.netProfit; verdict = analysis?.verdict
        computedAt = at
    }
}
