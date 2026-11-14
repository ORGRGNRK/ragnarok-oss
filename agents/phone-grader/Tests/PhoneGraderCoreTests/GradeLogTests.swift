import XCTest
@testable import PhoneGraderCore

final class GradeLogTests: XCTestCase {
    func testRequestPreservesPayloadAndStableIdentity() throws {
        let body = Data(#"{"grade":"B","summary":"quote \" and 日本語"}"#.utf8)
        let r = try GradeLog.request(endpoint: "https://example.test/grades", token: "secret", identity: "fixed-id", payload: body)
        XCTAssertEqual(r.url?.absoluteString, "https://example.test/grades/fixed-id")
        XCTAssertEqual(r.httpMethod, "PUT")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(r.httpBody, body)
        XCTAssertEqual(r.timeoutInterval, 20)
    }
    func testRejectsUnsafeEndpoints() {
        for url in ["", "http://example.test/grades", "file:///tmp/grades", "https://u:p@example.test", "https://example.test?token=x", "https://example.test/#x"] {
            XCTAssertThrowsError(try GradeLog.request(endpoint: url, token: "secret", identity: "id", payload: Data()))
        }
    }
    func testRejectsMissingCredentialsAndHeaderInjection() {
        for token in ["", "  ", "token\r\nX: injected"] {
            XCTAssertThrowsError(try GradeLog.request(endpoint: "https://example.test", token: token, identity: "id", payload: Data()))
        }
    }
    func testValidReceipt() throws {
        XCTAssertEqual(try GradeLog.recordID(data: Data(#"{"id":"stable"}"#.utf8), status: 200, expected: "stable"), "stable")
    }
    func testRejectsUnsuccessfulStatusesWithoutLeakingBody() {
        for status in [0, 301, 400, 401, 429, 500] {
            XCTAssertThrowsError(try GradeLog.recordID(data: Data("private server secret".utf8), status: status, expected: "id")) { error in
                XCTAssertFalse(error.localizedDescription.contains("private server secret"))
            }
        }
    }
    func testRejectsMalformedOrWrongIdentityReceipts() {
        for body in ["", "[]", "{}", #"{"id":4}"#, #"{"id":"other"}"#] {
            XCTAssertThrowsError(try GradeLog.recordID(data: Data(body.utf8), status: 200, expected: "id"))
        }
    }
}
