import XCTest
@testable import PhoneGraderCore

final class PartsLogTests: XCTestCase {
    func d(_ s: String) -> Date { AmazonBusinessCSV.date(s)! }

    func testTotalsAndMonths() {
        let p = [PartPurchase(date: d("2026-10-02"), item: "Back glass", cost: 28.99, recordId: 3),
                 PartPurchase(date: d("2026-10-15"), item: "Screen", cost: 61.5, recordId: 3),
                 PartPurchase(date: d("2026-09-20"), item: "Adhesive", supplier: "iFixit", cost: 9.99)]
        XCTAssertEqual(PartsLedger.total(p), 100.48)
        let m = PartsLedger.byMonth(p)
        XCTAssertEqual(m.map(\.month), ["2026-10", "2026-09"]); XCTAssertEqual(m[0].total, 90.49); XCTAssertEqual(m[0].count, 2)
        XCTAssertEqual(PartsLedger.actualCost(p, recordId: 3), 90.49)
        XCTAssertNil(PartsLedger.actualCost(p, recordId: 4)); XCTAssertNil(PartsLedger.actualCost(p, recordId: nil))
        XCTAssertEqual(p[0].supplier, "Amazon")
    }
    func testLinkedActualReplacesPlaceholder() {
        let k = DealCosts(parts: RepairParts(backGlass: .aftermarket), profitTarget: 40, actualPartsCost: 22.5)
        let r = DealRule.compute(floor: 540, floorQuotable: true, source: .atlasLadder, costs: k)
        XCTAssertEqual(r.partsCost, 22.5); XCTAssertEqual(r.maxBuy, 540 - 4 - 22.5 - 40)
        XCTAssertEqual(DealBreakdown(r).partsActualFromLog, 22.5)
        XCTAssertTrue(k.partsLabel.hasPrefix("actual from Parts log"))
        XCTAssertEqual(DealCosts(parts: RepairParts(backGlass: .aftermarket)).partsCost, 30)   // no link → placeholder
    }
    func testAmazonBusinessCSV() throws {
        let csv = "\u{FEFF}Order Date,Order ID,Title,Seller Name,Item Subtotal,Item Net Total\r\n" +
            "10/14/2026,113-1,\"iPhone 15 Pro Back Glass, Black\",Seller A,$24.99,$27.18\r\n" +
            "10/15/2026,113-2,\"Screen 6.1\"\" OLED\",Seller B,59.00,64.16\r\n" +
            "not a date,113-3,Thing,S,1,1\r\n" +
            "10/16/2026,113-4,,S,1,1\r\n"
        let p = try AmazonBusinessCSV.preview(csv)
        XCTAssertEqual(p.rows.count, 2); XCTAssertEqual(p.skipped.count, 2)
        XCTAssertEqual(p.columns.total, "Item Net Total")
        XCTAssertEqual(p.rows[0].item, "iPhone 15 Pro Back Glass, Black"); XCTAssertEqual(p.rows[0].cost, 27.18)
        XCTAssertEqual(p.rows[1].item, "Screen 6.1\" OLED"); XCTAssertEqual(p.rows[1].supplier, "Amazon")
        XCTAssertThrowsError(try AmazonBusinessCSV.preview("Foo,Bar\n1,2")) { e in
            XCTAssertEqual(e as? AmazonBusinessCSV.ParseError, .missingColumn("date (Order Date)"))
        }
        XCTAssertThrowsError(try AmazonBusinessCSV.preview(""))
    }
    func testCodableRoundTrip() throws {
        let p = PartPurchase(date: d("2026-10-02"), item: "x", cost: 1, recordId: 9)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode([PartPurchase].self, from: enc.encode([p])), [p])
    }
}
