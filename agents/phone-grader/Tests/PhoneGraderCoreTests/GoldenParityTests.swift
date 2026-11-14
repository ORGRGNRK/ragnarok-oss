import XCTest
@testable import PhoneGraderCore

/// Byte-for-byte parity with the ORIGINAL Python servers. Fixtures were produced
/// by running resale-op-mcp's server.py functions (interpreter off) over a sweep
/// of inputs on 2026-10-14 (expired) and 2026-09-01 (fresh).
final class GoldenParityTests: XCTestCase {
    func testPriceParityWithPython() throws {
        // The public copy ships sample prices and leaves this real-price snapshot out.
        guard FileManager.default.fileExists(atPath: TestData.testsDir.appendingPathComponent("Fixtures/price-golden.json").path)
        else { throw XCTSkip("price-golden.json not present (public copy with sample prices)") }
        let cases = try JSONSerialization.jsonObject(with: TestData.fixture("price-golden.json")) as! [[String: Any]]
        var mismatches: [String] = []
        for c in cases {
            let a = c["args"] as! [String: Any], o = c["out"] as! [String: Any]
            let r = TestData.engine.getAtlasFloor(
                model: a["model"] as! String, storage: a["storage"] as! Int, grade: a["grade"] as! String,
                lock: a["lock"] as! String, battery: a["battery"] as? String, imeiClean: a["imei_clean"] as? Bool,
                aftermarketScreen: a["aftermarket_screen"] as! Bool, crackedBack: a["cracked_back"] as! Bool,
                today: c["today"] as! String, interpreter: nil)
            let pyFloor = (o["floor"] as? NSNumber)?.doubleValue
            let ok = r.status == (o["status"] as? String ?? "") && r.floor == pyFloor &&
                r.floorQuotable == (o["floor_quotable"] as! Bool) &&
                r.warnings == (o["warnings"] as! [String]) &&
                r.blockingDisclosures == (o["blocking_disclosures"] as! [String]) &&
                r.note == (o["note"] as? String) && r.modelResolved == (o["model_resolved"] as? String) &&
                r.modelMatch == (o["model_match"] as? String) && r.matchedRow == (o["matched_row"] as? String) &&
                r.quoteSource == (o["quote_source"] as? String) && r.quoteDate == (o["quote_date"] as? String)
            if !ok { mismatches.append("\(c["today"]!) \(a)") }
        }
        XCTAssertEqual(mismatches.count, 0, "first: \(mismatches.prefix(3))")
        XCTAssertGreaterThan(cases.count, 4000)
    }

    func testCopyParityWithPython() throws {
        let cases = try JSONSerialization.jsonObject(with: TestData.fixture("copy-golden.json")) as! [[String: Any]]
        var mismatches: [String] = []
        for c in cases {
            let a = c["args"] as! [String: Any], o = c["out"] as! [String: Any]
            let r = ListingCopyGenerator.generate(
                model: a["model"] as! String, storage: a["storage"] as! Int, grade: a["grade"] as! String,
                battery: a["battery"] as? String, icloudClear: a["icloud_clear"] as? Bool,
                imeiClean: a["imei_clean"] as? Bool, carrierLock: a["carrier_lock"] as? String,
                defects: a["defects"] as! [String], concerns: a["concerns"] as! [String],
                priceFBM: a["price"] as? Int, location: "Springfield, IL")
            let ok = r.title == o["title"] as! String && r.description == o["description"] as! String &&
                r.keywords == o["keywords"] as! [String] && r.grade == o["grade"] as! String &&
                r.suggestedPrice == o["suggested_price"] as? Int && r.omittedClaims == o["omitted_claims"] as! [String] &&
                r.claimsVerified == o["claims_verified"] as! Bool && r.carrierVerified == o["carrier_verified"] as! Bool &&
                r.blockingDisclosures == o["blocking_disclosures"] as! [String]
            if !ok { mismatches.append("\(a)") }
        }
        XCTAssertEqual(mismatches.count, 0, "first: \(mismatches.prefix(3))")
    }
}
