import Foundation
import XCTest
@testable import PhoneGraderCore

/// Comps parsing + suggested-range math. Saved Swappa pages (2026-10-15) — no live network in tests.
final class CompsTests: XCTestCase {
    func html(_ n: String) -> String { String(data: TestData.fixture(n), encoding: .utf8)! }
    let listings = "swappa-listings-iphone-16-pro-unlocked-128gb-2026-10-15.html"
    let sales = "swappa-sales-iphone-16-pro-unlocked-128gb-2026-10-15.html"
    let prices = "swappa-prices-iphone-16-pro-2026-10-15.html"
    let date = Date(timeIntervalSince1970: 1_791_000_000)
    func q(_ g: String = "A", carrier: String = "unlocked") -> CompsQuery {
        CompsQuery(model: "iPhone 16 Pro", storage: 128, carrier: carrier, grade: g)
    }

    // MARK: URLs / mapping
    func testSlugAndURLs() {
        XCTAssertEqual(Swappa.slug("iPhone 16 Pro"), "apple-iphone-16-pro")
        XCTAssertEqual(Swappa.slug("iPhone 15 Pro Max 256GB"), "apple-iphone-15-pro-max")
        XCTAssertEqual(Swappa.slug("iPhone SE (2022)"), "apple-iphone-se-2022")
        XCTAssertEqual(Swappa.listingsURL(q()), "https://swappa.com/listings/apple-iphone-16-pro?carrier=unlocked&storage=128gb")
        XCTAssertEqual(Swappa.salesURL(q(carrier: "verizon_locked")), "https://swappa.com/xui/product/apple-iphone-16-pro/sales?carrier=verizon&storage=128gb")
        XCTAssertEqual(Swappa.storageParam(1024), "1tb")
        XCTAssertNil(Swappa.carrierParam("other_locked"))
        XCTAssertEqual(Swappa.conditions(forGrade: "b"), ["Good"])
    }

    // MARK: parsing
    func testParseListings() {
        let l = Swappa.parseListings(html(listings))
        XCTAssertEqual(l.count, 50)
        XCTAssertEqual(l.first, Swappa.Listing(code: "LALA09814", price: 559, condition: "Good"))
        XCTAssertEqual(l.filter { $0.condition == "Mint" }.count, 18)
        XCTAssertEqual(Set(l.map(\.code)).count, 50)
    }
    func testParseSales() {
        let s = Swappa.parseSales(html(sales))
        XCTAssertEqual(s.count, 20)
        XCTAssertEqual(s[0], Swappa.Sale(date: "Oct 15", condition: "Mint", carrier: "Unlocked", storage: "128 GB", price: 706))
        XCTAssertEqual(s.map(\.price).reduce(0, +) / 20, 638.8, accuracy: 0.001)
    }
    func testParsePriceGuide() {
        let rows = Swappa.parsePriceGuide(html(prices))
        let r = rows.first { $0.carrier == "Unlocked" && $0.storage == "128 GB" }
        XCTAssertEqual(r?.listings, 116)
        XCTAssertEqual(r?.avg, 707)
    }
    func testParseGarbageGivesNothing() {
        XCTAssertTrue(Swappa.parseListings("<html>Access denied</html>").isEmpty)
        XCTAssertTrue(Swappa.parseSales("").isEmpty)
        XCTAssertTrue(Swappa.parsePriceGuide("<table><tr><td>x</td></tr></table>").isEmpty)
    }

    func testCompSetsGradeMatching() {
        let sets = Swappa.compSets(query: q("A"), listingsHTML: html(listings), salesHTML: html(sales), pricesHTML: html(prices), fetchedAt: date)
        XCTAssertEqual(sets.count, 3)
        let sold = sets.first { $0.kind == .sold }!
        XCTAssertEqual(sold.count, 9)                                   // Mint only
        XCTAssertEqual(sold.stats!.mean, 646, accuracy: 0.001)
        XCTAssertEqual(sold.stats!.median, 659)
        XCTAssertTrue(sold.note!.contains("Mint/New condition only"))
        XCTAssertEqual(sets.first { $0.kind == .ask }!.count, 18)
        let guide = sets.first { $0.kind == .avgList }!
        XCTAssertEqual(guide.prices, [707]); XCTAssertEqual(guide.count, 116)
        XCTAssertTrue(sets.allSatisfy { $0.fetchedAt == date })
    }
    func testCompSetsFallsBackToAllConditionsWhenFew() {
        // Grade C -> Fair; the sales fixture has no Fair 128GB unlocked sales.
        let sold = Swappa.compSets(query: q("C"), listingsHTML: nil, salesHTML: html(sales), pricesHTML: nil, fetchedAt: date)[0]
        XCTAssertEqual(sold.count, 20)
        XCTAssertTrue(sold.note!.contains("all conditions"))
    }
    func testCompSetsCarrierFilterExcludesOthers() {
        let sold = Swappa.compSets(query: q("A", carrier: "tmobile_locked"), listingsHTML: nil, salesHTML: html(sales), pricesHTML: nil, fetchedAt: date)[0]
        XCTAssertTrue(sold.prices.isEmpty)       // fixture is unlocked-only: never borrow other carriers' numbers
    }

    // MARK: manual local asks
    func testLocalAskParsing() {
        XCTAssertEqual(LocalAsks.parse("640, $699 / 650.50\n$1,050"), [640, 699, 650.5, 1050])
        XCTAssertEqual(LocalAsks.parse("iPhone 16 Pro 128GB $650 Springfield 62701 · 12 mi · 87% battery"), [650])
        XCTAssertEqual(LocalAsks.parse("asking 675 obo"), [675])
        XCTAssertEqual(LocalAsks.parse("nothing here"), [])
    }

    // MARK: stats + range math
    func testPercentiles() {
        let s = CompStats([699, 640, 675, 650])!
        XCTAssertEqual(s.p25, 647.5); XCTAssertEqual(s.median, 662.5); XCTAssertEqual(s.mean, 666)
        XCTAssertNil(CompStats([]))
        XCTAssertEqual(CompStats([600])!.p25, 600)
    }
    func report(local: [Double] = [], sold: [Double] = [], listed: [Double] = []) -> CompsReport {
        var sets: [CompSet] = []
        if !local.isEmpty { sets.append(LocalAskEntry(source: "Marketplace", prices: local, enteredAt: date).compSet(location: "Springfield, IL")) }
        if !sold.isEmpty { sets.append(CompSet(source: "Swappa sold", kind: .sold, prices: sold, fetchedAt: date)) }
        if !listed.isEmpty { sets.append(CompSet(source: "Swappa listings", kind: .ask, prices: listed, fetchedAt: date)) }
        return CompsReport(query: q(), sets: sets, errors: [])
    }
    func testRangeWithLocalAsks() {
        let r = PriceRange.compute(floor: 560, comps: report(local: [640, 650, 675, 699], sold: [647]), buyPrice: 500)
        XCTAssertEqual(r.low, 625)        // p25 647.5 − 25 = 622.5 → $5 round
        XCTAssertEqual(r.high, 665)       // median 662.5
        XCTAssertFalse(r.floorBound)
        XCTAssertEqual(r.profitLow, 125); XCTAssertEqual(r.profitHigh, 165)
        XCTAssertTrue(r.anchorLow.contains("local ask p25"))
    }
    func testRangeSoldOnly() {
        let r = PriceRange.compute(floor: 560, comps: report(sold: [600, 640, 660, 700]), buyPrice: nil)
        XCTAssertEqual(r.low, 625)        // avg 650 − 25
        XCTAssertEqual(r.high, 650)       // median 650
        XCTAssertNil(r.profitLow)
        XCTAssertTrue(r.explanation.contains { $0.contains("No local Marketplace/OfferUp asks") })
    }
    func testRangeFloorGuard() {
        let r = PriceRange.compute(floor: 600, comps: report(local: [610, 620, 630]), buyPrice: nil,
                                   settings: RangeSettings(marginOverFloor: 40, discount: 25))
        XCTAssertEqual(r.low, 640)        // anchor 615 − 25 = 590 < 640
        XCTAssertTrue(r.floorBound)
        XCTAssertEqual(r.high, 640)       // median 620 < low → clamped
        XCTAssertTrue(r.explanation.contains { $0.contains("clamped") })
    }
    func testRangeNoComps() {
        let r = PriceRange.compute(floor: 560, comps: CompsReport(query: q(), sets: [], errors: ["offline"]), buyPrice: 520)
        XCTAssertEqual(r.low, 600); XCTAssertNil(r.high); XCTAssertEqual(r.profitLow, 80)
        let none = PriceRange.compute(floor: nil, comps: nil, buyPrice: nil)
        XCTAssertNil(none.low); XCTAssertNil(none.high)
    }
    func testRangeConfigurable() {
        let r = PriceRange.compute(floor: 500, comps: report(sold: [700]), buyPrice: nil,
                                   settings: RangeSettings(marginOverFloor: 0, discount: 50, roundTo: 1))
        XCTAssertEqual(r.low, 650); XCTAssertEqual(r.high, 700)
    }

    // MARK: listing template
    func testListingTemplate() {
        let t = ListingTemplate.make(model: "iPhone 16 Pro", storage: 128, grade: "A", gradeNotes: "Tiny scuff on frame",
                                     battery: 91, carrier: "unlocked", price: 640, location: "Springfield, IL")
        XCTAssertEqual(t.title, "iPhone 16 Pro 128GB Unlocked – 91% Battery – $640")
        XCTAssertTrue(t.body.contains("Battery health: 91%"))
        XCTAssertTrue(t.body.contains("Notes: Tiny scuff on frame"))
        XCTAssertTrue(t.body.contains("local pickup in Springfield, IL"))
        let u = ListingTemplate.make(model: "iPhone 13", storage: 0, grade: "B", gradeNotes: nil, battery: nil,
                                     carrier: "unknown", price: nil, location: "Springfield, IL")
        XCTAssertEqual(u.title, "iPhone 13")
        XCTAssertFalse(u.body.contains("Battery")); XCTAssertFalse(u.body.contains("Carrier:")); XCTAssertFalse(u.body.contains("Price:"))
        XCTAssertFalse(t.body.lowercased().contains("atlas"))
    }
}
