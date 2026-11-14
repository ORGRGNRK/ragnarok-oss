import XCTest
@testable import PhoneGraderCore

/// PhoneFacts is the one buyer-facing model: Listing text, QR payload and share photo all use it.
final class MarketplaceCopyTests: XCTestCase {
    func input(grade: String = "A", repairs: RepairParts? = RepairParts(backGlass: .aftermarket), checklist: [ChecklistEntry]? = nil) -> ReceiptInput {
        let g = GradeResult(overall_grade: grade, categories: [GradeCategory(name: "Frame", grade: "B", notes: "Light scratches on frame")],
                            concerns: ["Grade B: check Face ID"], photos_needed: [], summary: "")
        return ReceiptInput(recordId: 2, date: Date(timeIntervalSince1970: 1_792_000_000), model: "iPhone 16 Pro", storageGb: 128,
                            carrier: "Unlocked", imei: "490154203237518", serial: nil, grade: g,
                            checklist: checklist ?? [ChecklistEntry(Checklist.icloud, "PASS"), ChecklistEntry(Checklist.imei, "PASS"),
                                                     ChecklistEntry(Checklist.battery, "91%")],
                            backend: nil, listingPrice: 640, repairs: repairs, batteryCycles: 312)
    }
    func testListingFromFacts() {
        let f = PhoneFacts(input())
        let l = f.listing(location: "Springfield, IL", concerns: ["Grade B: check Face ID"])
        let all = l.title + "\n" + l.description
        XCTAssertNil(all.range(of: #"(?i)\bgrad(e|ing|ed)\b"#, options: .regularExpression), all)
        XCTAssertEqual(l.title, "iPhone 16 Pro 128GB Unlocked - 91% Battery - Excellent - iCloud Off")
        for s in ["📱 iPhone 16 Pro 128GB Unlocked", "✅ Unlocked — works on any carrier", "🔋 Battery health 91% · 312 cycles",
                  "✅ IMEI clean (blacklist checked)", "✅ iCloud / Activation Lock off", "✨ Excellent condition, light scratches on frame",
                  "⚠️ Back glass replaced with aftermarket part", "   • Check Face ID", "📍 Springfield, IL — local pickup"] {
            XCTAssertTrue(l.description.contains(s), "missing \(s)\n\(l.description)")
        }
        XCTAssertFalse(all.contains("490154203237518")); XCTAssertFalse(all.contains("$"))
    }
    func testQRTextNoGradeNoPrices() {
        let q = PhoneFacts(input()).qrText(recordId: 2, maskIMEI: true)
        XCTAssertTrue(q.contains("IMEI: ***********7518")); XCTAssertFalse(q.contains("490154203237518"))
        XCTAssertFalse(q.contains("GRADE")); XCTAssertFalse(q.contains("$")); XCTAssertFalse(q.contains("640"))
        XCTAssertTrue(PhoneFacts(input()).qrText(recordId: 2, maskIMEI: false).contains("IMEI: 490154203237518"))
    }
    func testUnknownsAndProblemsDisclosed() {
        let f = PhoneFacts(input(repairs: nil, checklist: [ChecklistEntry(Checklist.imei, "FAIL"), ChecklistEntry(Checklist.battery, "76"),
                                                          ChecklistEntry(Checklist.originalScreen, "FAIL")]))
        XCTAssertNil(f.icloudOff); XCTAssertNil(f.icloudText)
        XCTAssertEqual(f.disclosures, ["Screen is not the original Apple screen", "Battery below 80% — iPhone will show a Service message",
                                       "IMEI is NOT clean (blacklisted / reported)"])
        XCTAssertTrue(f.lines(emoji: true).contains("⚠️ IMEI NOT clean"))
    }
    func testConditionKeepsItShort() {
        let long = "Close-up edge shots show light dust specks and faint micro-scratches on the titanium frame near the buttons, consistent with normal light use"
        XCTAssertEqual(MarketplaceCopy.condition(grade: "B", notes: ["Faint scratches on frame, consistent with light use", long]),
                       "Good condition, light signs of use, faint scratches on frame")
    }
    func testConditionWording() {
        XCTAssertEqual(MarketplaceCopy.condition(grade: "b", notes: []), "Good condition, light signs of use")
        XCTAssertEqual(MarketplaceCopy.condition(grade: "C", notes: ["Grade C. Dent on corner", ""]), "Fair condition, visible wear, dent on corner")
    }
    func testTemplateHasNoGrade() {
        let t = ListingTemplate.make(model: "iPhone 13", storage: 128, grade: "B", gradeNotes: "light scuff", battery: 88,
                                     carrier: "unlocked", price: nil, location: "Springfield, IL")
        XCTAssertFalse(t.body.lowercased().contains("grade")); XCTAssertTrue(t.body.contains("Condition: Good condition"))
    }

    // MARK: - Title
    func facts(model: String = "iPhone 16 Pro", storage: Int? = 128, color: String? = nil, carrier: String = "Unlocked",
               grade: String? = "A", checklist: [ChecklistEntry] = [ChecklistEntry(Checklist.icloud, "PASS"), ChecklistEntry(Checklist.battery, "92%")]) -> PhoneFacts {
        let g = grade.map { GradeResult(overall_grade: $0, categories: [], concerns: [], photos_needed: [], summary: "") }
        return PhoneFacts(ReceiptInput(recordId: 1, date: Date(), model: model, storageGb: storage, color: color, carrier: carrier,
                                       imei: "490154203237518", serial: nil, grade: g, checklist: checklist, backend: nil, listingPrice: 640))
    }
    func assertClean(_ t: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(t.count, PhoneFacts.titleLimit, t, file: file, line: line)
        XCTAssertNil(t.range(of: #"(?i)\bgrade\b|\$|490154203237518|atlas|\(model not set\)|unknown|nil"#, options: .regularExpression), t, file: file, line: line)
    }
    func testTitleOrderAndConditionWord() {
        let t = facts(color: "Black Titanium").title
        // Full set is 82 chars → lowest-priority "iCloud Off" is dropped first.
        XCTAssertEqual(t, "iPhone 16 Pro 128GB Unlocked - 92% Battery - Excellent - Black Titanium"); assertClean(t)
        XCTAssertEqual(facts(model: "iPhone 13", color: "Blue").title, "iPhone 13 128GB Unlocked - 92% Battery - Excellent - Blue - iCloud Off")
        XCTAssertEqual(facts(grade: "B").title, "iPhone 16 Pro 128GB Unlocked - 92% Battery - Good - iCloud Off")
        XCTAssertEqual(facts(grade: "C").title, "iPhone 16 Pro 128GB Unlocked - 92% Battery - Fair - iCloud Off")
    }
    func testTitleLockedCarrierAndTB() {
        let t = facts(model: "iPhone 15 Pro Max", storage: 1024, carrier: "Verizon Locked", grade: "B").title
        XCTAssertTrue(t.hasPrefix("iPhone 15 Pro Max 1TB Verizon Locked - 92% Battery - Good"), t); assertClean(t)
    }
    func testTitleMissingFieldsOmitted() {
        let t = facts(storage: nil, carrier: "Unknown", grade: nil, checklist: []).title
        XCTAssertEqual(t, "iPhone 16 Pro"); assertClean(t)
        XCTAssertEqual(facts(model: "", storage: 64, grade: nil, checklist: []).title, "iPhone 64GB Unlocked")
    }
    func testTitleLongDropsLowestPriorityFirst() {
        let t = facts(model: "iPhone 16 Pro Max", storage: 1024, color: "Desert Titanium Limited Edition Finish", carrier: "T-Mobile Locked").title
        assertClean(t)
        XCTAssertEqual(t, "iPhone 16 Pro Max 1TB T-Mobile Locked - 92% Battery - Excellent - iCloud Off".count <= 80 ?
                       "iPhone 16 Pro Max 1TB T-Mobile Locked - 92% Battery - Excellent" : t)
        XCTAssertFalse(t.contains("Desert")); XCTAssertTrue(t.contains("92% Battery")); XCTAssertTrue(t.contains("Excellent"))
        let huge = facts(model: String(repeating: "iPhone 16 Pro Max ", count: 6)).title
        XCTAssertLessThanOrEqual(huge.count, PhoneFacts.titleLimit)
    }
    func testTitleActivationLockedKeepsPartsOnly() {
        let t = facts(model: "iPhone 16 Pro Max 1TB Extra Words Here To Make It Long", color: "Natural Titanium", grade: "F",
                      checklist: [ChecklistEntry(Checklist.icloud, "FAIL"), ChecklistEntry(Checklist.battery, "88")]).title
        XCTAssertTrue(t.hasSuffix(" - PARTS ONLY"), t); XCTAssertFalse(t.contains("iCloud Off")); assertClean(t)
    }
}
