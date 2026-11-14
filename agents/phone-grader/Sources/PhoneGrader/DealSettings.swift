import Foundation
import PhoneGraderCore

/// Max-buy inputs live in the app's ONE settings store (UserDefaults.standard — the same store
/// every other setting, @AppStorage and `pgctl config` use). Keys + defaults are declared here once;
/// views bind with `@AppStorage(DealSettings.Key.x)` and the CLI/AppState read through these helpers.
enum DealSettings {
    enum Key {
        static let profitTarget = "profitFloor"          // kept from 52c53a4 so a saved value carries over
        static let mpg = "dealMPG"
        static let defaultMiles = "dealDefaultMiles"
        static let manualGasPrice = "gasPriceManual"
        static let alwaysManualGas = "gasPriceAlwaysManual"
        static let eiaPrice = "gasEIAPrice"
        static let eiaWeek = "gasEIAWeek"
        static let eiaFetchedAt = "gasEIAFetchedAt"
        static let eiaLastError = "gasEIALastError"
        static let backGlassAftermarket = "partBackGlassAftermarket"
        static let backGlassApple = "partBackGlassApple"
        static let screenOEM = "partScreenOEM"
        static let screenAftermarket = "partScreenAftermarket"
    }
    static var d: UserDefaults { .standard }
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }

    static var profitTarget: Double { double(Key.profitTarget, DealDefaults.profitTarget) }
    static var mpg: Double { double(Key.mpg, DealDefaults.mpg) }
    static var defaultMiles: Double { double(Key.defaultMiles, DealDefaults.roundTripMiles) }
    static var manualGasPrice: Double { double(Key.manualGasPrice, DealDefaults.manualGasPrice) }
    static var manualGasIsPlaceholder: Bool { d.object(forKey: Key.manualGasPrice) == nil }
    static var alwaysManualGas: Bool { d.bool(forKey: Key.alwaysManualGas) }
    static var eiaPrice: Double? { d.object(forKey: Key.eiaPrice) as? Double }
    static var eiaWeek: String? { d.string(forKey: Key.eiaWeek) }
    static var eiaFetchedAt: Date? { (d.object(forKey: Key.eiaFetchedAt) as? Double).map { Date(timeIntervalSince1970: $0) } }
    static var eiaLastError: String? { d.string(forKey: Key.eiaLastError) }
    static var partCosts: PartCosts {
        let p = PartCosts.placeholder
        return PartCosts(backGlassAftermarket: double(Key.backGlassAftermarket, p.backGlassAftermarket),
                         backGlassApple: double(Key.backGlassApple, p.backGlassApple),
                         screenOEM: double(Key.screenOEM, p.screenOEM),
                         screenAftermarket: double(Key.screenAftermarket, p.screenAftermarket))
    }
    static func isPlaceholder(_ k: String) -> Bool { d.object(forKey: k) == nil }

    static func gasSource(override: Double?) -> GasPriceSource {
        GasPriceSource.resolve(override: override, alwaysManual: alwaysManualGas, manualPrice: manualGasPrice,
                               manualIsPlaceholder: manualGasIsPlaceholder, eiaPrice: eiaPrice, eiaDate: eiaWeek)
    }

    static func costs(miles: Double?, mpgOverride: Double? = nil, gasOverride: Double?, parts: RepairParts,
                      profitOverride: Double? = nil, actualParts: Double? = nil) -> DealCosts {
        let src = gasSource(override: gasOverride)
        return DealCosts(gas: GasInputs(roundTripMiles: miles ?? defaultMiles, mpg: mpgOverride ?? mpg,
                                        pricePerGallon: src.price, priceSource: src.label, priceDate: src.date),
                         parts: parts, partCosts: partCosts, profitTarget: profitOverride ?? profitTarget,
                         actualPartsCost: actualParts)
    }
}

/// Fetches the EIA weekly California regular price from EIA's public (keyless) history page and caches
/// it in the settings store. Failures leave the last good value (or the manual fallback) in place.
enum GasPriceService {
    static let staleAfter: TimeInterval = 12 * 3600

    static var isStale: Bool { DealSettings.eiaFetchedAt.map { Date().timeIntervalSince($0) > staleAfter } ?? true }

    @discardableResult
    static func refresh(force: Bool = false) async -> String {
        if !force && !isStale, let p = DealSettings.eiaPrice {
            return "EIA $\(String(format: "%.3f", p))/gal, week of \(DealSettings.eiaWeek ?? "?") (cached)"
        }
        var req = URLRequest(url: EIAGasPrice.pageURL); req.timeoutInterval = 12
        req.setValue("PhoneGrader/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let d = DealSettings.d
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "EIA", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                              userInfo: [NSLocalizedDescriptionKey: "EIA returned HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let r = EIAGasPrice.parse(html: html) else {
                throw NSError(domain: "EIA", code: 1, userInfo: [NSLocalizedDescriptionKey: "EIA page format not recognised"])
            }
            d.set(r.price, forKey: DealSettings.Key.eiaPrice)
            d.set(r.weekOf, forKey: DealSettings.Key.eiaWeek)
            d.set(Date().timeIntervalSince1970, forKey: DealSettings.Key.eiaFetchedAt)
            d.removeObject(forKey: DealSettings.Key.eiaLastError)
            return "EIA $\(String(format: "%.3f", r.price))/gal, week of \(r.weekOf)"
        } catch {
            d.set(error.localizedDescription, forKey: DealSettings.Key.eiaLastError)
            return "EIA fetch failed (\(error.localizedDescription)) — using \(DealSettings.eiaPrice != nil ? "last EIA value" : "manual price from Settings")"
        }
    }
}

/// Parts log: lives in the same settings store (UserDefaults.standard, key "partsLog", JSON) so the app
/// and pgctl see the same purchases and the max-buy math can read linked actual costs.
enum PartsLogStore {
    static let key = "partsLog"
    /// With PHONEGRADER_DATA_DIR set (tests), the parts log is a file there instead of UserDefaults.
    static var file: URL? { Paths.dataOverride == nil ? nil : Paths.support.appendingPathComponent("parts-log.json") }
    static var all: [PartPurchase] {
        guard let d = file.map({ try? Data(contentsOf: $0) }) ?? UserDefaults.standard.data(forKey: key) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([PartPurchase].self, from: d)) ?? []
    }
    static func save(_ p: [PartPurchase]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(p.sorted { $0.date > $1.date }) { if let f = file { try? d.write(to: f, options: .atomic) } else { UserDefaults.standard.set(d, forKey: key) } }
    }
    static func add(_ p: [PartPurchase]) { save(all + p) }
    static func update(_ p: PartPurchase) { var a = all; if let i = a.firstIndex(where: { $0.id == p.id }) { a[i] = p }; save(a) }
    static func delete(_ id: UUID) { save(all.filter { $0.id != id }) }
}
