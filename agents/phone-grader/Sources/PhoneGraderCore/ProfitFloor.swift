import Foundation

/// Verdicts against an asking price, using the SAME numbers as DealRule (profit is subtracted once):
///   Walk-away (break-even) = floor − gas − parts
///   Max buy (target)       = walk-away − profit target          (= DealResult.maxBuy)
///   vs an asking price:
///   Total cost    = asking + gas + parts
///   Gross spread  = floor − asking
///   Net profit    = floor − total cost        ("you make $X if Atlas buys at floor")
///   Cushion       = net profit − profit target
///   BUY  asking ≤ max buy · THIN  max buy < asking ≤ walk-away · PASS  asking > walk-away
/// No numbers when the deal is blocked (iCloud/IMEI/rig), stale, or has no floor.
public struct DealAnalysis: Equatable, Sendable, Codable {
    public var exit: Double
    public var gasCost: Double
    public var partsCost: Double
    public var breakEven: Double
    public var profitTarget: Double
    public var targetBuy: Double
    public var recommendedOffer: Double?     // nil when no deal
    public var noDeal: Bool
    public var asking: Double?
    public var totalCost: Double?
    public var grossSpread: Double?
    public var netProfit: Double?
    public var profitCushion: Double?
    public var verdict: String
}

public enum ProfitMath {
    public static let defaultProfitTarget: Double = DealDefaults.profitTarget

    public static func analyze(_ d: DealResult, asking: Double? = nil) -> DealAnalysis? {
        guard let exit = d.floor, let be = d.breakEven, let target = d.maxBuy, d.source != .none,
              !d.headline.hasPrefix("BLOCKED"), !d.headline.hasPrefix("STALE") else { return nil }
        let pf = d.profitTarget
        let noDeal = target <= 0
        var a = DealAnalysis(exit: exit, gasCost: d.gasCost, partsCost: d.partsCost, breakEven: be, profitTarget: pf,
                             targetBuy: target, recommendedOffer: noDeal ? nil : target, noDeal: noDeal, asking: nil,
                             totalCost: nil, grossSpread: nil, netProfit: nil, profitCushion: nil, verdict: "")
        if let ask = asking, ask >= 0 {
            a.asking = ask
            a.totalCost = cents(ask + d.costs.costsBeforeProfit)
            a.grossSpread = cents(exit - ask)
            a.netProfit = cents(exit - a.totalCost!)
            a.profitCushion = cents(a.netProfit! - pf)
        }
        if noDeal {
            a.verdict = "NO DEAL — max buy is $\(usd(target)) (walk-away $\(usd(be)) − $\(usd(pf)) profit target)."
        } else if let ask = a.asking, let c = a.profitCushion {
            if ask <= target { a.verdict = "BUY — asking is at/under max buy (you make $\(usd(a.netProfit!)), cushion +$\(usd(c)))." }
            else if ask <= be { a.verdict = "THIN — over max buy, under walk-away (you make $\(usd(a.netProfit!)), $\(usd(-c)) short of target). Counter at $\(usd(target))." }
            else { a.verdict = "PASS — asking is over walk-away (loses $\(usd(-a.netProfit!))). Offer $\(usd(target)) or walk." }
        } else {
            a.verdict = "Offer up to $\(usd(target)); walk away above $\(usd(be))."
        }
        return a
    }
}
