import Foundation
import CryptoKit

enum EvidenceState: String, Codable, CaseIterable { case observed = "Observed", passed = "Selected checks passed", unverified = "Unverified" }
struct RepairBinding: Codable, Equatable {
    let repairID: String
    let candidateSHA256: String
    let sourceSHA256: String
    let checksSHA256: String
    let nonce: String
    let expiresAt: Date
    func isCurrent(now: Date, source: String, candidate: String) -> Bool {
        expiresAt > now && expiresAt.timeIntervalSince(now) <= 180 && sourceSHA256 == source && candidateSHA256 == candidate && !nonce.isEmpty
    }
}
struct ReceiptEnvelope: Codable {
    let sequence: Int
    let timestamp: String
    let action: String
    let previousHash: String
    let hash: String
}
struct PublicProject: Decodable, Identifiable {
    let id: String
    let title: String
    let category: String
    let description: String
    let path: String
    let runtime: String
    let status: String
    let checks: [ProjectCheck]
    let limits: [String]
}
struct ProjectCheck: Decodable, Identifiable {
    var id: String { name + checked_at }
    let name: String
    let result: String
    let cases: Int
    let checked_at: String
    let scope: String
}
struct WorkCatalog: Decodable {
    let schema: String
    let captured_at: String
    let projects: [PublicProject]
}
struct FoundationText: Decodable {
    let project_title: String
    let foundation_title: String
    let quote: String
    let origin_quote: String
    let theory: [String]
}
