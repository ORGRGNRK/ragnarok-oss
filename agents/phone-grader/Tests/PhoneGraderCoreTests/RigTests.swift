import XCTest
@testable import PhoneGraderCore

final class DomainSchemaTests: XCTestCase {
    let schema = try! DomainSchema(data: TestData.resource("phone.schema.json"))

    func testLoadsV04Vocabulary() {
        XCTAssertTrue(schema.version.hasSuffix("v0.4"))
        XCTAssertEqual(schema.fields.count, 45)
        XCTAssertEqual(schema.order.first, "UID")
        XCTAssertEqual(schema.fields["storage"]?.sevenB, .keep)
        XCTAssertEqual(schema.fields["condition_screen"]?.sevenB, .triggerOnly)
        XCTAssertEqual(schema.fields["model_exact"]?.pass, .screen)
        XCTAssertEqual(schema.fields["Battery %"]?.range, 0...100)
        let keep = Set(schema.screenKeepFields.map(\.name))
        XCTAssertTrue(keep.isSuperset(of: ["storage", "IMEI", "icloud_lock", "true_tone", "parts_history"]))
        XCTAssertFalse(keep.contains("model_exact")); XCTAssertFalse(keep.contains("face_id"))
    }

    func testRefAndConfidenceRules() {
        var r = PhoneRecord()
        XCTAssertEqual(r.merge("storage", Claim(.text("256 GB"), source: .camera), schema: schema), .missingRef("storage"))
        XCTAssertEqual(r.merge("Item", Claim(.text("iPhone"), source: .inference), schema: schema), .missingConfidence("Item"))
        XCTAssertNil(r.merge("Item", Claim(.text("iPhone"), source: .inference, confidence: 0.4), schema: schema))
    }

    func testVisibilityAndSourceRules() {
        var r = PhoneRecord()
        // IMEI Status can't be seen by a camera (x-visibility never; sources human/pull)
        XCTAssertEqual(r.merge("IMEI Status", Claim(.text("Clean"), source: .camera, ref: "f"), schema: schema),
                       .sourceNotAllowed("IMEI Status", .camera))
        XCTAssertEqual(r.merge("model_number", Claim(.text("MG953LL/A"), source: .camera, ref: "f"), schema: schema),
                       .unknownField("model_number"))
    }

    func testTypedValuesRejectProbeJunk() {
        // probe-002 finding 4: powers_on="12:30", port_type="stand" under bare strings
        var r = PhoneRecord()
        XCTAssertEqual(r.merge("powers_on", Claim(.text("12:30"), source: .camera, ref: "f"), schema: schema), .badValue("powers_on", "12:30"))
        XCTAssertEqual(r.merge("port_type", Claim(.text("stand"), source: .camera, ref: "f"), schema: schema), .badValue("port_type", "stand"))
        XCTAssertEqual(r.merge("Battery %", Claim(.text("140"), source: .camera, ref: "f"), schema: schema), .badValue("Battery %", "140"))
        XCTAssertNil(r.merge("Battery %", Claim(.text("82%"), source: .camera, ref: "f"), schema: schema))
        XCTAssertEqual(r.value("Battery %"), .int(82))
        XCTAssertNil(r.merge("carrier_lock", Claim(.text("sim locked"), source: .camera, ref: "f"), schema: schema))
        XCTAssertEqual(r.value("carrier_lock"), .text("SIM locked"))
    }

    func testPrecedenceHumanAndPullImmovable() {
        var r = PhoneRecord()
        XCTAssertNil(r.merge("Battery %", Claim(.int(82), source: .human, ref: "checklist"), schema: schema))
        XCTAssertEqual(r.merge("Battery %", Claim(.int(85), source: .camera, ref: "f"), schema: schema), .outranked("Battery %", existing: .human))
        XCTAssertEqual(r.value("Battery %"), .int(82))
        // camera may replace camera; UNKNOWN never erases
        XCTAssertNil(r.merge("color", Claim(.text("black"), source: .camera, ref: "a"), schema: schema))
        XCTAssertNil(r.merge("color", Claim(.text("Pacific Blue"), source: .camera, ref: "b"), schema: schema))
        XCTAssertNil(r.merge("color", Claim(.unknown, source: .camera, ref: "c"), schema: schema))
        XCTAssertEqual(r.value("color"), .text("Pacific Blue"))
        XCTAssertNil(r.merge("color", Claim(.text("Pacific Blue"), source: .pull, ref: "INV-2026-017"), schema: schema))
        XCTAssertNotNil(r.merge("color", Claim(.text("black"), source: .inference, confidence: 0.9), schema: schema))
    }

    func testSevenBOnlyHoldsKeepFields() {
        var r = PhoneRecord()
        XCTAssertEqual(r.merge("condition_screen", Claim(.text("cracked"), source: .camera, ref: "f"), schema: schema, fromLocal7B: true),
                       .sevenBNotKeep("condition_screen"))
        XCTAssertEqual(r.merge("model_exact", Claim(.text("iPhone 12 Pro Max"), source: .camera, ref: "f"), schema: schema, fromLocal7B: true),
                       .sevenBNotKeep("model_exact"))
        XCTAssertNil(r.merge("storage", Claim(.text("256 GB"), source: .camera, ref: "f"), schema: schema, fromLocal7B: true))
    }

    func testPendingVsTerminal() {
        var r = PhoneRecord()
        XCTAssertEqual(r.state(of: "storage", schema: schema), .pending)
        XCTAssertEqual(r.state(of: "IMEI Status", schema: schema), .pending)
        r.markDone(.exterior)
        XCTAssertEqual(r.state(of: "color", schema: schema), .terminal)
        XCTAssertEqual(r.state(of: "storage", schema: schema), .pending)
        r.markDone(.screen)
        XCTAssertEqual(r.passesDone, [.exterior, .screen])
        XCTAssertEqual(r.state(of: "storage", schema: schema), .terminal)
        XCTAssertEqual(r.state(of: "IMEI Status", schema: schema), .terminal)
        r.merge("storage", Claim(.text("256 GB"), source: .camera, ref: "f"), schema: schema)
        XCTAssertEqual(r.state(of: "storage", schema: schema), .known)
    }

    func testQwenProbeFixtureOnlyKeepsKeepFields() throws {
        let raw = try JSONSerialization.jsonObject(with: TestData.fixture("qwen-raw-002.json")) as! [String: [String: Any]]
        var r = PhoneRecord()
        let text = raw["about-upright/C-constrained"]!["raw"] as! String
        let rej = RigParse.applyScreenText(text, frameRef: "frame:abc", into: &r, schema: schema)
        XCTAssertEqual(r.value("storage"), .text("256 GB"))
        XCTAssertEqual(r.value("carrier_lock"), .text("SIM locked"))
        XCTAssertEqual(r.value("IMEI"), .text("350000000000000"))     // spaces stripped, 15 digits
        XCTAssertEqual(r.value("model_exact"), .unknown)             // ungrounded prior (finding 6) refused
        XCTAssertEqual(r.value("powers_on"), .unknown)               // "12:30" refused
        XCTAssertTrue(rej.contains(.sevenBNotKeep("model_exact")))
        XCTAssertTrue(rej.contains(.badValue("powers_on", "12:30")))
        XCTAssertTrue(rej.contains(.sevenBNotKeep("make")))   // identity is never the 7B's
    }

    func testClaudeRefFixtureMerges() throws {
        let obj = try JSONSerialization.jsonObject(with: TestData.fixture("claude-ref-003.json")) as! [String: Any]
        let claims = obj["claims"] as! [String: [String: Any]]
        var r = PhoneRecord(identity: obj["identity"] as? String)
        for (k, c) in claims {
            let v: ClaimValue = (c["value"] as? Int).map(ClaimValue.int) ?? .text("\(c["value"]!)")
            let field = RigParse.defaultAliases[k] ?? k
            r.merge(field, Claim(v, source: ClaimSource(rawValue: c["source"] as! String)!, ref: c["ref"] as? String,
                                 confidence: c["confidence"] as? Double), schema: schema)
        }
        XCTAssertEqual(r.value("model_exact"), .text("iPhone 12 Pro Max"))
        XCTAssertEqual(r.value("Battery %"), .int(82))
        XCTAssertEqual(r.value("firmware_ios"), .text("iOS 26.6"))
        XCTAssertTrue(r.rejected.contains { $0.hasPrefix("model_number") })
        XCTAssertTrue(r.rejected.contains { $0.hasPrefix("not_wiped") })
    }

    func testBlockersAndChecklistClaims() {
        var r = PhoneRecord()
        r.markDone(.exterior); r.markDone(.screen)
        XCTAssertEqual(RigBlockers.blockers(r, schema: schema).count, 2)   // both terminal UNKNOWN
        let cl = [ChecklistEntry(Checklist.imei, "PASS"), ChecklistEntry(Checklist.icloud, "PASS"), ChecklistEntry(Checklist.battery, "82%")]
        for (f, c) in ChecklistClaims.claims(from: cl) { r.merge(f, c, schema: schema) }
        XCTAssertEqual(RigBlockers.blockers(r, schema: schema), [])
        r.merge("mdm_lock", Claim(.text("MDM locked"), source: .camera, ref: "f"), schema: schema)
        XCTAssertEqual(RigBlockers.blockers(r, schema: schema), ["mdm_lock = MDM locked"])
        var bad = PhoneRecord(); bad.merge("IMEI Status", Claim(.text("Flagged"), source: .human, ref: "c"), schema: schema)
        bad.merge("icloud_lock", Claim(.text("clean"), source: .human, ref: "c"), schema: schema)
        XCTAssertEqual(RigBlockers.blockers(bad, schema: schema), ["IMEI Status = Flagged"])
    }

    func testBlockersStopMaxBuy() {
        let d = DealRule.compute(floor: 200, floorQuotable: true, source: .atlasLadder, costs: DealCosts())
        XCTAssertTrue(d.actionable)
        let b = DealRule.applyRigBlockers(d, blockers: ["IMEI Status is UNKNOWN"])
        XCTAssertFalse(b.actionable); XCTAssertTrue(b.headline.hasPrefix("BLOCKED"))
        XCTAssertEqual(DealRule.applyRigBlockers(d, blockers: []), d)
    }
}

final class GradeAggregationTests: XCTestCase {
    func cat(_ n: String, _ g: String?, _ p: CapturePass = .exterior) -> RigCategory { RigCategory(name: n, grade: g, notes: "", pass: p) }

    func testLowestCategory() {
        XCTAssertEqual(GradeAggregator.overall([cat("Back glass / housing", "B"), cat("Frame / edges", "D")], checklist: []).overall, "D")
    }
    func testSingleCosmeticCrackedGlassIsB() {
        let a = GradeAggregator.overall([cat("Screen glass", "C"), cat("Display", "A", .screen), cat("Frame / edges", "B")], checklist: [])
        XCTAssertEqual(a.overall, "B")
    }
    func testCrackedGlassWithBadDisplayStaysLow() {
        XCTAssertEqual(GradeAggregator.overall([cat("Screen glass", "C"), cat("Display", "D", .screen)], checklist: []).overall, "D")
    }
    func testTwoCsStayC() {
        XCTAssertEqual(GradeAggregator.overall([cat("Screen glass", "C"), cat("Frame / edges", "C")], checklist: []).overall, "C")
    }
    func testAnyFCapsAtF() {
        XCTAssertEqual(GradeAggregator.overall([cat("Screen glass", "A"), cat("Frame / edges", "F")], checklist: []).overall, "F")
    }
    func testBatteryUnder80CapsAtC() {
        let a = GradeAggregator.overall([cat("Screen glass", "A"), cat("Back", "A")], checklist: [ChecklistEntry(Checklist.battery, "78%")])
        XCTAssertEqual(a.overall, "C"); XCTAssertTrue(a.concerns.contains { $0.contains("78%") })
        XCTAssertEqual(GradeAggregator.overall([cat("Back", "D")], checklist: [ChecklistEntry(Checklist.battery, "78%")]).overall, "D")
    }
    func testFailedChecklistIsConcernAndCaps() {
        let a = GradeAggregator.overall([cat("Back", "A")], checklist: [ChecklistEntry(Checklist.imei, "FAIL")])
        XCTAssertEqual(a.overall, "C"); XCTAssertEqual(a.concerns.count, 1)
    }
    func testUnknownCategoryNeedsHuman() {
        let a = GradeAggregator.overall([cat("Screen glass", nil), cat("Back", "A")], checklist: [])
        XCTAssertNil(a.overall)
        XCTAssertNil(GradeAggregator.overall([], checklist: []).overall)
    }
}

/// Fixture-backed models: no network, no API spend.
struct FixtureModel: RigModel {
    let label: String
    let reply: String
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String { reply }
}
struct DownModel: RigModel {
    let label = "ollama:down"
    func call(system: String, prompt: String, images: [Data], schema: [String: Any]) async throws -> String { throw URLError(.cannotConnectToHost) }
}

final class RigPipelineTests: XCTestCase {
    let schema = try! DomainSchema(data: TestData.resource("phone.schema.json"))
    func frame(_ i: Int, _ p: CapturePass) -> (RigFrame, Data) {
        var f = RigFrame(index: i, slot: "grader", time: Double(i), hash: UInt64(i), sharpness: 1, centerLuma: 10, file: "f\(i).jpg", markedPass: p)
        f.pass = p; return (f, Data([0xFF, 0xD8]))
    }

    func testEndToEndWithFixturesAndAudit() async throws {
        var o = RigOutcome()
        let ext = #"{"categories":[{"name":"Screen glass","grade":"C","notes":"hairline crack top-left"},{"name":"Back glass / housing","grade":"B","notes":"light scuffs"},{"name":"Frame / edges","grade":"B","notes":"one ding"}],"claims":[{"field":"color","value":"Pacific Blue","confidence":0.8,"frame":"0000000000000001","note":""},{"field":"condition_screen","value":"cracked","confidence":0.6,"frame":"0000000000000001","note":""}],"concerns":[],"photos_needed":[],"summary":"Clean body, cracked glass."}"#
        try await RigPipeline.gradePass(&o, pass: .exterior, frames: [frame(1, .exterior)], grader: FixtureModel(label: "fixture-grader", reply: ext),
                                        rubric: "rubric", schema: schema, checklist: [])
        o.record.markDone(.exterior)
        let qwen = try JSONSerialization.jsonObject(with: TestData.fixture("qwen-raw-002.json")) as! [String: [String: Any]]
        await RigPipeline.screenText(&o, frames: [frame(2, .screen)], qwen: FixtureModel(label: "fixture-qwen", reply: qwen["about-upright/C-constrained"]!["raw"] as! String), schema: schema)
        let scr = #"{"categories":[{"name":"Display / authenticity","grade":"A","notes":"True Tone present"}],"claims":[{"field":"model_exact","value":"iPhone 12 Pro Max","confidence":0.97,"frame":"0000000000000002","note":"Model Name row"}],"concerns":[],"photos_needed":[],"summary":"OEM-looking display."}"#
        try await RigPipeline.gradePass(&o, pass: .screen, frames: [frame(2, .screen)], grader: FixtureModel(label: "fixture-grader", reply: scr),
                                        rubric: "rubric", schema: schema, checklist: [])
        o.record.markDone(.screen)
        XCTAssertEqual(o.record.value("model_exact"), .text("iPhone 12 Pro Max"))
        XCTAssertEqual(o.record.value("storage"), .text("256 GB"))

        let audit = #"{"verdicts":[{"target":"condition_screen","verdict":"reject","reason":"line follows the rig — reflection"},{"target":"color","verdict":"verify","reason":"ok"},{"target":"category:Screen glass","verdict":"unsure","reason":"could be reflection"}],"concerns":[]}"#
        try await RigPipeline.audit(&o, frames: [frame(1, .exterior)], auditor: FixtureModel(label: "fixture-auditor", reply: audit))
        XCTAssertEqual(o.record.value("condition_screen"), .unknown)
        XCTAssertEqual(o.record.claims["condition_screen"]?.candidates, ["cracked"])
        XCTAssertEqual(o.record.value("color"), .text("Pacific Blue"))
        XCTAssertTrue(o.concerns.contains { $0.contains("condition_screen") })
        // disputed category → no overall grade → manual review
        let (g, agg) = RigPipeline.gradeResult(o, checklist: [], schema: schema)
        XCTAssertNil(g); XCTAssertNil(agg.overall)
        // human re-grades the disputed category
        o.categories[0].grade = "B"
        let (g2, _) = RigPipeline.gradeResult(o, checklist: [], schema: schema)
        XCTAssertEqual(g2?.overall_grade, "B")
        XCTAssertTrue(g2!.concerns.contains { $0.contains("IMEI Status") })   // terminal UNKNOWN surfaced
    }

    func testNoBackendIsNotFatal() async {
        var o = RigOutcome()
        await RigPipeline.screenText(&o, frames: [frame(1, .screen)], qwen: DownModel(), schema: schema)
        XCTAssertTrue(o.record.claims.isEmpty)
        XCTAssertTrue(o.log[0].contains("unavailable"))
    }

    func testAuditorCannotMoveHumanFacts() {
        var o = RigOutcome()
        o.record.merge("Battery %", Claim(.int(82), source: .human, ref: "checklist"), schema: schema)
        RigPipeline.applyAudit(AuditResult(verdicts: [AuditVerdict(target: "Battery %", verdict: .reject, reason: "x")], concerns: []), to: &o, by: "a")
        XCTAssertEqual(o.record.value("Battery %"), .int(82)); XCTAssertTrue(o.concerns.isEmpty)
    }

    func testSchemasAreValidJSON() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(RigPrompts.screenTextSchema(schema)))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(RigPrompts.passGradeSchema(schema, .exterior)))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(RigPrompts.auditSchema))
        let ext = RigPrompts.passFields(schema, .exterior).map(\.name)
        XCTAssertTrue(ext.contains("condition_screen")); XCTAssertFalse(ext.contains("storage"))
        XCTAssertTrue(RigPrompts.passFields(schema, .screen).map(\.name).contains("model_exact"))
    }
}

final class RigCaptureTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ f: (Int, Int) -> UInt8) -> GrayImage {
        var p: [UInt8] = []; for y in 0..<h { for x in 0..<w { p.append(f(x, y)) } }
        return GrayImage(width: w, height: h, pixels: p)
    }

    func testRotation() {
        let a = img(3, 2) { x, y in UInt8(y * 3 + x) }      // [0 1 2; 3 4 5]
        let r = a.rotated(90)
        XCTAssertEqual(r.width, 2); XCTAssertEqual(r.height, 3)
        XCTAssertEqual(r.pixels, [3, 0, 4, 1, 5, 2])
        XCTAssertEqual(a.rotated(180).pixels, [5, 4, 3, 2, 1, 0])
        XCTAssertEqual(a.rotated(270).rotated(90), a)
        XCTAssertEqual(Upright.rotation(width: 1920, height: 1080, cameraRotation: nil), 90)
        XCTAssertEqual(Upright.rotation(width: 1080, height: 1920, cameraRotation: nil), 0)
        XCTAssertEqual(Upright.rotation(width: 1920, height: 1080, cameraRotation: 270), 270)
    }

    func testHashAndSharpness() {
        let grad = img(64, 64) { x, _ in UInt8(255 - x * 4) }
        let flipped = img(64, 64) { x, _ in UInt8(x * 4) }
        XCTAssertEqual(PHash.hamming(grad.dHash, grad.dHash), 0)
        XCTAssertGreaterThan(PHash.hamming(grad.dHash, flipped.dHash), 40)
        let checker = img(64, 64) { x, y in (x + y) % 2 == 0 ? 255 : 0 }
        let flat = img(64, 64) { _, _ in 128 }
        XCTAssertGreaterThan(checker.sharpness, flat.sharpness)
        XCTAssertEqual(flat.sharpness, 0)
    }

    func testPassTaggingFindsScreenOnJump() {
        var frames: [RigFrame] = []
        for i in 0..<10 { frames.append(RigFrame(index: i, slot: "a", time: Double(i), hash: 0b1010 << UInt64(i % 3), sharpness: 1, centerLuma: 20, file: "")) }
        for i in 10..<16 { frames.append(RigFrame(index: i, slot: "a", time: Double(i), hash: ~UInt64(0) >> UInt64(i % 3), sharpness: 1, centerLuma: 180, file: "")) }
        let t = PassTagger.tag(frames)
        XCTAssertTrue(t.prefix(10).allSatisfy { $0.pass == .exterior })
        XCTAssertTrue(t.suffix(6).allSatisfy { $0.pass == .screen })
    }

    func testNoJumpMeansAllExteriorAndMarksWin() {
        let fs = (0..<5).map { RigFrame(index: $0, slot: "a", time: Double($0), hash: 7, sharpness: 1, centerLuma: 20, file: "") }
        XCTAssertTrue(PassTagger.tag(fs).allSatisfy { $0.pass == .exterior })
        let marked = (0..<4).map { RigFrame(index: $0, slot: "a", time: Double($0), hash: 7, sharpness: 1, centerLuma: 20, file: "",
                                             markedPass: $0 < 2 ? .exterior : .screen) }
        XCTAssertEqual(PassTagger.tag(marked).map(\.pass), [.exterior, .exterior, .screen, .screen])
    }

    func testBestFramePerAngle() {
        var fs: [RigFrame] = []
        for i in 0..<16 {
            var f = RigFrame(index: i, slot: "a", time: Double(i), hash: UInt64(1) << UInt64(i * 4 % 64) | UInt64(i) << 40,
                             sharpness: Double(i % 2 == 0 ? 1 : 9), centerLuma: 0, file: "\(i)")
            f.pass = .exterior; fs.append(f)
        }
        let best = PassTagger.bestPerAngle(fs, pass: .exterior, angles: 8, dupDistance: 0)
        XCTAssertEqual(best.count, 8)
        XCTAssertTrue(best.allSatisfy { $0.sharpness == 9 })
        XCTAssertEqual(PassTagger.selection(fs, pass: .exterior, cap: 4).count, 4)
        // near-duplicates collapse
        let dup = (0..<8).map { i -> RigFrame in var f = RigFrame(index: i, slot: "a", time: Double(i), hash: 42, sharpness: 1, centerLuma: 0, file: ""); f.pass = .exterior; return f }
        XCTAssertEqual(PassTagger.bestPerAngle(dup, pass: .exterior).count, 1)
    }
}
