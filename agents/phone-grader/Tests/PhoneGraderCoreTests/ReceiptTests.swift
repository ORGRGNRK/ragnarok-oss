import Foundation
import XCTest
@testable import PhoneGraderCore

final class ReceiptTests: XCTestCase {
    func input(notes: String = "Light scuff on lower edge", price: Int? = 640) -> ReceiptInput {
        let g = GradeResult(overall_grade: "B",
                            categories: [GradeCategory(name: "Screen", grade: "A", notes: "No scratches"),
                                         GradeCategory(name: "Frame", grade: "C", notes: notes)],
                            concerns: ["Check Face ID"], photos_needed: [], summary: "Solid phone; frame wear.")
        let r = SickwResponse.parse(#"{"result":"iCloud Lock: OFF<br>Blacklist Status: CLEAN<br>SIM-Lock: Unlocked","price":"0.13","balance":"878.62","id":"76369091","status":"success"}"#)
        let rc = ImeiCheckReceipt(serviceId: "61", serviceName: nil, imei: "490154203237518",
                                  checkedAt: Date(timeIntervalSince1970: 1_792_000_000), response: r, verdict: SickwVerdict.from(r))
        return ReceiptInput(recordId: 7, date: Date(timeIntervalSince1970: 1_792_000_000), model: "iPhone 16 Pro", storageGb: 128,
                            color: "Desert", carrier: "Unlocked", imei: "490154203237518", serial: "G6TDW22T0ABC", grade: g,
                            checklist: [ChecklistEntry(Checklist.icloud, "PASS"), ChecklistEntry(Checklist.imei, "PASS"),
                                        ChecklistEntry(Checklist.battery, "91"), ChecklistEntry(Checklist.originalScreen, "FAIL")],
                            sickw: [rc], backend: "apple-on-device", listingPrice: price)
    }

    func testContentAndPrivacy() {
        let t = Receipt.text(input())
        for s in ["PhoneGrader receipt", "Record #7", "PT", "iPhone 16 Pro 128GB Unlocked Desert", "Unlocked — works on any carrier",
                  "IMEI: 490154203237518", "Serial: G6TDW22T0ABC", "Battery health 91%", "GRADE B", "C Frame: Light scuff",
                  "iCloud / Activation Lock off", "IMEI clean (blacklist checked)", "FAIL - Original screen",
                  "unanswered - Charging", "Disclosure: Screen is not the original Apple screen", "SIM-lock: Unlocked", "order 76369091", "Graded with: apple-on-device",
                  "Listing price: $640"] {
            XCTAssertTrue(t.contains(s), "missing \(s)\n\(t)")
        }
        // Never: Atlas/buy/profit/floor, raw API response, balance/charge, keys, IPs.
        for bad in ["Atlas", "floor", "Floor", "max buy", "Max buy", "profit", "Profit", "<br>", "878.62", "0.13", "balance", "\"result\""] {
            XCTAssertFalse(t.contains(bad), "leaked \(bad)")
        }
    }
    func testFactsNotRepeated() {
        let t = Receipt.text(input())
        XCTAssertEqual(t.components(separatedBy: "iCloud").count - 1, 1, t)   // once, from the shared facts
        XCTAssertFalse(t.contains("Pass - iCloud")); XCTAssertFalse(t.contains("Blacklist: CLEAN"))
    }
    func testScrubsIPsKeysLinksFromModelText() {
        let t = Receipt.text(input(notes: "seen at 10.0.0.20 key ABC-DEF-GHI-JKL-MNO-PQR-STU-VWX sk-ant-abcdef123456 https://x.y/z"))
        XCTAssertFalse(t.contains("10.0.0.20")); XCTAssertFalse(t.contains("ABC-DEF-GHI")); XCTAssertFalse(t.contains("sk-ant"))
        XCTAssertFalse(t.contains("https://"))
    }
    func testMaskAndPriceToggle() {
        let t = Receipt.text(input(), ReceiptOptions(maskIMEI: true, includeListingPrice: false))
        XCTAssertTrue(t.contains("IMEI: ***********7518")); XCTAssertFalse(t.contains("490154203237518"))
        XCTAssertTrue(t.contains("Serial: ********0ABC"))
        XCTAssertFalse(t.contains("Listing price"))
    }
    func testTrimsToLimit() {
        let long = String(repeating: "very long note ", count: 40)
        var i = input(notes: long)
        i.grade!.categories += (1...12).map { GradeCategory(name: "Area \($0)", grade: "B", notes: long) }
        i.grade!.summary = long; i.grade!.concerns = [long, long, long]
        let full = Receipt.build(i, ReceiptOptions(), trim: 0)
        XCTAssertGreaterThan(full.count, 1500)
        let t = Receipt.text(i)
        XCTAssertLessThanOrEqual(t.count, 1500)
        XCTAssertTrue(t.contains("GRADE B")); XCTAssertTrue(t.contains("IMEI: 490154203237518")); XCTAssertTrue(t.contains("IMEI clean"))
        XCTAssertLessThanOrEqual(Receipt.text(i, ReceiptOptions(maxChars: 300)).count, 300)
    }
    func testQRRoundTrip() throws {
        let t = Receipt.text(input())
        let cg = try XCTUnwrap(ReceiptQR.image(t, scale: 6))
        XCTAssertGreaterThan(cg.width, 100)
        XCTAssertEqual(ReceiptQR.decode(cg), t)
        let png = try XCTUnwrap(ReceiptQR.png(t))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(ReceiptQR.decode(png: png), t)
    }
    func testMaxSizeQRStillDecodes() throws {
        let t = String(repeating: "ABCDEFGHIJ klmnop 0123456789\n", count: 51).prefix(1500)
        XCTAssertEqual(ReceiptQR.decode(try XCTUnwrap(ReceiptQR.image(String(t), scale: 6))), String(t))
    }
}
