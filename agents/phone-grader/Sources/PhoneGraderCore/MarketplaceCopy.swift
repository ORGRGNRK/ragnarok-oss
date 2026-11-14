import Foundation

/// Buyer-facing Marketplace text says condition in plain words — no letter grade or grading talk.
/// (The grade stays on History records and QR receipts.) Applied on top of the parity-tested
/// ListingCopyGenerator output so the golden fixtures stay byte-for-byte.
public enum MarketplaceCopy {
    public static let plainCondition: [String: String] = [
        "A": "Excellent condition",
        "B": "Good condition, light signs of use",
        "C": "Fair condition, visible wear",
        "D": "Rough cosmetic condition, works",
        "F": "For parts / not fully functional",
    ]

    /// "Excellent condition, light scratches on frame" — the grade word plus up to two short cosmetic notes.
    public static func condition(grade: String, notes: [String]) -> String {
        var s = plainCondition[grade.uppercased()] ?? "See photos for condition"
        // Only short wear descriptions — not the grader's commentary about photos.
        let wear = #"(?i)\b(scratch|scuff|dent|crack|chip|wear|worn|mark|ding|nick|scrape)"#
        let meta = #"(?i)\b(photo|shot|image|picture|appear|confirm|visible in)"#
        let extra = notes.map { short(clean($0)) }
            .filter { !$0.isEmpty && $0.count <= 60 && $0.range(of: wear, options: .regularExpression) != nil
                      && $0.range(of: meta, options: .regularExpression) == nil }.prefix(2)
        if !extra.isEmpty { s += ", " + extra.joined(separator: ", ") }
        return s
    }

    /// Strip grading vocabulary from a note and lowercase its first letter so it reads as part of a sentence.
    public static func clean(_ n: String) -> String {
        var t = n.replacingOccurrences(of: #"(?i)\bgrade[sd]?\s*[A-F]?\b[:,]?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(grading|grader)\b"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .;,-—"))
        guard let f = t.first else { return "" }
        return f.lowercased() + t.dropFirst()
    }

    /// First clause only ("Light scratches on frame, consistent with…" → "light scratches on frame").
    public static func short(_ n: String) -> String {
        var t = n
        for sep in [". ", "; ", ", ", " — ", " - ", " though ", " but ", " consistent with "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}
