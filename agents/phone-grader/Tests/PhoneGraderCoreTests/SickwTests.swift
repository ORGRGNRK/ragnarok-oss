import Foundation
import XCTest
@testable import PhoneGraderCore

/// SICKW parsing / verdicts from saved sample responses. Never calls sickw.com.
final class SickwTests: XCTestCase {
    func sample(_ n: String) -> SickwResponse { SickwResponse.parse(String(data: TestData.fixture("sickw/\(n)"), encoding: .utf8)!) }

    // MARK: IMEI validation (before any paid call)
    func testLuhn() {
        XCTAssertTrue(IMEI.luhnValid("490154203237518"))
        XCTAssertFalse(IMEI.luhnValid("490154203237519"))
        XCTAssertTrue(IMEI.luhnValid("356938035643809"))
        XCTAssertFalse(IMEI.luhnValid(""))
        XCTAssertFalse(IMEI.luhnValid("49015420323751a"))
    }
    func testIMEIProblem() {
        XCTAssertNil(IMEI.problem("490154203237518"))
        XCTAssertNil(IMEI.problem(" 49-015420-323751-8 "))
        XCTAssertTrue(IMEI.problem("49015420323751")!.contains("exactly 15 digits"))
        XCTAssertTrue(IMEI.problem("4901542032375180")!.contains("exactly 15 digits"))
        XCTAssertTrue(IMEI.problem("490154203237519")!.contains("Luhn"))
        XCTAssertTrue(IMEI.problem("G6TDW22T0XXX")!.contains("digits only"))
        XCTAssertNotNil(IMEI.problem(""))
    }
    func testServiceIdsAndURLs() {
        XCTAssertTrue(Sickw.validServiceId("61")); XCTAssertTrue(Sickw.validServiceId("0"))
        XCTAssertFalse(Sickw.validServiceId("251")); XCTAssertFalse(Sickw.validServiceId("6a")); XCTAssertFalse(Sickw.validServiceId(""))
        XCTAssertEqual(Sickw.checkURL(key: "K", imei: "490154203237518", service: "61").absoluteString,
                       "https://sickw.com/api.php?format=json&key=K&imei=490154203237518&service=61")
        XCTAssertEqual(Sickw.balanceURL(key: "K").absoluteString, "https://sickw.com/api.php?action=balance&key=K")
        XCTAssertEqual(Sickw.defaultServiceId, "61")
        XCTAssertEqual(Sickw.service("61")?.listPrice, "$0.13")
    }
    func testBalanceAndRedaction() {
        XCTAssertEqual(Sickw.parseBalance("878.75"), 878.75)
        XCTAssertEqual(Sickw.parseBalance(" 12.5\n"), 12.5)
        XCTAssertNil(Sickw.parseBalance("<span>Error A01: API KEY is Wrong!</span>"))
        XCTAssertEqual(Sickw.redact("bad key ABC-123 here", key: "ABC-123"), "bad key ••• here")
    }

    // MARK: parsing
    func testParseJSONWithBrAndTags() {
        let r = sample("svc61-clean.json")
        XCTAssertTrue(r.ok); XCTAssertNil(r.errorCode)
        XCTAssertEqual(r.value("iCloud Lock"), "OFF")
        XCTAssertEqual(r.value("Blacklist Status"), "CLEAN")
        XCTAssertEqual(r.value("SIM-Lock"), "Locked")
        XCTAssertEqual(r.price, "0.13"); XCTAssertEqual(r.balance, "878.62"); XCTAssertEqual(r.orderId, "76369091")
        XCTAssertTrue(r.raw.contains("<br>"))      // raw kept verbatim for the receipt
    }
    func testParseBetaObjectAndPlainText() {
        XCTAssertEqual(sample("svc6-blacklisted.json").value("Blacklist Status"), "BLACKLISTED")
        let p = sample("svc3-off.html")
        XCTAssertTrue(p.ok); XCTAssertEqual(p.fields.first?.value, "OFF")
    }
    func testParseErrors() {
        let e = sample("error-instant.json")
        XCTAssertFalse(e.ok); XCTAssertEqual(e.errorCode, "S03"); XCTAssertEqual(e.errorMessage, "S03: Service is not instant")
        let k = sample("error-nokey.html")
        XCTAssertFalse(k.ok); XCTAssertEqual(k.errorCode, "A01")
        XCTAssertFalse(SickwResponse.parse("").ok)
    }

    // MARK: verdicts → checklist (never a pass on ambiguity)
    func testCleanSetsBothPass() {
        let v = SickwVerdict.from(sample("svc61-clean.json"))
        XCTAssertEqual(v.icloudClear, true); XCTAssertEqual(v.imeiClean, true); XCTAssertEqual(v.simLock, "Locked")
        var vals: [String: String] = [:]
        let (changed, conflicts) = v.apply(to: &vals)
        XCTAssertEqual(vals[Checklist.icloud], "PASS"); XCTAssertEqual(vals[Checklist.imei], "PASS")
        XCTAssertEqual(changed.count, 2); XCTAssertTrue(conflicts.isEmpty)
    }
    func testIcloudOnFailsAndBlacklistUnanswered() {
        let v = SickwVerdict.from(sample("svc78-icloud-on.json"))
        XCTAssertEqual(v.icloudClear, false); XCTAssertNil(v.imeiClean)
        var vals: [String: String] = [Checklist.icloud: "PASS"]
        let (_, conflicts) = v.apply(to: &vals)
        XCTAssertEqual(vals[Checklist.icloud], "FAIL"); XCTAssertNil(vals[Checklist.imei])
        XCTAssertEqual(conflicts.count, 1)
    }
    func testFindMyOffOnly() {
        let v = SickwVerdict.from(sample("svc3-off.html"))
        XCTAssertEqual(v.icloudClear, true); XCTAssertNil(v.imeiClean)
    }
    func testBlacklistedAndStolenFail() {
        XCTAssertEqual(SickwVerdict.from(sample("svc6-blacklisted.json")).imeiClean, false)
        let s = SickwVerdict.from(sample("svc16-stolen.json"))
        XCTAssertEqual(s.imeiClean, false); XCTAssertNil(s.icloudClear)
    }
    func testSimLockOnlyAndErrorsChangeNothing() {
        for n in ["svc8-simlock-only.json", "error-instant.json", "error-nokey.html"] {
            let v = SickwVerdict.from(sample(n))
            XCTAssertNil(v.icloudClear, n); XCTAssertNil(v.imeiClean, n)
            var vals: [String: String] = [:]
            XCTAssertTrue(v.apply(to: &vals).changed.isEmpty, n); XCTAssertTrue(vals.isEmpty, n)
        }
    }
    func testAmbiguousValuesStayUnanswered() {
        let r = SickwResponse.parse(#"{"result":"iCloud Lock: UNKNOWN<br>Blacklist Status: N/A<br>ESN Status: Clean - Your device is eligible.","status":"success"}"#)
        let v = SickwVerdict.from(r)
        XCTAssertNil(v.icloudClear); XCTAssertNil(v.imeiClean)      // carrier ESN clean is not a blacklist pass
        XCTAssertTrue(v.notes.contains { $0.contains("one carrier only") })
        let lost = SickwVerdict.from(SickwResponse.parse(#"{"result":"iCloud Lock: OFF<br>iCloud Status: LOST","status":"success"}"#))
        XCTAssertEqual(lost.icloudClear, false)
    }
    func testPassNeverOverridesHumanFail() {
        let v = SickwVerdict.from(sample("svc61-clean.json"))
        var vals: [String: String] = [Checklist.imei: "FAIL"]
        let (_, conflicts) = v.apply(to: &vals)
        XCTAssertEqual(vals[Checklist.imei], "FAIL"); XCTAssertEqual(vals[Checklist.icloud], "PASS")
        XCTAssertTrue(conflicts.first!.contains("kept your FAIL"))
    }
    func testReceiptKeepsRawAndSource() throws {
        let r = sample("svc61-clean.json"), v = SickwVerdict.from(r)
        let rc = ImeiCheckReceipt(serviceId: "61", serviceName: "iPHONE CARRIER & FMI & BLACKLIST", imei: "356478840268XXX",
                                  checkedAt: Date(timeIntervalSince1970: 0), response: r, verdict: v)
        XCTAssertEqual(rc.source, "SICKW"); XCTAssertEqual(rc.raw, r.raw); XCTAssertEqual(rc.price, "0.13")
        let back = try JSONDecoder().decode(ImeiCheckReceipt.self, from: JSONEncoder().encode(rc))
        XCTAssertEqual(back, rc)
    }
}
