import Foundation

/// Transport contract for the private PostgreSQL gateway, independent of UI and Keychain.
public enum GradeLog {
    public static func request(endpoint: String, token: String, identity: String, payload: Data) throws -> URLRequest {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw failure("Set a valid HTTPS grade log endpoint in Settings.")
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), !identity.isEmpty else {
            throw failure("No valid grade log token or identity configured.")
        }
        var r = URLRequest(url: url.appendingPathComponent(identity))
        r.httpMethod = "PUT"; r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = payload
        return r
    }
    public static func recordID(data: Data, status: Int, expected: String) throws -> String {
        guard (200..<300).contains(status) else { throw failure("Grade log failed (HTTP \(status)); remote save is not confirmed. Retry is safe.") }
        struct Reply: Decodable { let id: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.id == expected else {
            throw failure("Grade log returned an invalid receipt. Retry is safe.")
        }
        return reply.id
    }
    public static func failure(_ message: String) -> NSError {
        NSError(domain: "GradeLog", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
