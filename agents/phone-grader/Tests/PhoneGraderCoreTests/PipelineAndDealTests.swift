import XCTest
@testable import PhoneGraderCore

/// Ported from phone-grader-bot/test/listing-pipeline.test.js, plus the owner's deal rule.
final class PipelineTests: XCTestCase {
    let passing: [ChecklistEntry] = [
        .init(Checklist.icloud, "PASS"), .init(Checklist.imei, "PASS"), .init(Checklist.battery, "87%"),
        .init(Checklist.originalScreen, "PASS"), .init(Checklist.rearGlassIntact, "PASS"),
        .init("All buttons + Face ID/Touch ID work", "PASS"),
    ]
    func a(model: String = "iPhone 14 Pro Max", carrier: String = "unlocked", checklist: [ChecklistEntry]? = nil,
           grade: String = "C", concerns: [String] = ["light edge wear"], price: Double? = nil) -> AssessmentInput {
        AssessmentInput(phoneModel: model, storageGb: 128, carrierLock: carrier, checklist: checklist ?? passing,
                        overallGrade: grade, concerns: concerns, notes: nil, askingPrice: price)
    }
    func run(_ x: AssessmentInput) throws -> AssessmentResult {
        try ListingPipeline.evaluate(x, engine: TestData.engine, today: TestData.expiredDay)
    }
    func replacing(_ label: String, _ v: String) -> [ChecklistEntry] {
        passing.map { $0.label == label ? .init(label, v) : $0 }
    }

    func testNormalizesEmbeddedStorage() {
        let r = ListingPipeline.normalizeModelAndStorage("iPhone 14 Pro Max 256GB", nil)
        XCTAssertEqual(r.model, "iPhone 14 Pro Max"); XCTAssertEqual(r.storage, 256)
    }

    func testNeedsHumanPriceThenReady() throws {
        let p = try run(a())
        XCTAssertEqual(p.loopStatus, .NEEDS_HUMAN_PRICE)
        XCTAssertEqual(p.priceGate.status, "on_ladder")
        XCTAssertFalse(p.priceGate.floorQuotable)
        XCTAssertTrue(p.listing.claimsVerified)
        let r = try run(a(price: 400))
        XCTAssertEqual(r.loopStatus, .READY)
        XCTAssertEqual(r.listing.suggestedPrice, 400)
        XCTAssertTrue(r.listing.description.contains("Activation lock OFF"))
        XCTAssertTrue(r.listing.description.contains("IMEI checked"))
    }

    func testBlocksOnActivationLock() throws {
        let r = try run(a(checklist: replacing(Checklist.icloud, "FAIL"), price: 150))
        XCTAssertEqual(r.loopStatus, .BLOCKED)
        XCTAssertTrue(r.listing.title.contains("ACTIVATION LOCKED"))
        XCTAssertTrue(r.listing.blockingDisclosures.contains { $0.contains("activation locked") })
    }

    func testBlocksOnIMEI() throws {
        let r = try run(a(checklist: replacing(Checklist.imei, "FAIL"), price: 150))
        XCTAssertEqual(r.loopStatus, .BLOCKED)
        XCTAssertTrue(r.listing.blockingDisclosures.contains { $0.contains("IMEI") })
    }

    func testVerifiedCarrierReachesCopy() throws {
        let r = try run(a(carrier: "verizon_locked", price: 400))
        XCTAssertEqual(r.loopStatus, .READY)
        XCTAssertEqual(r.carrierLock, "verizon_locked")
        XCTAssertTrue(r.listing.title.contains("Verizon Locked"))
        XCTAssertTrue(r.listing.description.contains("locked to Verizon"))
        // app decision: locked phones price off the ladder's "carrier locked" row exactly
        XCTAssertEqual(r.priceGate.matchedRow, "iPhone 14 Pro Max 128GB Carrier Locked")
    }

    func testRejectsBadAskingPrices() {
        XCTAssertThrowsError(try run(a(price: 0))) { XCTAssertTrue($0.localizedDescription.contains("whole-dollar")) }
        XCTAssertThrowsError(try run(a(price: 399.5))) { XCTAssertTrue($0.localizedDescription.contains("whole-dollar")) }
    }

    func testBlocksWhenHumanTruthMissing() throws {
        let r = try run(a(checklist: [], price: 400))
        XCTAssertEqual(r.loopStatus, .BLOCKED)
        XCTAssertTrue(r.listing.blockingDisclosures.contains { $0.contains("checks are required") })
    }

    func testDamageReachesPriceAndSelectsRealQuote() throws {
        var cl = replacing(Checklist.originalScreen, "FAIL")
        cl = cl.map { $0.label == Checklist.rearGlassIntact ? .init($0.label, "FAIL") : $0 }
        let r = try run(a(model: "iPhone 12 Pro Max", checklist: cl, grade: "D", concerns: []))
        XCTAssertEqual(r.priceGate.status, "actual_quote")
        XCTAssertEqual(r.priceGate.floor, 40)
        XCTAssertTrue(r.listing.description.contains("Screen is original / OEM"))
        XCTAssertTrue(r.listing.description.contains("Rear glass intact"))
    }

    func testGraderPromptMatchesBot() {
        let p = Grader.promptText(checklist: [.init(Checklist.icloud, "PASS")], phoneModel: "iPhone 13", notes: nil)
        XCTAssertEqual(p, "Phone model: iPhone 13\nHuman checklist results (verified in person by the buyer):\n- Activation lock OFF / signed out of iCloud: PASS\n\nGrade this phone per the rubric.")
        XCTAssertTrue(Grader.promptText(checklist: [], phoneModel: nil, notes: nil).contains("(no checklist items provided yet)"))
        let rubric = String(data: TestData.resource("rubric.md"), encoding: .utf8)!
        XCTAssertTrue(rubric.contains("**This is the single most common miscalibration to avoid"))
    }

    func testParseGradeValidates() throws {
        let ok = #"{"overall_grade":"B","categories":[{"name":"Screen","grade":"B","notes":"ok"}],"concerns":[],"photos_needed":[],"summary":"fine"}"#
        XCTAssertEqual(try Grader.parseGrade("```json\n" + ok + "\n```").overall_grade, "B")
        XCTAssertThrowsError(try Grader.parseGrade(ok.replacingOccurrences(of: "\"B\",\"categories", with: "\"E\",\"categories")))
    }
}

final class DealRuleTests: XCTestCase {
    /// $4.00 gas (20 mi ÷ 24 MPG × $4.80), no parts, $40 profit → $44 off the floor.
    let c = DealCosts()
    func testOneFormula() {
        let d = DealRule.compute(floor: 300, floorQuotable: true, source: .atlasLadder, costs: c)
        XCTAssertEqual(d.gasCost, 4); XCTAssertEqual(d.partsCost, 0); XCTAssertEqual(d.profitTarget, 40)
        XCTAssertEqual(d.breakEven, 296); XCTAssertEqual(d.maxBuy, 256); XCTAssertTrue(d.actionable)
        XCTAssertEqual(d.headline, "Max buy $256")
        XCTAssertEqual(d.detail, "$300 floor − $4 gas (20 mi ÷ 24 MPG × $4.800/gal) − $0 parts − $40 profit = $256 max buy")
    }
    func testNoBuffersOrFixedDriving() {
        // the old rule was 300 − 6 − 35 = 259 / 300 − 6 − 50 = 244; neither survives
        let free = DealCosts(gas: GasInputs(roundTripMiles: 0), profitTarget: 0)
        XCTAssertEqual(DealRule.compute(floor: 300, floorQuotable: true, source: .atlasLadder, costs: free).maxBuy, 300)
    }
    func testPartsSubtract() {
        var k = c; k.parts = RepairParts(backGlass: .apple, screen: .aftermarket)
        let d = DealRule.compute(floor: 240, floorQuotable: true, source: .atlasLadder, costs: k)
        XCTAssertEqual(d.partsCost, 160 + 45); XCTAssertEqual(d.maxBuy, 240 - 4 - 205 - 40)
        XCTAssertFalse(d.actionable); XCTAssertTrue(d.headline.hasPrefix("PASS"))
    }
    func testStaleLadderIsReferenceOnly() {
        let d = DealRule.compute(floor: 300, floorQuotable: false, source: .atlasLadder, costs: c)
        XCTAssertEqual(d.maxBuy, 256); XCTAssertFalse(d.actionable); XCTAssertTrue(d.headline.contains("STALE"))
    }
    func testNoFloorNoBuy() {
        let d = DealRule.compute(floor: nil, floorQuotable: false, source: .none, costs: c)
        XCTAssertNil(d.maxBuy); XCTAssertNil(d.breakEven); XCTAssertFalse(d.actionable)
    }
    func testUnprofitablePasses() {
        let d = DealRule.compute(floor: 40, floorQuotable: true, source: .buyerQuote, costs: c)
        XCTAssertEqual(d.maxBuy, -4); XCTAssertFalse(d.actionable); XCTAssertTrue(d.headline.hasPrefix("PASS"))
    }
    func testManualBuyerQuoteBeatsStaleLadder() {
        let gate = TestData.engine.getAtlasFloor(model: "iPhone 14 Pro Max", storage: 128, grade: "B", today: TestData.expiredDay)
        XCTAssertFalse(DealRule.compute(gate: gate, manualQuote: nil, costs: c).actionable)
        let d = DealRule.compute(gate: gate, manualQuote: 410, costs: c)
        XCTAssertEqual(d.maxBuy, 366); XCTAssertEqual(d.source, .buyerQuote); XCTAssertTrue(d.actionable)
    }
    func testRealQuoteGateIsActionable() {
        let gate = TestData.engine.getAtlasFloor(model: "iPhone 12 Pro Max", storage: 128, grade: "D",
                                                 aftermarketScreen: true, crackedBack: true, today: TestData.expiredDay)
        let d = DealRule.compute(gate: gate, manualQuote: nil, costs: c)
        XCTAssertEqual(d.source, .buyerQuote); XCTAssertEqual(d.maxBuy, (gate.floor ?? 0) - 44); XCTAssertTrue(d.headline.hasPrefix("PASS"))
    }
    /// The worked example in the Oct 16 report: iPhone 16 Pro 128 Unlocked Grade B, floor $540, 20 mi, 24 MPG, no repairs.
    func testWorkedExample() {
        let k = DealCosts(gas: GasInputs(roundTripMiles: 20, mpg: 24, pricePerGallon: 4.80), profitTarget: 40)
        let d = DealRule.compute(floor: 540, floorQuotable: true, source: .atlasLadder, costs: k)
        XCTAssertEqual(d.maxBuy, 496); XCTAssertEqual(d.breakEven, 536)
        let e = DealCosts(gas: GasInputs(roundTripMiles: 20, mpg: 24, pricePerGallon: 6.104), profitTarget: 40)
        let d2 = DealRule.compute(floor: 540, floorQuotable: true, source: .atlasLadder, costs: e)
        XCTAssertEqual(d2.gasCost, 5.09); XCTAssertEqual(d2.maxBuy, 494.91); XCTAssertEqual(usd(d2.maxBuy!), "494.91")
    }
}
