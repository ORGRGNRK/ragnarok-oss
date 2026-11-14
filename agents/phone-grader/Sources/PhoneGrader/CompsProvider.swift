import Foundation
import PhoneGraderCore

/// Fetches public Swappa pages (listings, price guide, recent-sales sampling) for a
/// model, politely: one request at a time, ≥2 s apart, identified User-Agent, and
/// every page cached on disk for 24 h. Marketplace/OfferUp are NEVER fetched — those
/// comps are typed/pasted in by you (LocalAskStore). Fetch failure = "no comps".
actor CompsProvider {
    static let shared = CompsProvider()
    static let cacheTTL: TimeInterval = 24 * 3600
    static let minGap: TimeInterval = 2.0
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) PhoneGrader/1.0 (personal resale pricing; low volume)"

    private var lastRequest = Date.distantPast

    static var cacheDir: URL {
        let u = Paths.support.appendingPathComponent("comps-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    struct Page { let html: String; let fetchedAt: Date; let fromCache: Bool }

    private func cacheFile(_ url: String) -> URL {
        let safe = url.replacingOccurrences(of: "https://swappa.com/", with: "")
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
        return CompsProvider.cacheDir.appendingPathComponent(safe + ".html")
    }

    func page(_ url: String, refresh: Bool) async throws -> Page {
        let f = cacheFile(url)
        if !refresh, let a = try? FileManager.default.attributesOfItem(atPath: f.path), let m = a[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < CompsProvider.cacheTTL, let h = try? String(contentsOf: f, encoding: .utf8) {
            return Page(html: h, fetchedAt: m, fromCache: true)
        }
        let wait = CompsProvider.minGap - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastRequest = Date()
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        req.setValue(CompsProvider.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        if url.contains("/xui/") { req.setValue("true", forHTTPHeaderField: "HX-Request") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let h = String(data: data, encoding: .utf8), !h.isEmpty else {
            throw NSError(domain: "Comps", code: code, userInfo: [NSLocalizedDescriptionKey: "Swappa returned HTTP \(code) for \(url)"])
        }
        try? h.write(to: f, atomically: true, encoding: .utf8)
        return Page(html: h, fetchedAt: Date(), fromCache: false)
    }

    /// Swappa comps + your saved local asks. Never throws: failures land in `errors`.
    func report(_ q: CompsQuery, refresh: Bool = false, includeSwappa: Bool = true) async -> CompsReport {
        var sets: [CompSet] = [], errors: [String] = []
        if includeSwappa {
            if Swappa.carrierParam(q.carrier) == nil {
                errors.append("Swappa: no comparable carrier filter for \(q.carrier) — skipped (no comps).")
            } else {
                for (kind, url) in [("listings", Swappa.listingsURL(q)), ("sales", Swappa.salesURL(q)), ("prices", Swappa.pricesURL(q))] {
                    do {
                        let p = try await page(url, refresh: refresh)
                        var s = Swappa.compSets(query: q, listingsHTML: kind == "listings" ? p.html : nil,
                                                salesHTML: kind == "sales" ? p.html : nil,
                                                pricesHTML: kind == "prices" ? p.html : nil, fetchedAt: p.fetchedAt)
                        if kind == "listings" {
                            s = s.map { var c = $0; c.note = (c.note ?? "") + " · first results page only"; return c }
                        }
                        if p.fromCache { s = s.map { var c = $0; c.note = (c.note ?? "") + " · cached"; return c } }
                        sets += s
                    } catch {
                        errors.append("Swappa \(kind): \(error.localizedDescription) — no comps from this source.")
                    }
                }
            }
        }
        sets += LocalAskStore.load(q.deviceKey).map { $0.compSet(location: "\(q.city) \(q.zip), \(q.radiusMiles) mi") }
        return CompsReport(query: q, sets: sets, errors: errors)
    }
}

/// Local asks you saw on Marketplace / OfferUp, typed or pasted in. Stored per model|storage|carrier.
enum LocalAskStore {
    static var file: URL { Paths.support.appendingPathComponent("local-asks.json") }
    static func all() -> [String: [LocalAskEntry]] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: [LocalAskEntry]].self, from: d)) ?? [:]
    }
    static func load(_ key: String) -> [LocalAskEntry] { all()[key] ?? [] }
    /// Replaces that source's entry for the device (one current list per source).
    static func save(_ key: String, _ e: LocalAskEntry) {
        var a = all(); var list = a[key] ?? []
        list.removeAll { $0.source == e.source }
        if !e.prices.isEmpty { list.append(e) }
        a[key] = list.isEmpty ? nil : list
        write(a)
    }
    static func clear(_ key: String) { var a = all(); a[key] = nil; write(a) }
    private static func write(_ a: [String: [LocalAskEntry]]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(a) { try? d.write(to: file, options: .atomic) }
    }
}

/// Settings for comps / range (UserDefaults; shared by app + pgctl).
enum CompsSettings {
    static var d: UserDefaults { .standard }
    static var zip: String { d.string(forKey: "compsZip") ?? LocalPlace.zip }
    static var city: String { d.string(forKey: "compsCity") ?? LocalPlace.city }
    static var radius: Int { d.object(forKey: "compsRadiusMiles") as? Int ?? 25 }
    static var margin: Double { d.object(forKey: "rangeMarginOverFloor") as? Double ?? 40 }
    static var discount: Double { d.object(forKey: "rangeDiscount") as? Double ?? 25 }
    static var range: RangeSettings { RangeSettings(marginOverFloor: margin, discount: discount) }

    /// Search links you can open yourself (we never fetch these).
    static func marketplaceURL(_ q: CompsQuery) -> URL? {
        let term = "\(q.model) \(q.storage > 0 ? "\(q.storage)GB" : "")".trimmingCharacters(in: .whitespaces)
        let enc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        return URL(string: "https://www.facebook.com/marketplace/search/?query=\(enc)")
    }
    static func offerUpURL(_ q: CompsQuery) -> URL? {
        let term = "\(q.model) \(q.storage > 0 ? "\(q.storage)GB" : "")".trimmingCharacters(in: .whitespaces)
        let enc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        return URL(string: "https://offerup.com/search?q=\(enc)")
    }
}

extension AppState {
    func compsQuery(zip: String? = nil, radius: Int? = nil) -> CompsQuery? {
        let (model, storage) = ListingPipeline.normalizeModelAndStorage(phoneModel, storageGb)
        guard !model.isEmpty else { return nil }
        return CompsQuery(model: model, storage: storage, carrier: carrier.rawValue, grade: effectiveGrade,
                          zip: zip ?? CompsSettings.zip, city: CompsSettings.city, radiusMiles: radius ?? CompsSettings.radius)
    }
    var batteryPercent: Int? { ListingPipeline.deriveVerifiedFacts(checklistEntries).battery }
}
