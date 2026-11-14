import XCTest
@testable import PhoneGraderCore

final class SaleTrackingTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    func day(_ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
    func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    struct OldRecord: Codable { var id: Int; var askingPrice: Int?; var sale: SaleTracking? }
    func testOldRecordsLoadWithEmptySale() throws {
        let r = try dec().decode([OldRecord].self, from: Data(#"[{"id":1,"askingPrice":450},{"id":2}]"#.utf8))
        XCTAssertNil(r[0].sale); XCTAssertNil(r[1].sale)
        let partial = try dec().decode(SaleTracking.self, from: Data(#"{"listingPrice":400}"#.utf8))
        XCTAssertEqual(partial.listingPrice, 400); XCTAssertEqual(partial.priceHistory, []); XCTAssertNil(partial.soldAt)
        XCTAssertTrue(try dec().decode(SaleTracking.self, from: Data("{}".utf8)).isEmpty)
    }
    func testRoundTrip() throws {
        var s = SaleTracking(); s.setListing(500, at: day(1)); s.markSold(460, at: day(5)); s.purchasePrice = 300
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try dec().decode(SaleTracking.self, from: e.encode(s)), s)
    }
    func testListingHistoryAndListedAtDefault() {
        var s = SaleTracking()
        s.setListing(500, at: day(1)); s.setListing(500, at: day(2)); s.setListing(470, at: day(4))
        XCTAssertEqual(s.listedAt, day(1)); XCTAssertEqual(s.listingPrice, 470)
        XCTAssertEqual(s.priceHistory, [PricePoint(price: 500, at: day(1)), PricePoint(price: 470, at: day(4))])
        XCTAssertEqual(s.firstListingPrice, 500)
    }
    func testDaysToSell() {
        var s = SaleTracking()
        XCTAssertNil(s.daysToSell(now: day(10), calendar: cal))
        s.setListing(500, at: day(1, 22))
        XCTAssertEqual(s.daysToSell(now: day(8, 9), calendar: cal), 7)        // unsold: listed so far
        s.markSold(450, at: day(4, 8))
        XCTAssertEqual(s.daysToSell(now: day(20), calendar: cal), 3)
        var same = SaleTracking(); same.setListing(300, at: day(3, 9)); same.markSold(300, at: day(3, 18))
        XCTAssertEqual(same.daysToSell(calendar: cal), 0)
    }
    func testProfitMathAndPct() {
        var s = SaleTracking(); s.setListing(500, at: day(1)); s.markSold(450, at: day(3))
        XCTAssertNil(s.actualProfit(partsCost: 20, gasCost: 6))               // purchase unknown
        s.purchasePrice = 300
        XCTAssertEqual(s.actualProfit(partsCost: 20, gasCost: 6.5)!, 123.5, accuracy: 0.001)
        XCTAssertEqual(s.actualProfit(partsCost: nil, gasCost: nil)!, 150, accuracy: 0.001)
        XCTAssertEqual(s.soldVsListedPct!, 90, accuracy: 0.001)
        var unsold = SaleTracking(); unsold.purchasePrice = 300; unsold.setListing(500)
        XCTAssertNil(unsold.actualProfit(partsCost: 0, gasCost: 0)); XCTAssertNil(unsold.soldVsListedPct)
    }
    func testSummary() {
        var a = SaleTracking(); a.setListing(500, at: day(1)); a.markSold(450, at: day(3)); a.purchasePrice = 300
        var b = SaleTracking(); b.setListing(400, at: day(2)); b.markSold(400, at: day(6)); b.purchasePrice = 250
        var c = SaleTracking(); c.setListing(600, at: day(5))
        let m = SaleSummary([(a, 20, 10), (b, nil, 10), (c, nil, nil)], now: day(9), calendar: cal)
        XCTAssertEqual(m.soldCount, 2); XCTAssertEqual(m.listedCount, 1)
        XCTAssertEqual(m.avgDaysToSell!, 3, accuracy: 0.001)
        XCTAssertEqual(m.avgSoldVsListedPct!, 95, accuracy: 0.001)
        XCTAssertEqual(m.avgActualProfit!, (120 + 140) / 2, accuracy: 0.001)
        XCTAssertEqual(m.text, "Sold 2 · listed 1 · avg 3.0 days to sell · sold at 95% of list · avg profit $130")
        XCTAssertEqual(SaleSummary([]).text, "Sold 0 · listed 0")
    }
    func testCLIParseAndApply() throws {
        XCTAssertEqual(try SaleCommand.parse(["set-listing", "12", "$480"]).command, .setListing(480))
        XCTAssertEqual(try SaleCommand.parse(["set-listing", "12", "480"]).id, 12)
        XCTAssertEqual(try SaleCommand.parse(["sold", "3", "455"]).command, .sold(455))
        XCTAssertEqual(try SaleCommand.parse(["bought", "3", "310.50"]).command, .bought(310.5))
        XCTAssertEqual(try SaleCommand.parse(["stats", "3", "120", "9", "4"]).command, .stats(120, 9, 4))
        XCTAssertEqual(try SaleCommand.parse(["unsold", "3"]).command, .unsold)
        for bad in [["sold", "x", "400"], ["sold", "3"], ["stats", "3", "1", "2"], ["set-listing", "3", "-5"], ["nope", "1"]] {
            XCTAssertThrowsError(try SaleCommand.parse(bad), "\(bad)")
        }
        var s = SaleTracking()
        try SaleCommand.parse(["set-listing", "1", "500"]).command.apply(to: &s, at: day(1))
        try SaleCommand.parse(["set-listing", "1", "480"]).command.apply(to: &s, at: day(3))
        try SaleCommand.parse(["stats", "1", "50", "6", "3"]).command.apply(to: &s, at: day(4))
        try SaleCommand.parse(["bought", "1", "320"]).command.apply(to: &s, at: day(4))
        try SaleCommand.parse(["sold", "1", "470"]).command.apply(to: &s, at: day(6))
        XCTAssertEqual(s.listedAt, day(1)); XCTAssertEqual(s.listingPrice, 480); XCTAssertEqual(s.priceHistory.count, 2)
        XCTAssertEqual(s.clicks, 50); XCTAssertEqual(s.saves, 6); XCTAssertEqual(s.messages, 3); XCTAssertEqual(s.statsCheckedAt, day(4))
        XCTAssertEqual(s.soldAt, day(6)); XCTAssertEqual(s.daysToSell(calendar: cal), 5)
        XCTAssertEqual(s.actualProfit(partsCost: 15, gasCost: 5)!, 130, accuracy: 0.001)
        try SaleCommand.parse(["unsold", "1"]).command.apply(to: &s)
        XCTAssertFalse(s.isSold); XCTAssertNil(s.soldAt)
    }
    func testSaleNeverInBuyerFacts() {
        // PhoneFacts is built only from ReceiptInput, which has no sale/purchase/profit fields.
        let labels = Mirror(reflecting: ReceiptInput(recordId: 1, date: Date(), model: "iPhone 13", storageGb: 128, carrier: "Unlocked", imei: nil,
                                                    serial: nil, grade: nil, checklist: [], backend: nil, listingPrice: nil)).children.compactMap(\.label)
        for f in ["sale", "soldPrice", "purchasePrice", "floor", "maxBuy", "actualProfit"] { XCTAssertFalse(labels.contains(f), f) }
    }
}
