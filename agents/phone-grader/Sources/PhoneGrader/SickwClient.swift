import Foundation
import PhoneGraderCore

/// SICKW network calls. The API key is read from the Keychain at call time and is
/// never logged, printed, stored in history, or included in any error message.
enum SickwClient {
    enum Failure: Error, LocalizedError {
        case noKey, badIMEI(String), badService(String), network(String), http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "No SICKW API key saved. Paste it in Settings → SICKW IMEI checks (stored in your Keychain)."
            case .badIMEI(let m): return m
            case .badService(let s): return "SICKW service ID '\(s)' is invalid (numeric, 0–250)."
            case .network(let m): return "Couldn't reach sickw.com: \(m)"
            case .http(let c, let b): return "sickw.com returned HTTP \(c).\n\(b)"
            }
        }
    }

    static var key: String? { Keychain.get(.sickwAPIKey).flatMap { $0.isEmpty ? nil : $0 } }

    private static func get(_ url: URL, key: String) async throws -> String {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.setValue("PhoneGrader/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) }
        catch let e as URLError { throw Failure.network(Sickw.redact("\(e.code.rawValue) \(e.localizedDescription)", key: key)) }
        let body = Sickw.redact(String(data: data, encoding: .utf8) ?? "", key: key)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, body) }
        return body
    }

    /// One paid check. Validates the IMEI (15 digits + Luhn) before anything leaves the Mac.
    static func check(imei raw: String, service: String) async throws -> SickwResponse {
        let imei = IMEI.normalized(raw)
        if let p = IMEI.problem(imei) { throw Failure.badIMEI(p) }
        guard Sickw.validServiceId(service) else { throw Failure.badService(service) }
        guard let key else { throw Failure.noKey }
        return SickwResponse.parse(try await get(Sickw.checkURL(key: key, imei: imei, service: service), key: key))
    }

    /// Free: account balance (plain text).
    static func balance() async throws -> (Double?, String) {
        guard let key else { throw Failure.noKey }
        let t = try await get(Sickw.balanceURL(key: key), key: key)
        return (Sickw.parseBalance(t), t)
    }
}

extension AppState {
    var sickwService: SickwService {
        Sickw.service(sickwServiceId) ?? SickwService(id: sickwServiceId, name: "custom service \(sickwServiceId)", listPrice: "unknown", covers: "unknown")
    }

    /// Explicit, paid. Updates the checklist conservatively and saves a receipt on the record.
    @discardableResult
    func runImeiCheck(service: String? = nil) async -> ImeiCheckReceipt? {
        imeiCheckError = nil; imeiCheckMessage = nil
        let svc = service ?? sickwServiceId
        let imei = IMEI.normalized(imeiText)
        imeiChecking = true
        defer { imeiChecking = false }
        do {
            let r = try await SickwClient.check(imei: imei, service: svc)
            let v = SickwVerdict.from(r)
            let receipt = ImeiCheckReceipt(serviceId: svc, serviceName: Sickw.service(svc)?.name, imei: imei,
                                           checkedAt: Date(), response: r, verdict: v)
            imeiChecks.append(receipt)
            var msg: [String] = []
            if r.ok {
                let (changed, conflicts) = v.apply(to: &checklistValues)
                msg.append(changed.isEmpty ? "Checklist unchanged." : "Set from SICKW: " + changed.map { "\($0) = \(checklistValues[$0] ?? "")" }.joined(separator: "; "))
                msg += conflicts
            } else {
                imeiCheckError = "SICKW: \(r.errorMessage ?? "error") — checklist unchanged."
            }
            msg += v.notes
            imeiCheckMessage = msg.joined(separator: "\n")
            saveToHistory()
            return receipt
        } catch {
            imeiCheckError = error.localizedDescription
            return nil
        }
    }
}
