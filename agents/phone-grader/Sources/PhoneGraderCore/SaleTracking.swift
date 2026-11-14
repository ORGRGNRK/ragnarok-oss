import Foundation

/// One listing-price change.
public struct PricePoint: Codable, Equatable, Sendable {
    public var price: Int
    public var at: Date
    public init(price: Int, at: Date) { self.price = price; self.at = at }
}

/// Private sale tracking for a History record (never in buyer-facing text, QR or share photo).
/// Every field is optional and decoded with decodeIfPresent, so old records (no `sale` key, or a partial one) load empty.
public struct SaleTracking: Codable, Equatable, Sendable {
    public var listingPrice: Int?
    public var listedAt: Date?
    public var priceHistory: [PricePoint] = []
    public var soldPrice: Int?
    public var soldAt: Date?
    /// What you actually paid for the phone (manual). Needed for actual profit.
    public var purchasePrice: Double?
    /// When the purchase cash left (the day you bought the phone). Start of the cash cycle.
    public var boughtAt: Date?
    /// When the sale money actually landed (payout). nil = not logged; the cash cycle then uses soldAt and says so.
    public var paidAt: Date?
    public var clicks: Int?
    public var saves: Int?
    public var messages: Int?
    public var statsCheckedAt: Date?

    public init() {}
    enum CodingKeys: String, CodingKey { case listingPrice, listedAt, priceHistory, soldPrice, soldAt, purchasePrice, boughtAt, paidAt, clicks, saves, messages, statsCheckedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        listingPrice = try c.decodeIfPresent(Int.self, forKey: .listingPrice)
        listedAt = try c.decodeIfPresent(Date.self, forKey: .listedAt)
        priceHistory = try c.decodeIfPresent([PricePoint].self, forKey: .priceHistory) ?? []
        soldPrice = try c.decodeIfPresent(Int.self, forKey: .soldPrice)
        soldAt = try c.decodeIfPresent(Date.self, forKey: .soldAt)
        purchasePrice = try c.decodeIfPresent(Double.self, forKey: .purchasePrice)
        boughtAt = try c.decodeIfPresent(Date.self, forKey: .boughtAt)
        paidAt = try c.decodeIfPresent(Date.self, forKey: .paidAt)
        clicks = try c.decodeIfPresent(Int.self, forKey: .clicks)
        saves = try c.decodeIfPresent(Int.self, forKey: .saves)
        messages = try c.decodeIfPresent(Int.self, forKey: .messages)
        statsCheckedAt = try c.decodeIfPresent(Date.self, forKey: .statsCheckedAt)
    }

    public var isEmpty: Bool { self == SaleTracking() }
    public var isSold: Bool { soldPrice != nil }

    /// Sets/changes the listing price; listedAt defaults to the first time a price is set. Records each change.
    public mutating func setListing(_ price: Int, at: Date = Date()) {
        if listedAt == nil || at < listedAt! { listedAt = at }   // a back-dated price moves listedAt earlier
        if listingPrice != price { priceHistory.append(PricePoint(price: price, at: at)); priceHistory.sort { $0.at < $1.at } }
        listingPrice = priceHistory.last?.price ?? price
    }
    public mutating func markSold(_ price: Int, at: Date = Date()) {
        soldPrice = price; soldAt = at
        if listedAt == nil { listedAt = at }
    }
    public mutating func unmarkSold() { soldPrice = nil; soldAt = nil; paidAt = nil }
    public mutating func setStats(clicks: Int?, saves: Int?, messages: Int?, at: Date = Date()) {
        self.clicks = clicks; self.saves = saves; self.messages = messages; statsCheckedAt = at
    }

    /// Whole days from listedAt to soldAt, or listed-so-far (to `now`) if unsold. nil if never listed.
    public func daysToSell(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let l = listedAt else { return nil }
        let end = soldAt ?? now
        return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: l), to: calendar.startOfDay(for: end)).day ?? 0)
    }
    /// The price it was first listed at (start of the price history), else the current listing price.
    public var firstListingPrice: Int? { priceHistory.first?.price ?? listingPrice }
    /// soldPrice as a % of the first listing price.
    public var soldVsListedPct: Double? {
        guard let s = soldPrice, let l = firstListingPrice, l > 0 else { return nil }
        return Double(s) / Double(l) * 100
    }
    /// Actual profit = soldPrice − purchasePrice − partsCost − gasCost. nil until sold and purchase price known.
    public func actualProfit(partsCost: Double?, gasCost: Double?) -> Double? {
        guard let s = soldPrice, let p = purchasePrice else { return nil }
        return Double(s) - p - (partsCost ?? 0) - (gasCost ?? 0)
    }
}

/// History-wide averages over sold phones.
public struct SaleSummary: Equatable, Sendable {
    public var soldCount: Int
    public var listedCount: Int
    public var avgDaysToSell: Double?
    public var avgSoldVsListedPct: Double?
    public var avgActualProfit: Double?
    public var totalRevenue: Double
    public var totalPurchase: Double
    public var totalActualProfit: Double

    /// rows: (sale, partsCost, gasCost) per record.
    public init(_ rows: [(sale: SaleTracking, partsCost: Double?, gasCost: Double?)], now: Date = Date(), calendar: Calendar = .current) {
        func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let sold = rows.filter { $0.sale.isSold }
        soldCount = sold.count
        listedCount = rows.filter { $0.sale.listingPrice != nil && !$0.sale.isSold }.count
        avgDaysToSell = avg(sold.compactMap { $0.sale.daysToSell(now: now, calendar: calendar).map(Double.init) })
        avgSoldVsListedPct = avg(sold.compactMap { $0.sale.soldVsListedPct })
        let profits = sold.compactMap { $0.sale.actualProfit(partsCost: $0.partsCost, gasCost: $0.gasCost) }
        avgActualProfit = avg(profits)
        totalRevenue = sold.reduce(0) { $0 + Double($1.sale.soldPrice ?? 0) }
        totalPurchase = rows.reduce(0) { $0 + ($1.sale.purchasePrice ?? 0) }
        totalActualProfit = profits.reduce(0, +)
    }
    public var text: String {
        if soldCount == 0 { return "Sold 0 · listed \(listedCount)" }
        var b = ["Sold \(soldCount)", "listed \(listedCount)"]
        if let d = avgDaysToSell { b.append(String(format: "avg %.1f days to sell", d)) }
        if let p = avgSoldVsListedPct { b.append(String(format: "sold at %.0f%% of list", p)) }
        if let p = avgActualProfit { b.append(String(format: "avg profit $%.0f", p)) }
        return b.joined(separator: " · ")
    }
}

/// pgctl history sale subcommands (parsed here so they are unit-testable):
///   set-listing N PRICE · sold N PRICE · unsold N · bought N PRICE · paid N · stats N CLICKS SAVES MESSAGES
public enum SaleCommand: Equatable {
    case setListing(Int), sold(Int), unsold, bought(Double), paid, stats(Int, Int, Int)

    public static let names: Set<String> = ["set-listing", "sold", "unsold", "bought", "paid", "stats"]
    public struct ParseError: Error, Equatable { public let message: String }

    /// args: e.g. ["sold", "12", "480"] → (12, .sold(480))
    public static func parse(_ args: [String]) throws -> (id: Int, command: SaleCommand) {
        func num(_ i: Int) -> String? { args.count > i ? args[i].replacingOccurrences(of: "$", with: "") : nil }
        func int(_ i: Int, _ what: String) throws -> Int {
            guard let s = num(i), let v = Int(s), v >= 0 else { throw ParseError(message: "\(what) must be a whole number ≥ 0") }
            return v
        }
        guard let name = args.first, names.contains(name) else { throw ParseError(message: "unknown sale command") }
        let id = try int(1, "record id N")
        switch name {
        case "set-listing": return (id, .setListing(try int(2, "PRICE")))
        case "sold": return (id, .sold(try int(2, "PRICE")))
        case "unsold": return (id, .unsold)
        case "paid": return (id, .paid)
        case "bought":
            guard let s = num(2), let v = Double(s), v >= 0 else { throw ParseError(message: "PRICE must be a number ≥ 0") }
            return (id, .bought(v))
        default: return (id, .stats(try int(2, "CLICKS"), try int(3, "SAVES"), try int(4, "MESSAGES")))
        }
    }
    public func apply(to s: inout SaleTracking, at: Date = Date()) {
        switch self {
        case .setListing(let p): s.setListing(p, at: at)
        case .sold(let p): s.markSold(p, at: at)
        case .unsold: s.unmarkSold()
        case .bought(let p): s.purchasePrice = p; s.boughtAt = at
        case .paid: s.paidAt = at
        case .stats(let c, let v, let m): s.setStats(clicks: c, saves: v, messages: m, at: at)
        }
    }
}
