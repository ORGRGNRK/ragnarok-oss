import Foundation
import XCTest
@testable import PhoneGraderCore

enum TestData {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let root = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    static func resource(_ name: String) -> Data { try! Data(contentsOf: root.appendingPathComponent("Resources/\(name)")) }
    static func fixture(_ name: String) -> Data { try! Data(contentsOf: testsDir.appendingPathComponent("Fixtures/\(name)")) }
    /// Golden parity is pinned to the frozen 2026-09-05 ladder; the live bundled
    /// ladder (Resources/atlas-ladder.json) is regenerated weekly by scripts/refresh_atlas.py.
    static let ladder = try! AtlasLadder(data: fixture("atlas-ladder-2026-09-05.json"))
    static let currentLadder = try! AtlasLadder(data: resource("atlas-ladder.json"))
    static let quotes = try! QuoteBook(data: resource("actual-quotes.json"))
    static let engine = PriceEngine(ladder: ladder, quotes: quotes)
    /// The frozen ladder's delivery Friday is 2026-09-04 → expired on this date.
    static let expiredDay = "2026-10-14"
    static let freshDay = "2026-09-01"
}
