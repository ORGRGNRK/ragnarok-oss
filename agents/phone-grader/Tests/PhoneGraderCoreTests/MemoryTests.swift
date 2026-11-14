import XCTest
@testable import PhoneGraderCore

final class MemoryTests: XCTestCase {
    let la = TimeZone(identifier: "America/Los_Angeles")!
    func testAppendOnlyNotes() throws {
        let a = try MemoryNotes.appending(nil, "  AT&T unlocked it ", at: Date(timeIntervalSince1970: 1))
        let b = try MemoryNotes.appending(a, "buyer haggled from 650 to 600", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(b.map(\.text), ["AT&T unlocked it", "buyer haggled from 650 to 600"])
        XCTAssertEqual(Array(b.prefix(1)), a)
        XCTAssertThrowsError(try MemoryNotes.appending(b, "   "))
    }
    struct OldRecord: Codable { var id: Int; var notes: String?; var notesLog: [MemoryNote]? }
    func testOldRecordsDecodeWithoutNotesLog() throws {
        let r = try JSONDecoder().decode(OldRecord.self, from: Data(#"{"id":2,"notes":"old free text"}"#.utf8))
        XCTAssertNil(r.notesLog); XCTAssertEqual(r.notes, "old free text")
    }
    func testCLIDateParse() {
        let d = CLIDate.parse("2026-10-16 19:30", timeZone: la)!
        XCTAssertEqual(ISO8601DateFormatter().string(from: d), "2026-10-17T02:30:00Z")
        XCTAssertEqual(CLIDate.parse("2026-10-16T19:30", timeZone: la), d)
        XCTAssertEqual(CLIDate.parse("2026-10-17T02:30:00Z"), d)
        XCTAssertNotNil(CLIDate.parse("2026-10-16", timeZone: la))
        XCTAssertNil(CLIDate.parse("yesterday"))
    }
    func testBackdatedListingMovesListedAt() {
        let now = Date(timeIntervalSince1970: 2_000_000), earlier = Date(timeIntervalSince1970: 1_000_000)
        var s = SaleTracking(); s.setListing(650, at: now)
        s.setListing(700, at: earlier)
        XCTAssertEqual(s.listedAt, earlier); XCTAssertEqual(s.priceHistory.map(\.price), [700, 650]); XCTAssertEqual(s.listingPrice, 650)
        var t = SaleTracking(); t.setListing(650, at: earlier); t.setListing(650, at: now)
        XCTAssertEqual(t.listedAt, earlier); XCTAssertEqual(t.priceHistory.count, 1)
    }
    func testSummaryTotals() {
        var a = SaleTracking(); a.setListing(500); a.markSold(450); a.purchasePrice = 300
        var b = SaleTracking(); b.setListing(600); b.purchasePrice = 330
        let m = SaleSummary([(a, 20, 10), (b, nil, nil)])
        XCTAssertEqual(m.totalRevenue, 450); XCTAssertEqual(m.totalPurchase, 630); XCTAssertEqual(m.totalActualProfit, 120, accuracy: 0.001)
    }
}
