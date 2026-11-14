import XCTest
@testable import PhoneGraderCore

/// BUY/THIN/PASS verdicts on top of the one formula — profit is subtracted exactly once.
final class ProfitFloorTests: XCTestCase {
    func deal(_ floor: Double?, profit: Double = 40, parts: RepairParts = RepairParts(), quotable: Bool = true) -> DealResult {
        DealRule.compute(floor: floor, floorQuotable: quotable, source: floor == nil ? .none : .atlasLadder,
                         costs: DealCosts(parts: parts, profitTarget: profit))   // gas $4
    }

    func testTargetEqualsMaxBuyNotDoubleCounted() throws {
        let d = deal(560)
        let a = try XCTUnwrap(ProfitMath.analyze(d, asking: 480))
        XCTAssertEqual(a.breakEven, 556); XCTAssertEqual(a.targetBuy, 516); XCTAssertEqual(a.targetBuy, d.maxBuy)
        XCTAssertEqual(a.totalCost, 484); XCTAssertEqual(a.grossSpread, 80); XCTAssertEqual(a.netProfit, 76); XCTAssertEqual(a.profitCushion, 36)
        XCTAssertTrue(a.verdict.hasPrefix("BUY"))
    }
    func testDefaultProfitIs40AndOverride() throws {
        XCTAssertEqual(ProfitMath.analyze(deal(560))?.profitTarget, 40)
        XCTAssertEqual(ProfitMath.analyze(deal(560, profit: 75))?.targetBuy, 481)
        XCTAssertEqual(ProfitMath.analyze(deal(560, profit: -5))?.targetBuy, 556) // negative clamps to 0
    }
    func testBuyThinPassVerdicts() throws {
        XCTAssertTrue(try XCTUnwrap(ProfitMath.analyze(deal(560), asking: 516)).verdict.hasPrefix("BUY"))   // at max buy, cushion 0
        let thin = try XCTUnwrap(ProfitMath.analyze(deal(560), asking: 530))
        XCTAssertTrue(thin.verdict.hasPrefix("THIN")); XCTAssertEqual(thin.netProfit, 26); XCTAssertEqual(thin.profitCushion, -14)
        let pass = try XCTUnwrap(ProfitMath.analyze(deal(560), asking: 560))
        XCTAssertTrue(pass.verdict.hasPrefix("PASS")); XCTAssertEqual(pass.netProfit, -4)
    }
    func testPartsCountInTotalCost() throws {
        let a = try XCTUnwrap(ProfitMath.analyze(deal(300, parts: RepairParts(backGlass: .aftermarket)), asking: 200))
        XCTAssertEqual(a.partsCost, 30); XCTAssertEqual(a.breakEven, 266); XCTAssertEqual(a.targetBuy, 226)
        XCTAssertEqual(a.totalCost, 234); XCTAssertEqual(a.netProfit, 66)
    }
    func testTargetBelowZeroIsNoDeal() throws {
        let a = try XCTUnwrap(ProfitMath.analyze(deal(30)))
        XCTAssertTrue(a.noDeal); XCTAssertNil(a.recommendedOffer); XCTAssertTrue(a.verdict.hasPrefix("NO DEAL"))
        XCTAssertTrue(try XCTUnwrap(ProfitMath.analyze(deal(44))).noDeal)    // max buy exactly 0
    }
    func testNoNumbersWhenBlockedStaleOrNoFloor() {
        XCTAssertNil(ProfitMath.analyze(deal(nil)))
        XCTAssertNil(ProfitMath.analyze(deal(560, quotable: false)))
        let blocked = DealRule.applyRigBlockers(deal(560), blockers: ["iCloud not verified"])
        XCTAssertNil(ProfitMath.analyze(blocked, asking: 480))
    }
}
