import XCTest
@testable import PhoneGraderCore

/// Ported from price-mcp/test_model_names.py (asserts no prices).
final class ModelNameTests: XCTestCase {
    let e = TestData.engine
    let today = TestData.expiredDay
    func floorFor(_ m: String, storage: Int = 256, interpreter: ModelInterpreter? = nil) -> PriceResult {
        e.getAtlasFloor(model: m, storage: storage, grade: "B", today: today, interpreter: interpreter)
    }

    func testReminderCase16Promax() {
        let typed = floorFor("iPhone 16 promax"), canon = floorFor("iPhone 16 Pro Max")
        XCTAssertEqual(typed.status, canon.status)
        XCTAssertEqual(typed.matchedRow, canon.matchedRow)
        XCTAssertEqual(typed.floor, canon.floor)
        XCTAssertEqual(typed.modelResolved, "iphone 16 pro max")
        XCTAssertNotEqual(typed.status, "off_ladder")
        XCTAssertEqual(typed.model, "iPhone 16 promax")
    }

    func testLosslessAcrossVocabulary() {
        let names = TestData.ladder.canonicalModels
        XCTAssertEqual(names.count, 38)
        let variants: [(String) -> String] = [
            { $0 }, { $0.uppercased() }, { $0.replacingOccurrences(of: " ", with: "") },
            { $0.replacingOccurrences(of: " pro max", with: " promax") },
            { "apple \($0) 256gb unlocked" },
            { s in var t = s; if let r = t.range(of: "iphone ") { t.replaceSubrange(r, with: "") }; return t },
            { s in var t = s; if let r = t.range(of: "iphone ") { t.replaceSubrange(r, with: "") }; return t.replacingOccurrences(of: " ", with: "") },
        ]
        var bad: [String] = []
        for n in names { for v in variants where e.canonicalizeModel(v(n), interpreter: nil).0 != n { bad.append(v(n)) } }
        XCTAssertEqual(bad, [], "\(names.count * variants.count) variants")
    }

    func testVocabularyUnambiguous() {
        let sq = TestData.ladder.canonicalModels.map(pySquash)
        XCTAssertEqual(Set(sq).count, sq.count)
    }

    func testAmbiguousQualifierNotResolved() {
        let (got, how, _) = e.canonicalizeModel("16pm", interpreter: nil)
        XCTAssertNil(got); XCTAssertNil(how)
        XCTAssertFalse(PriceEngine.residueIsNoise("iphone16pm", "iphone16"))
        XCTAssertTrue(PriceEngine.residueIsNoise("appleiphone16promaxunlocked256gb", "iphone16promax"))
    }

    func testCanonicalizationReachesQuotesAndAdvisories() {
        let typed = e.getAtlasFloor(model: "12promax", storage: 128, grade: "B", lock: "unlocked",
                                    aftermarketScreen: true, crackedBack: true, today: today)
        let canon = e.getAtlasFloor(model: "iPhone 12 Pro Max", storage: 128, grade: "B", lock: "unlocked",
                                    aftermarketScreen: true, crackedBack: true, today: today)
        XCTAssertEqual(typed.status, "actual_quote")
        XCTAssertEqual(typed.status, canon.status)
        XCTAssertEqual(typed.warnings.filter { !$0.hasPrefix("read ") }, canon.warnings)
        XCTAssertEqual(typed.warnings.count, canon.warnings.count + 1)
        XCTAssertTrue(typed.warnings.contains { $0.contains("TWO units") })
    }

    func testOffLadderStaysOffEvenWithWrongInterpreterPick() {
        let mac = floorFor("macbook pro 14", storage: 512)
        XCTAssertEqual(mac.status, "off_ladder"); XCTAssertNil(mac.floor); XCTAssertNil(mac.modelResolved)
        let tricked = floorFor("macbook pro 14", storage: 512, interpreter: { _, _ in ("iphone 14", "stubbed") })
        XCTAssertEqual(tricked.status, "off_ladder")
        XCTAssertNil(tricked.floor)
        XCTAssertTrue(tricked.note!.contains("NO ATLAS FLOOR"))
    }

    func testInterpretedMatchIsBlockingAndHallucinationsDiscarded() {
        let r = floorFor("sixteen pro max", interpreter: { _, _ in ("iphone 16 pro max", "stub") })
        XCTAssertEqual(r.modelMatch, "interpreted")
        XCTAssertTrue(r.blockingDisclosures.contains { $0.contains("INTERPRETED") })
        let h = floorFor("sixteen pro max", interpreter: { _, _ in ("iphone 99 ultra", "stub") })
        XCTAssertNil(h.modelResolved)
        XCTAssertNil(h.floor)
    }

    func testDeterministicMatchNeverLabelledGuess() {
        XCTAssertTrue(floorFor("iPhone 16 promax").blockingDisclosures.isEmpty)
        XCTAssertTrue(floorFor("iPhone 16 promax").warnings.contains { $0.contains("read 'iPhone 16 promax'") })
        XCTAssertFalse(floorFor("iPhone 16 Pro Max").warnings.contains { $0.contains("read ") })
    }

    func testAbsentInterpreterYieldsHonestNonAnswer() {
        let dead = floorFor("sixteen pro max", interpreter: { _, _ in (nil, "unavailable (URLError)") })
        XCTAssertNil(dead.floor)
        XCTAssertTrue(dead.warnings.contains { $0.contains("interpreter did not resolve") })
    }
}
