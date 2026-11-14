import Foundation
import PhoneGraderCore

/// Manual, opt-in logging. The gateway atomically upserts the grade and its receipt.
enum GradeLogClient {
    static var destination: String { UserDefaults.standard.string(forKey: "gradeLogURL") ?? "(configure endpoint in Settings)" }
    @MainActor
    static func send(_ rec: HistoryRecord, persistRecordId: @MainActor (String) throws -> Void) async throws -> String {
        guard UserDefaults.standard.bool(forKey: "gradeLogEnabled") else { throw GradeLog.failure("Grade logging is disabled.") }
        guard rec.grade != nil else { throw GradeLog.failure("This record has no grade yet.") }
        guard let token = Keychain.get(.gradeLogToken) else { throw GradeLog.failure("No grade log token saved in Settings.") }
        // Separate identity from legacy Airtable ids. Persist before sending so lost replies retry the same row.
        let id = rec.gradeLogRecordId ?? UUID().uuidString.lowercased()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        let request = try GradeLog.request(endpoint: destination, token: token, identity: id, payload: enc.encode(rec))
        try persistRecordId(id)
        // No redirects: a misconfigured proxy must not move the private payload to another host.
        let session = URLSession(configuration: .ephemeral, delegate: NoGradeLogRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return try GradeLog.recordID(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, expected: id)
    }
}
private final class NoGradeLogRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
