import Foundation
import XCTest
@testable import PhoneGraderCore

final class DealCostsTests: XCTestCase {
    func testGasFormula() {
        XCTAssertEqual(GasInputs(roundTripMiles: 20, mpg: 24, pricePerGallon: 4.80).cost, 4)
        XCTAssertEqual(GasInputs(roundTripMiles: 20, mpg: 24, pricePerGallon: 6.104).cost, 5.09)
        XCTAssertEqual(GasInputs(roundTripMiles: 55, mpg: 31, pricePerGallon: 5.199).cost, 9.22)
        XCTAssertEqual(GasInputs(roundTripMiles: 20, mpg: 0, pricePerGallon: 5).cost, 0)     // bad MPG never divides by zero
        XCTAssertEqual(GasInputs(roundTripMiles: -3, mpg: 24, pricePerGallon: 5).cost, 0)
    }
    func testDefaults() {
        let c = DealCosts()
        XCTAssertEqual(c.gas.mpg, 24); XCTAssertEqual(c.gas.roundTripMiles, 20); XCTAssertEqual(c.gas.pricePerGallon, 4.80)
        XCTAssertEqual(c.profitTarget, 40); XCTAssertEqual(c.partsCost, 0)
        XCTAssertEqual(PartCosts.placeholder.backGlassAftermarket, 30); XCTAssertEqual(PartCosts.placeholder.backGlassApple, 160)
        XCTAssertEqual(PartCosts.placeholder.screenOEM, 0)
    }
    func testPartCostsAndDefaults() {
        let pc = PartCosts(backGlassAftermarket: 25, backGlassApple: 150, screenOEM: 90, screenAftermarket: 40)
        XCTAssertEqual(RepairParts(backGlass: .aftermarket, screen: .oem).cost(pc), 115)
        XCTAssertEqual(RepairParts(backGlass: .apple, screen: .aftermarket).cost(pc), 190)
        XCTAssertEqual(RepairParts().cost(pc), 0)
        XCTAssertEqual(RepairParts.defaults(rearGlassFailed: true).backGlass, .aftermarket)
        XCTAssertEqual(RepairParts.defaults(rearGlassFailed: false), RepairParts())
        XCTAssertTrue(RepairParts(backGlass: .aftermarket).usesNonApplePart)
        XCTAssertFalse(RepairParts(backGlass: .apple).usesNonApplePart)
    }
    func testGasSourceOrder() {
        func r(_ o: Double?, _ man: Bool, _ eia: Double?) -> GasPriceSource {
            GasPriceSource.resolve(override: o, alwaysManual: man, manualPrice: 4.80, manualIsPlaceholder: true, eiaPrice: eia, eiaDate: "2026-10-12")
        }
        XCTAssertEqual(r(5.5, false, 6.1).label, GasPriceSource.overrideLabel); XCTAssertEqual(r(5.5, false, 6.1).price, 5.5)
        XCTAssertEqual(r(nil, true, 6.1).price, 4.80); XCTAssertEqual(r(nil, true, 6.1).label, GasPriceSource.placeholderLabel)
        XCTAssertEqual(r(nil, false, 6.1).label, GasPriceSource.eiaLabel); XCTAssertEqual(r(nil, false, 6.1).date, "2026-10-12")
        XCTAssertEqual(r(nil, false, nil).price, 4.80)                                   // fetch failed, nothing cached
        XCTAssertEqual(GasPriceSource.resolve(override: nil, alwaysManual: false, manualPrice: 5.1, manualIsPlaceholder: false,
                                              eiaPrice: nil, eiaDate: nil).label, GasPriceSource.manualLabel)
    }
    func testEIAParseRealPage() throws {
        let html = String(decoding: TestData.fixture("eia-ca-regular-weekly-2026-10-14.html"), as: UTF8.self)
        let r = try XCTUnwrap(EIAGasPrice.parse(html: html))
        XCTAssertEqual(r.weekOf, "2026-10-12"); XCTAssertEqual(r.price, 6.104)
        XCTAssertNil(EIAGasPrice.parse(html: "<html>maintenance</html>"))
    }
    func testEIAParseYearBoundary() {
        let html = "<td class='B6'>&nbsp;&nbsp;2027-Jan</td><td class='B5'>12/28&nbsp;</td><td class='B3'>5.111&nbsp;</td><td class='B5'>&nbsp;</td><td class='B3'>&nbsp;</td>"
        XCTAssertEqual(EIAGasPrice.parse(html: html)?.weekOf, "2026-12-28")
    }
    func testBreakdownRoundTripsAndHasEveryLine() throws {
        let k = DealCosts(gas: GasInputs(roundTripMiles: 20, mpg: 24, pricePerGallon: 6.104, priceSource: GasPriceSource.eiaLabel, priceDate: "2026-10-12"),
                          parts: RepairParts(backGlass: .aftermarket), profitTarget: 40)
        let d = DealRule.compute(floor: 540, floorQuotable: true, source: .atlasLadder, costs: k)
        let a = ProfitMath.analyze(d, asking: 450)
        let b = DealBreakdown(d, analysis: a, at: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(b.floor, 540); XCTAssertEqual(b.gasCost, 5.09); XCTAssertEqual(b.partsCost, 30); XCTAssertEqual(b.profitTarget, 40)
        XCTAssertEqual(b.maxBuy, 464.91); XCTAssertEqual(b.breakEven, 504.91); XCTAssertEqual(b.youMakeAtFloor, 40)
        XCTAssertEqual(b.netProfitAtAsking, 54.91); XCTAssertEqual(b.gas.priceDate, "2026-10-12")
        XCTAssertEqual(b.formula, "$540 floor − $5.09 gas (20 mi ÷ 24 MPG × $6.104/gal) − $30 parts − $40 profit = $464.91 max buy")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(DealBreakdown.self, from: enc.encode(b)), b)
    }
}

final class ReceiptRepairTests: XCTestCase {
    func base(_ r: RepairParts?) -> ReceiptInput {
        ReceiptInput(recordId: 9, date: Date(timeIntervalSince1970: 1_792_000_000), model: "iPhone 16 Pro", storageGb: 128,
                     carrier: "Unlocked", imei: nil, serial: nil, grade: nil, checklist: [], backend: nil, listingPrice: nil, repairs: r)
    }
    func testAftermarketBackGlassDisclosedWithoutCost() {
        let t = Receipt.text(base(RepairParts(backGlass: .aftermarket, screen: .oem)))
        XCTAssertTrue(t.contains("Repairs: back glass: Aftermarket; screen: OEM"))
        XCTAssertTrue(t.contains("Disclosure: Back glass replaced with aftermarket part"))
        for bad in ["$", "floor", "profit", "max buy", "gas"] { XCTAssertFalse(t.contains(bad), "leaked \(bad)\n\(t)") }
    }
    func testNoRepairsNoSection() {
        XCTAssertFalse(Receipt.text(base(nil)).contains("Repairs"))
        XCTAssertFalse(Receipt.text(base(RepairParts())).contains("Repairs"))
        XCTAssertFalse(Receipt.text(base(RepairParts(backGlass: .apple))).contains("Disclosure"))
    }
}
