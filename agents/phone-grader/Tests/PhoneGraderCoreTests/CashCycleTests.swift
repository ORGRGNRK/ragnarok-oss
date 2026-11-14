import XCTest
@testable import PhoneGraderCore

final class CashCycleTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    func day(_ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    func sold(bought b: Int, listed l: Int, sold s: Int, paid p: Int? = nil, paidPrice: Double = 300, soldPrice: Int = 400) -> SaleTracking {
        var t = SaleTracking(); t.purchasePrice = paidPrice; t.boughtAt = day(b)
        t.setListing(soldPrice + 20, at: day(l)); t.markSold(soldPrice, at: day(s)); t.paidAt = p.map { day($0) }
        return t
    }

    func testClosedCycleWithPayoutAndPartsAhead() {
        let c = CashCycle(recordId: 1, sale: sold(bought: 5, listed: 6, sold: 12, paid: 14),
                          parts: [(date: day(2), cost: 30)], placeholderParts: 80, gas: 5, now: day(20), calendar: cal)
        XCTAssertEqual(c.firstCashOut, day(2)); XCTAssertEqual(c.partsLeadDays, 3)
        XCTAssertEqual(c.daysToList, 1); XCTAssertEqual(c.daysHeld, 7); XCTAssertEqual(c.daysToCash, 2)
        XCTAssertEqual(c.cycleDays, 12)                  // Oct 2 parts → Oct 14 payout
        XCTAssertEqual(c.cashTied, 335)                  // logged parts replace the $80 placeholder
        XCTAssertEqual(c.profit, 65); XCTAssertFalse(c.partsEstimated); XCTAssertFalse(c.cashInAssumed)
        XCTAssertEqual(c.returnOnCash!, 65.0 / 335, accuracy: 1e-9)
        XCTAssertEqual(c.annualizedReturn!, 65.0 / 335 * 365 / 12, accuracy: 1e-9)
        XCTAssertTrue(c.unknowns.isEmpty)
    }

    func testMissingPayoutUsesSoldDateAndSaysSo() {
        let c = CashCycle(recordId: 3, sale: sold(bought: 1, listed: 1, sold: 4), parts: [], placeholderParts: nil, gas: nil, calendar: cal)
        XCTAssertTrue(c.cashInAssumed); XCTAssertEqual(c.daysToCash, 0); XCTAssertEqual(c.cycleDays, 3)
        XCTAssertTrue(c.unknowns.contains { $0.contains("payout not logged") && $0.contains("history paid 3") })
        XCTAssertTrue(c.lines.contains { $0.contains("(assumed)") })
    }

    func testSameDayFlipCountsAsOneDayForRates() {
        let c = CashCycle(recordId: 1, sale: sold(bought: 3, listed: 3, sold: 3, paid: 3), parts: [], placeholderParts: nil, gas: nil, calendar: cal)
        XCTAssertEqual(c.cycleDays, 0)
        XCTAssertEqual(c.annualizedReturn!, 100.0 / 300 * 365, accuracy: 1e-9)
        XCTAssertEqual(c.profitPerDay, 100)
    }

    func testNoBuyDateMeansNoCycleNotAGuess() {
        var t = SaleTracking(); t.purchasePrice = 300; t.markSold(400, at: day(9))
        let c = CashCycle(recordId: 7, sale: t, parts: [(date: day(1), cost: 20)], placeholderParts: nil, gas: nil, calendar: cal)
        XCTAssertNil(c.firstCashOut); XCTAssertNil(c.cycleDays); XCTAssertNil(c.annualizedReturn)
        XCTAssertTrue(c.unknowns.first!.contains("no buy date"))
        XCTAssertTrue(c.lines.first!.contains("unknown"))
    }

    func testOpenPhoneCountsDaysSoFarAndHasNoReturn() {
        var t = SaleTracking(); t.purchasePrice = 250; t.boughtAt = day(1); t.setListing(350, at: day(2))
        let c = CashCycle(recordId: 2, sale: t, parts: [], placeholderParts: 60, gas: 4, now: day(11), calendar: cal)
        XCTAssertTrue(c.isOpen); XCTAssertEqual(c.cycleDays, 10); XCTAssertNil(c.daysHeld)
        XCTAssertEqual(c.cashTied, 314); XCTAssertTrue(c.partsEstimated)
        XCTAssertNil(c.returnOnCash); XCTAssertNil(c.profit)
    }

    func testSummaryWeightsByCashAndPoolsReturn() {
        let a = CashCycle(recordId: 1, sale: sold(bought: 1, listed: 1, sold: 3, paid: 3, paidPrice: 100, soldPrice: 150),
                          parts: [], placeholderParts: nil, gas: nil, calendar: cal)          // 2d, $100 → +$50
        let b = CashCycle(recordId: 2, sale: sold(bought: 1, listed: 2, sold: 11, paid: 11, paidPrice: 300, soldPrice: 360),
                          parts: [], placeholderParts: nil, gas: nil, calendar: cal)          // 10d, $300 → +$60
        var o = SaleTracking(); o.purchasePrice = 200; o.boughtAt = day(5)
        let open = CashCycle(recordId: 3, sale: o, parts: [], placeholderParts: nil, gas: nil, now: day(20), calendar: cal)
        var n = SaleTracking(); n.purchasePrice = 90
        let unknown = CashCycle(recordId: 4, sale: n, parts: [], placeholderParts: nil, gas: nil, calendar: cal)

        let s = CashCycleSummary([a, b, open, unknown])
        XCTAssertEqual(s.closed.count, 2); XCTAssertEqual(s.open.count, 1); XCTAssertEqual(s.unknown.map(\.recordId), [4])
        XCTAssertEqual(s.avgCycleDays, 6)
        XCTAssertEqual(s.cashWeightedCycleDays!, (100.0 * 2 + 300 * 10) / 400, accuracy: 1e-9)   // 8 days
        XCTAssertEqual(s.turnsPerYear!, 365.0 / 8, accuracy: 1e-9)
        XCTAssertEqual(s.totalProfit, 110)
        XCTAssertEqual(s.annualizedReturn!, 110.0 / 3200 * 365, accuracy: 1e-9)
        XCTAssertEqual(s.cashOutNow, 200); XCTAssertEqual(s.oldestOpenDays, 15)
        XCTAssertTrue(s.lines.contains { $0.contains("#4 UNKNOWN") && $0.contains("no buy date") })
        XCTAssertTrue(s.text.hasPrefix("Cash cycle 8d"))
    }

    func testEmptySummaryRendersUnknownNotZero() {
        let s = CashCycleSummary([])
        XCTAssertNil(s.cashWeightedCycleDays); XCTAssertNil(s.turnsPerYear)
        XCTAssertEqual(s.text, "Cash cycle: no bought phones logged")
        XCTAssertTrue(s.lines.contains { $0.contains("Cash cycle: unknown") })
    }

    func testBoughtAndPaidCommandsSetDatesAndOldRecordsDecode() throws {
        var t = SaleTracking()
        let (id, cmd) = try SaleCommand.parse(["bought", "4", "$310"]); XCTAssertEqual(id, 4)
        cmd.apply(to: &t, at: day(2)); XCTAssertEqual(t.purchasePrice, 310); XCTAssertEqual(t.boughtAt, day(2))
        t.markSold(400, at: day(6))
        try SaleCommand.parse(["paid", "4"]).command.apply(to: &t, at: day(8)); XCTAssertEqual(t.paidAt, day(8))
        t.unmarkSold(); XCTAssertNil(t.paidAt)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let old = try dec.decode(SaleTracking.self, from: Data(#"{"purchasePrice":200,"soldPrice":300}"#.utf8))
        XCTAssertNil(old.boughtAt); XCTAssertNil(old.paidAt)
    }
}
