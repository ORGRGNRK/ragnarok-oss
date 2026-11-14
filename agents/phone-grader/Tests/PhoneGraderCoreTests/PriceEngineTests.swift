import XCTest
@testable import PhoneGraderCore

/// Ported from resale-op-mcp/price-mcp/test_price.py. Assertions that pin
/// prices from an OLDER sheet (the 12 known failures that also fail in Python
/// today — Reminder rec1inMCINj3vEaW3) are re-expressed against the bundled
/// 2026-09-04 ladder, and noted inline.
final class PriceEngineTests: XCTestCase {
    let e = TestData.engine
    let today = TestData.expiredDay

    func testLadderStatusReportsDaysPastDelivery() {
        let s = e.ladderStatus(today: today)
        XCTAssertEqual(s.daysPastDelivery, 40)
        XCTAssertFalse(s.quotable)
        XCTAssertTrue(s.verdict.hasPrefix("EXPIRED 40d"))
        XCTAssertTrue(e.ladderStatus(today: "2026-09-04").quotable)
    }

    func testOnLadder14ProMaxGradeC() {
        let r = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "C", lock: "unlocked", today: today)
        XCTAssertEqual(r.status, "on_ladder")
        // Python suite pins $280/$380/$80 from an older tab; bundled 2026-09-04 row:
        let row = TestData.ladder.rows.first { $0.key == "iphone 14 pro max|128|unlocked" }!
        XCTAssertEqual(r.floor, row.ladder[3])
        XCTAssertEqual(r.ladderFull?.first(where: { $0.column == "A" })?.value, row.ladder[1])
        XCTAssertEqual(r.ladderFull?.first(where: { $0.column == "DOA" })?.value, row.ladder[5])
    }

    func testMacBookHasNoFloor() {
        let r = e.getAtlasFloor(model: "MacBook Air M2 2022", storage: 256, grade: "B", today: today)
        XCTAssertEqual(r.status, "off_ladder")
        XCTAssertNil(r.floor)
        XCTAssertTrue(r.note!.contains("NO ATLAS FLOOR"))
    }

    func testInFamilyMissNeverInventsNumber() {
        // 1TB row for the 16 Pro Max now exists on the sheet; use a storage that doesn't.
        let r = e.getAtlasFloor(model: "iPhone 16 Pro Max", storage: 64, grade: "B", today: today)
        XCTAssertEqual(r.status, "in_family")
        XCTAssertNil(r.floor)
        XCTAssertTrue(r.note!.contains("live sheet"))
    }

    func testGradeFMapsToDOANeverD() {
        let f = e.getAtlasFloor(model: "iPhone 13 Pro", storage: 128, grade: "F", lock: "unlocked", today: today)
        let d = e.getAtlasFloor(model: "iPhone 13 Pro", storage: 128, grade: "D", lock: "unlocked", today: today)
        let row = TestData.ladder.rows.first { $0.key == "iphone 13 pro|128|unlocked" }!
        XCTAssertEqual(f.floor, row.ladder[5])
        XCTAssertEqual(d.floor, row.ladder[4])
        XCTAssertNotEqual(f.floor, d.floor)
        XCTAssertTrue(f.blockingDisclosures.contains { $0.contains("grade F") })
    }

    func testBatteryUnder80WarnsButDoesNotChangeFloor() {
        let base = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "C", today: today)
        let r = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "C", battery: "78", today: today)
        XCTAssertTrue(r.warnings.contains { $0.contains("EXTRA DEDUCTION") })
        XCTAssertEqual(r.floor, base.floor)
    }

    func testBadIMEIRelockLiability() {
        let r = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "B", imeiClean: false, today: today)
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("IMEI not clean") })
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("SELLER is liable") || $0.contains("Relock") })
    }

    func testExpiredAnchorNeverQuotable() {
        let r = e.getAtlasFloor(model: "iPhone 13 Pro", storage: 128, grade: "B", lock: "unlocked", today: today)
        XCTAssertFalse(r.floorQuotable)
        XCTAssertTrue(r.warnings.contains { $0.contains("ANCHOR EXPIRED") })
        XCTAssertTrue(r.note!.contains("Reference only"))
        let fresh = e.getAtlasFloor(model: "iPhone 13 Pro", storage: 128, grade: "B", lock: "unlocked", today: TestData.freshDay)
        XCTAssertTrue(fresh.floorQuotable)
    }

    func testNoRetailNumberEver() {
        let r = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "B", today: today)
        XCTAssertTrue(r.retailGuidance.contains("the owner's call"))
    }

    func testBadGradeRejected() {
        let r = e.getAtlasFloor(model: "iPhone 13 Pro", storage: 128, grade: "Z", today: today)
        XCTAssertEqual(r.status, "bad_grade")
        XCTAssertNil(r.floor)
    }

    func testRealQuoteBeatsLadderOnlyOnDamagedUnit() {
        let dmg = e.getAtlasFloor(model: "iPhone 12 Pro Max", storage: 128, grade: "B",
                                  aftermarketScreen: true, crackedBack: true, today: today)
        XCTAssertEqual(dmg.floor, 40)
        XCTAssertEqual(dmg.status, "actual_quote")
        XCTAssertEqual(dmg.quoteSource, "Atlas Mobile Co")
        XCTAssertTrue(dmg.floorQuotable, "a real quote is quotable even when the ladder is stale")
        let clean = e.getAtlasFloor(model: "iPhone 12 Pro Max", storage: 256, grade: "B", lock: "carrier_locked", today: today)
        XCTAssertNotEqual(clean.floor, 40)
        XCTAssertNotEqual(clean.status, "actual_quote")
        for r in [dmg, clean] { XCTAssertTrue(r.warnings.contains { $0.contains("unlocked row") }) }
    }

    func testAftermarketScreenCapsGradeBClaim() {
        let r = e.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "B", aftermarketScreen: true, today: today)
        XCTAssertTrue(r.warnings.contains { $0.contains("caps this at D") })
    }

    func testUserBuyerQuoteBeatsLadder() {
        let q = BuyerQuote(match: "iphone 14 pro max", storage: 128, lock: nil, buyer: "Brett", quoted: 333,
                           dateApprox: "2026-10-14", dateExactRecorded: true)
        let eng = PriceEngine(ladder: TestData.ladder, quotes: TestData.quotes.merged(withUserQuotes: [q]))
        let r = eng.getAtlasFloor(model: "14 pro max", storage: 128, grade: "C", today: today)
        XCTAssertEqual(r.status, "actual_quote")
        XCTAssertEqual(r.floor, 333)
        XCTAssertEqual(r.quoteDate, "2026-10-14")
        XCTAssertTrue(r.floorQuotable)
    }

    func testRowOrderPreservedFromFile() {
        XCTAssertEqual(TestData.ladder.rows.first?.key, "iphone 17 pro max|256|unlocked")
        XCTAssertEqual(TestData.ladder.rows.count, 278)
    }

    func testCorruptImportRejected() {
        XCTAssertThrowsError(try AtlasLadder(data: Data(#"{"rows":{}}"#.utf8)))
        XCTAssertThrowsError(try AtlasLadder(data: Data("not json".utf8)))
    }
}
