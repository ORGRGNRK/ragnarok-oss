import XCTest
@testable import PhoneGraderCore

/// Ported from copy-mcp/test_copy.py — the NEGATIVE assertions matter most.
final class ListingCopyTests: XCTestCase {
    typealias G = ListingCopyGenerator

    func testNothingVerifiedClaimsNothing() {
        let r = G.generate(model: "iPhone 12 Pro Max", storage: 128, grade: "B")
        let blob = (r.title + r.description).lowercased()
        XCTAssertFalse(blob.contains("icloud clear") || blob.contains("no icloud lock"))
        XCTAssertFalse(blob.contains("imei checked"))
        XCTAssertFalse(blob.contains("% battery") || blob.contains("battery health"))
        XCTAssertFalse(blob.contains("face id"))
        XCTAssertFalse(r.claimsVerified)
        XCTAssertGreaterThanOrEqual(r.omittedClaims.count, 3)
    }

    func testFullyVerified() {
        let r = G.generate(model: "iPhone 12 Pro Max", storage: 128, grade: "B", battery: "87%",
                           icloudClear: true, imeiClean: true, defects: ["light scratch rear"], priceFBM: 285)
        XCTAssertTrue(r.title.contains("iCloud Clear"))
        XCTAssertTrue(r.description.contains("IMEI checked against blacklist"))
        XCTAssertTrue(r.title.contains("87% Battery"))
        XCTAssertTrue(r.description.contains("light scratch rear"))
        XCTAssertTrue(r.claimsVerified)
        XCTAssertEqual(r.blockingDisclosures, [])
    }

    func testActivationLockedLeads() {
        let r = G.generate(model: "iPhone 13 Pro Max", storage: 256, grade: "C", icloudClear: false, imeiClean: true)
        XCTAssertTrue(r.title.contains("PARTS ONLY"))
        XCTAssertTrue(r.description.hasPrefix("⚠️ ACTIVATION LOCKED"))
        XCTAssertFalse(r.description.lowercased().contains("ready to activate"))
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("activation locked") })
    }

    func testGradeF() {
        let r = G.generate(model: "iPhone 6s", grade: "F", icloudClear: true, imeiClean: true)
        XCTAssertTrue(r.title.contains("Grade F")); XCTAssertTrue(r.title.contains("For Parts"))
    }

    func testBadIMEI() {
        let r = G.generate(model: "iPhone 12", grade: "B", icloudClear: true, imeiClean: false)
        XCTAssertTrue(r.description.contains("NOT clean"))
        XCTAssertTrue(r.claimsVerified)
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("IMEI not clean") })
    }

    func testBatteryBelow80() {
        let r = G.generate(model: "iPhone 12", grade: "C", battery: "72", icloudClear: true, imeiClean: true)
        XCTAssertTrue(r.description.contains("Service warning"))
    }

    func testAirPods() {
        let r = G.generate(model: "AirPods Pro 2nd Gen", grade: "B", icloudClear: true, imeiClean: true)
        XCTAssertFalse(r.title.contains("0GB")); XCTAssertTrue(r.description.contains("🎧"))
    }

    func testJunkBatteryIgnored() {
        for bad in ["n/a", "", "abc", "150", "-5"] {
            XCTAssertFalse(G.generate(model: "iPhone 12", grade: "B", battery: bad).description.contains("Battery Health"), bad)
        }
    }

    func testCarrierIsBuyerFacingTruth() {
        var r = G.generate(model: "iPhone 14 Pro Max", storage: 128, grade: "B", icloudClear: true, imeiClean: true, carrierLock: "verizon_locked")
        XCTAssertTrue(r.title.contains("Verizon Locked")); XCTAssertTrue(r.description.contains("locked to Verizon"))
        XCTAssertTrue(r.carrierVerified)
        r = G.generate(model: "iPhone 14 Pro Max", grade: "B", carrierLock: "other_locked")
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("exact carrier") })
        XCTAssertFalse(G.generate(model: "iPhone 14 Pro Max", grade: "B").carrierVerified)
    }
}
