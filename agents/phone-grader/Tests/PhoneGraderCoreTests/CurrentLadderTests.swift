import XCTest
@testable import PhoneGraderCore

/// Sanity checks on the generated (current) Atlas ladder. Values are checked
/// against the 2026-10-14 sheet only when that is the bundled anchor date.
final class CurrentLadderTests: XCTestCase {
    let l = TestData.currentLadder

    func testLoadsAndHasSixColumns() {
        XCTAssertEqual(l.columns, ["SWAP", "A", "B", "C", "D", "DOA"])
        XCTAssertGreaterThan(l.rows.count, 100)
        XCTAssertTrue(l.rows.allSatisfy { $0.ladder.count == 6 })
    }

    func testFreshOnAnchorDay() {
        XCTAssertFalse(l.isExpired(today: l.anchoredDate))
    }

    func test16Pro128Values20261014() throws {
        guard l.anchoredDate == "2026-10-14" else { throw XCTSkip("ladder re-anchored") }
        let u = l.rows[l.rowIndex["iphone 16 pro|128|unlocked"]!].ladder
        let c = l.rows[l.rowIndex["iphone 16 pro|128|carrier locked"]!].ladder
        XCTAssertEqual(u, [570, 560, 540, 370, 280, 90])
        XCTAssertEqual(c, [395, 385, 365, 290, 200, 90])
        XCTAssertEqual(l.deliveryFriday, "2026-10-16")
    }
}
