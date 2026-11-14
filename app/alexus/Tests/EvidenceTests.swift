import XCTest
final class EvidenceTests: XCTestCase {
    func testApprovalExpiresAndBindsCandidate() {
        let now=Date()
        let b=RepairBinding(repairID:"r",candidateSHA256:"candidate",sourceSHA256:"base",checksSHA256:"checks",nonce:"fresh",expiresAt:now.addingTimeInterval(120))
        XCTAssertTrue(b.isCurrent(now:now,source:"base",candidate:"candidate"))
        XCTAssertFalse(b.isCurrent(now:now.addingTimeInterval(121),source:"base",candidate:"candidate"))
        XCTAssertFalse(b.isCurrent(now:now,source:"changed",candidate:"candidate"))
        XCTAssertFalse(b.isCurrent(now:now,source:"base",candidate:"swapped"))
    }
    func testNoVerifiedRuntimeStateIsInvented() {
        XCTAssertNil(EvidenceState(rawValue:"Verified"))
        XCTAssertEqual(EvidenceState.unverified.rawValue,"Unverified")
    }
}
