import Foundation

/// One thing that happened: an AI said something, ran a tool, ran a command, or the OS saw it.
struct Event: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let actor: String      // claude, argon, grok, codex, alexus, ai-admin, owner, os
    let host: String       // mac, alexus
    let source: String     // which feed it came from
    let kind: String       // said, prompt, tool, result, command, audit, change
    let title: String      // one line
    let body: String       // everything, for reading
    let session: String
}

enum Actors {
    /// Map whatever a log calls someone to one short name.
    static func normalize(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("claude") { return "claude" }
        if s.contains("argon") || s.contains("castor") || s.contains("gemini") || s.contains("antigravity") { return "argon" }
        if s.contains("grok") { return "grok" }
        if s.contains("codex") { return "codex" }
        if s.contains("alexus") && !s.contains("@alexus") { return "alexus" }
        if s.contains("ai-admin") { return "ai-admin" }
        if s == "owner" || s == "user" || s == "human-terminal" || s == ownerLogin
            || s == LocalConfig.current.alexusUser.lowercased() || s == LocalConfig.owner.lowercased() { return "owner" }
        return s.isEmpty ? "unknown" : s
    }

    /// The Mac login (lowercased): the owner's own account.
    static let ownerLogin = NSUserName().lowercased()

    /// auditd login uid -> account (Alexus, set up 2026-10-31).
    static let auid: [String: String] = [
        "1000": "owner", "1001": "claude", "1002": "argon", "1003": "grok", "1004": "codex", "1005": "ai-admin",
    ]

    static let order = ["owner", "claude", "argon", "grok", "codex", "gemini", "alexus", "ai-admin", "heimdall", "os", "unknown"]
}

enum Time {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) ?? isoNoFrac.date(from: s) { return d }
        // microseconds (grok: 2026-11-01T17:35:18.687029Z): keep 3 fraction digits
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let frac = s[s.index(after: dot)..<end].prefix(3)
            return iso.date(from: String(s[..<dot]) + "." + frac + String(s[end...]))
        }
        return nil
    }
}

extension String {
    func oneLine(_ max: Int = 160) -> String {
        let flat = self.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}
