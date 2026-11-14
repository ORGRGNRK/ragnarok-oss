import Foundation

/// Append-only free-text memory note ("buyer haggled from 650 to 600", "AT&T unlocked it").
public struct MemoryNote: Codable, Equatable, Sendable {
    public var at: Date
    public var text: String
    public init(at: Date = Date(), text: String) { self.at = at; self.text = text }
}

public enum MemoryNotes {
    public struct EmptyNote: Error {}
    /// Returns notes + one new note (trimmed). Never edits or removes existing notes.
    public static func appending(_ notes: [MemoryNote]?, _ text: String, at: Date = Date()) throws -> [MemoryNote] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw EmptyNote() }
        return (notes ?? []) + [MemoryNote(at: at, text: t)]
    }
}

/// Dates typed on the command line: ISO 8601 with zone, or local "2026-10-16 19:30", "2026-10-16T19:30", "2026-10-16".
public enum CLIDate {
    public static func parse(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}
