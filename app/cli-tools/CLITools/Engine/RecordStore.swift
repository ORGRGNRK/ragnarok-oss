import Foundation

/// Where `save_record` writes. This is the pipeline's source of truth; the app backs it with
/// a SwiftData database (HistoryStore) and tests can swap in a fake.
@MainActor
protocol RecordStore {
    /// Saves a record of the given type and returns its ID, which later records can use as `parent`.
    func save(record type: String, parent: String?, fields: [String: String]) throws -> String
}

/// Reads the `Key: value` line protocol the pipeline's shell scripts print
/// (STATUS: OK, Tool: lsof, EXIT: 0, …).
struct KeyLines {
    let text: String

    /// The value after the first line that starts with `key:`.
    func value(_ key: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("\(key): ") {
            return String(line.dropFirst(key.count + 2))
        }
        return nil
    }

    /// Everything after a line that is exactly `key:`, e.g. the body under "Output:".
    func block(after key: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0 == "\(key):" }) else { return nil }
        return lines[(index + 1)...].joined(separator: "\n")
    }
}
