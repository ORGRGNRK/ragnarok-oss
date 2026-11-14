import Darwin
import Foundation
import OSLog

/// App-level errors are kept locally, scrubbed before both storage and system logging.
/// The file is readable through the Timeline feed and `bin/ragnarok-ai-log app-errors`.
enum AppLog {
    static let path = NSHomeDirectory() + "/.ragnarok/ragnarok-app-errors.jsonl"
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.rgnrk.heimdall", category: "app")
    private static let maxBytes: UInt64 = 1_000_000
    private static let processSession = UUID().uuidString

    /// Attribution is supplied by the launcher, never inferred from the shared OS login.
    /// These fields are diagnostic labels, not authenticated identities.
    static func attribution(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        func field(_ key: String, fallback: String = "Unverified") -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !["unknown", "unverified"].contains(value.lowercased()) else { return fallback }
            return Scrub.clean(value).oneLine(120)
        }
        return ["os_user": Scrub.clean(NSUserName()).oneLine(120),
                "actor": field("RAGNAROK_ACTOR"),
                "run_id": field("RAGNAROK_RUN_ID", fallback: field("RAGNAROK_AGENT_RUN")),
                "origin": field("RAGNAROK_ORIGIN", fallback: "app"),
                "incident_id": field("RAGNAROK_INCIDENT_ID"),
                "process_session": processSession]
    }

    static func error(_ area: String, _ error: Error, context: String? = nil) {
        let e = error as NSError
        record(area, message: [context, e.localizedDescription].compactMap { $0 }.joined(separator: ": "),
               domain: e.domain, code: e.code)
    }

    static func error(_ area: String, message: String, domain: String? = nil, code: Int? = nil) {
        record(area, message: message, domain: domain, code: code)
    }

    private static func record(_ area: String, message: String, domain: String? = nil, code: Int? = nil) {
        let safeArea = Scrub.clean(area).oneLine(80)
        let safeMessage = Scrub.clean(message).oneLine(1200)
        var row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "level": "error",
                                  "area": safeArea, "message": safeMessage]
        row["schema_version"] = 2
        for (key, value) in attribution() { row[key] = value }
        if let url = Bundle.main.url(forResource: "commit", withExtension: nil),
           let build = try? String(contentsOf: url, encoding: .utf8) {
            row["build"] = Scrub.clean(build).oneLine(80)
        } else { row["build"] = "Unverified" }
        if let domain { row["domain"] = Scrub.clean(domain).oneLine(120) }
        if let code { row["code"] = code }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        var line = data; line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        append(line)
        logger.error("\(safeArea, privacy: .public): \(safeMessage, privacy: .public)")
    }

    private static func append(_ line: Data) {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
               size + UInt64(line.count) > maxBytes {
                let previous = path + ".1"
                try? FileManager.default.removeItem(atPath: previous)
                try? FileManager.default.moveItem(atPath: path, toPath: previous)
                _ = chmod(previous, mode_t(S_IRUSR | S_IWUSR))
            }
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
            guard fd >= 0 else { return }
            defer { _ = close(fd) }
            _ = fchmod(fd, mode_t(S_IRUSR | S_IWUSR))
            line.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, base.advanced(by: offset), buffer.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        } catch {
            // Avoid recursively logging a failure to write the error log.
            logger.error("could not append app error log")
        }
    }

    static func uncaughtException(_ exception: NSException) {
        error("uncaught-exception", message: exception.reason ?? exception.description,
              domain: exception.name.rawValue)
    }
}
