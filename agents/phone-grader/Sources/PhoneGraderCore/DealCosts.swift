import Foundation

/// Inputs to the one max-buy formula:
///   max buy = Atlas floor − gas − repair parts − profit target
///   gas     = round-trip miles ÷ MPG × price per gallon
/// Defaults live here; the app stores the user's values in UserDefaults (see DealSettings in the app).

/// Money for display: whole dollars stay whole, otherwise two decimals.
public func usd(_ v: Double) -> String {
    let r = (v * 100).rounded() / 100
    if r == r.rounded() { return String(Int(r)) }
    return String(format: "%.2f", r)
}

/// Round to cents (all stored breakdown numbers are cent-rounded so they add up exactly).
public func cents(_ v: Double) -> Double { (v * 100).rounded() / 100 }

public enum BackGlassPart: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, aftermarket, apple
    public var id: String { rawValue }
    public var label: String {
        switch self { case .none: return "None"; case .aftermarket: return "Aftermarket"; case .apple: return "Apple" }
    }
}

public enum ScreenPart: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, oem, aftermarket
    public var id: String { rawValue }
    public var label: String {
        switch self { case .none: return "None"; case .oem: return "OEM"; case .aftermarket: return "Aftermarket" }
    }
}

/// Per-part costs. Every default is a PLACEHOLDER — enter your real cost in Settings.
public struct PartCosts: Codable, Equatable, Sendable {
    public var backGlassAftermarket: Double
    public var backGlassApple: Double
    public var screenOEM: Double
    public var screenAftermarket: Double
    public init(backGlassAftermarket: Double = PartCosts.placeholder.backGlassAftermarket,
                backGlassApple: Double = PartCosts.placeholder.backGlassApple,
                screenOEM: Double = PartCosts.placeholder.screenOEM,
                screenAftermarket: Double = PartCosts.placeholder.screenAftermarket) {
        self.backGlassAftermarket = backGlassAftermarket; self.backGlassApple = backGlassApple
        self.screenOEM = screenOEM; self.screenAftermarket = screenAftermarket
    }
    private init(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
        backGlassAftermarket = a; backGlassApple = b; screenOEM = c; screenAftermarket = d
    }
    /// Placeholders (not researched prices). OEM screen $0 = "enter your cost".
    public static let placeholder = PartCosts(30, 160, 0, 45)
}

public struct RepairParts: Codable, Equatable, Sendable {
    public var backGlass: BackGlassPart
    public var screen: ScreenPart
    public init(backGlass: BackGlassPart = .none, screen: ScreenPart = .none) {
        self.backGlass = backGlass; self.screen = screen
    }
    /// Default for a new deal: aftermarket back glass only when the checklist says the rear glass failed.
    public static func defaults(rearGlassFailed: Bool) -> RepairParts {
        RepairParts(backGlass: rearGlassFailed ? .aftermarket : .none, screen: .none)
    }
    public func backGlassCost(_ c: PartCosts) -> Double {
        switch backGlass { case .none: return 0; case .aftermarket: return c.backGlassAftermarket; case .apple: return c.backGlassApple }
    }
    public func screenCost(_ c: PartCosts) -> Double {
        switch screen { case .none: return 0; case .oem: return c.screenOEM; case .aftermarket: return c.screenAftermarket }
    }
    public func cost(_ c: PartCosts) -> Double { cents(backGlassCost(c) + screenCost(c)) }
    public var isEmpty: Bool { backGlass == .none && screen == .none }
    /// Any part that isn't Apple-original (Atlas may deduct for these).
    public var usesNonApplePart: Bool { backGlass == .aftermarket || screen == .aftermarket || screen == .oem }
    public static let aftermarketBackGlassDisclosure = "Back glass replaced with aftermarket part"
    /// Lines a buyer must see (Listing text + QR receipt).
    public var disclosures: [String] {
        backGlass == .aftermarket ? [RepairParts.aftermarketBackGlassDisclosure] : []
    }
    /// Non-price summary, e.g. "back glass: aftermarket; screen: OEM".
    public var summary: String {
        var p: [String] = []
        if backGlass != .none { p.append("back glass: \(backGlass.label)") }
        if screen != .none { p.append("screen: \(screen.label)") }
        return p.isEmpty ? "none" : p.joined(separator: "; ")
    }
    public static let atlasNote = "Atlas may deduct for non-Apple parts — check the Atlas sheet before counting on the full floor."
}

public struct GasInputs: Codable, Equatable, Sendable {
    public var roundTripMiles: Double
    public var mpg: Double
    public var pricePerGallon: Double
    /// e.g. "EIA weekly California regular", "Manual (Settings)", "Manual override".
    public var priceSource: String
    /// e.g. "2026-10-12" (EIA week) — nil for manual prices.
    public var priceDate: String?
    public init(roundTripMiles: Double = DealDefaults.roundTripMiles, mpg: Double = DealDefaults.mpg,
                pricePerGallon: Double = DealDefaults.manualGasPrice, priceSource: String = GasPriceSource.placeholderLabel,
                priceDate: String? = nil) {
        self.roundTripMiles = roundTripMiles; self.mpg = mpg; self.pricePerGallon = pricePerGallon
        self.priceSource = priceSource; self.priceDate = priceDate
    }
    /// miles ÷ MPG × $/gal, cent-rounded. Bad inputs (≤0 MPG, negative miles) cost 0 rather than blowing up.
    public var cost: Double {
        guard mpg > 0, roundTripMiles > 0, pricePerGallon > 0 else { return 0 }
        return cents(roundTripMiles / mpg * pricePerGallon)
    }
    public var explanation: String {
        "\(usd(roundTripMiles)) mi ÷ \(usd(mpg)) MPG × $\(String(format: "%.3f", pricePerGallon))/gal"
    }
}

public enum DealDefaults {
    public static let mpg: Double = 24
    public static let roundTripMiles: Double = 20
    /// Placeholder used only when the EIA fetch fails and nothing is cached.
    public static let manualGasPrice: Double = 4.80
    public static let profitTarget: Double = 40
}

/// Everything subtracted from the floor, as one value the app builds from Settings + the Price tab.
public struct DealCosts: Codable, Equatable, Sendable {
    public var gas: GasInputs
    public var parts: RepairParts
    public var partCosts: PartCosts
    public var profitTarget: Double
    /// Real cost from the Parts log for parts linked to this phone; replaces the placeholder part costs.
    public var actualPartsCost: Double?
    public init(gas: GasInputs = GasInputs(), parts: RepairParts = RepairParts(), partCosts: PartCosts = .placeholder,
                profitTarget: Double = DealDefaults.profitTarget, actualPartsCost: Double? = nil) {
        self.gas = gas; self.parts = parts; self.partCosts = partCosts; self.profitTarget = max(0, profitTarget)
        self.actualPartsCost = actualPartsCost
    }
    public var gasCost: Double { gas.cost }
    public var partsCost: Double { actualPartsCost.map(cents) ?? parts.cost(partCosts) }
    public var partsLabel: String {
        actualPartsCost != nil ? "actual from Parts log" + (parts.isEmpty ? "" : " (\(parts.summary))") : parts.summary
    }
    /// gas + parts — what it costs you to get the phone to Atlas (excludes profit).
    public var costsBeforeProfit: Double { cents(gasCost + partsCost) }
}

/// Where the gas price came from, resolved in a fixed order:
/// per-deal override → "always manual" setting → EIA (fresh or cached) → manual Settings price.
public struct GasPriceSource: Equatable, Sendable {
    public var price: Double
    public var label: String
    public var date: String?
    public static let eiaLabel = "EIA weekly California regular"
    public static let placeholderLabel = "Manual price from Settings (placeholder $4.80 — set yours)"
    public static let manualLabel = "Manual price from Settings"
    public static let overrideLabel = "Manual override (this deal)"

    public static func resolve(override: Double?, alwaysManual: Bool, manualPrice: Double, manualIsPlaceholder: Bool,
                               eiaPrice: Double?, eiaDate: String?) -> GasPriceSource {
        if let o = override, o > 0 { return GasPriceSource(price: o, label: overrideLabel, date: nil) }
        let manual = GasPriceSource(price: manualPrice > 0 ? manualPrice : DealDefaults.manualGasPrice,
                                    label: manualIsPlaceholder ? placeholderLabel : manualLabel, date: nil)
        if alwaysManual { return manual }
        if let p = eiaPrice, p > 0 { return GasPriceSource(price: p, label: eiaLabel, date: eiaDate) }
        return manual
    }
}

/// Keyless EIA source: the public weekly history page for series EMM_EPMR_PTE_SCA_DPG
/// (California regular gasoline retail, $/gal). The EIA JSON API (api.eia.gov/v2) needs a key.
public enum EIAGasPrice {
    public static let seriesId = "EMM_EPMR_PTE_SCA_DPG"
    public static let pageURL = URL(string: "https://www.eia.gov/dnav/pet/hist/LeafHandler.ashx?n=PET&s=EMM_EPMR_PTE_SCA_DPG&f=W")!

    /// Latest (weekOf "yyyy-MM-dd", $/gal) from the history table, or nil if the page changed shape.
    /// Rows: <td class='B6'>  2026-Oct</td> then pairs <td class='B5'>10/05 </td><td class='B3'>6.227 </td>.
    public static func parse(html: String) -> (weekOf: String, price: Double)? {
        let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
        guard let cell = try? NSRegularExpression(pattern: #"<td class=['"](B[356])['"][^>]*>([^<]*)</td>"#) else { return nil }
        let ns = html as NSString
        var year: Int?
        var rowMonth: Int?
        var pendingDate: (Int, Int)?
        var last: (String, Double)?
        for m in cell.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cls = ns.substring(with: m.range(at: 1))
            let text = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch cls {
            case "B6":
                let parts = text.split(separator: "-")
                year = parts.first.flatMap { Int($0) }
                rowMonth = parts.count > 1 ? months[String(parts[1])] : nil
                pendingDate = nil
            case "B5":
                let md = text.split(separator: "/").compactMap { Int($0) }
                pendingDate = md.count == 2 ? (md[0], md[1]) : nil
            default:  // B3 value
                if let (mo, d) = pendingDate, let y = year, let v = Double(text), v > 0, v < 20 {
                    let yy = (rowMonth == 1 && mo == 12) ? y - 1 : y   // a week that started in late Dec
                    last = (String(format: "%04d-%02d-%02d", yy, mo, d), v)
                }
                pendingDate = nil
            }
        }
        return last.map { (weekOf: $0.0, price: $0.1) }
    }
}
