import Foundation

// SICKW (sickw.com) IMEI checks — pure parts: validation, URLs, response parsing,
// and the conservative mapping onto the human checklist. No network here.
//
// API (public PHP sample https://sickw.com/sample.txt; endpoint/format/error-code docs
// transcribed from sickw.com's login-only API page in github.com/HOPLAtools/sickw):
//   GET https://sickw.com/api.php?format=json&key=KEY&imei=IMEI&service=ID
//   GET https://sickw.com/api.php?action=balance&key=KEY          -> plain text "878.75"
//   format=json -> {"result":"A: b<br>C: d","imei":…,"balance":…,"price":…,"id":…,"status":"success"|"error"}

public enum IMEI {
    public static func digits(_ s: String) -> String { s.filter(\.isNumber) }
    public static func luhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue!
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
    /// nil = valid; otherwise the reason. Requires exactly 15 digits + Luhn (checked BEFORE any paid call).
    public static func problem(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard !t.isEmpty else { return "Enter the IMEI (dial *#06# or Settings → General → About)." }
        guard t.allSatisfy(\.isNumber) else { return "IMEI must be digits only." }
        guard t.count == 15 else { return "IMEI must be exactly 15 digits (got \(t.count))." }
        guard luhnValid(t) else { return "That IMEI fails the Luhn check digit — re-read it; no check was run." }
        return nil
    }
    public static func normalized(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SickwService: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var listPrice: String       // as shown on sickw.com/sample.txt (your account tier may differ)
    public var covers: String
    public init(id: String, name: String, listPrice: String, covers: String) {
        self.id = id; self.name = name; self.listPrice = listPrice; self.covers = covers
    }
}

public enum Sickw {
    public static let base = "https://sickw.com/api.php"
    public static let defaultServiceId = "61"
    /// IDs/names/prices from https://sickw.com/sample.txt (Oct 2026). Configurable — SICKW can change them.
    public static let knownServices: [SickwService] = [
        .init(id: "61", name: "iPHONE CARRIER & FMI & BLACKLIST", listPrice: "$0.13", covers: "iCloud/FMI + blacklist + carrier/SIM-lock"),
        .init(id: "78", name: "iPHONE CARRIER & FMI", listPrice: "$0.08", covers: "iCloud/FMI + carrier/SIM-lock (no blacklist)"),
        .init(id: "3", name: "iCLOUD ON/OFF", listPrice: "$0.02", covers: "iCloud/FMI on/off only"),
        .init(id: "4", name: "iCLOUD CLEAN/LOST", listPrice: "$0.03", covers: "iCloud clean/lost status"),
        .init(id: "6", name: "GSMA BLACKLIST STATUS - PRO", listPrice: "$0.12", covers: "GSMA blacklist (all brands)"),
        .init(id: "54", name: "WW BLACKLIST STATUS", listPrice: "$0.04", covers: "worldwide blacklist"),
        .init(id: "103", name: "iPHONE CARRIER", listPrice: "$0.06", covers: "carrier/SIM-lock only"),
        .init(id: "8", name: "iPHONE SIM-LOCK", listPrice: "$0.025", covers: "SIM-lock only"),
    ]
    public static func service(_ id: String) -> SickwService? { knownServices.first { $0.id == id } }

    public static func validServiceId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 4, id.allSatisfy(\.isNumber), let n = Int(id) else { return false }
        return n <= 250
    }

    static func url(_ items: [URLQueryItem]) -> URL {
        var c = URLComponents(string: base)!; c.queryItems = items; return c.url!
    }
    public static func checkURL(key: String, imei: String, service: String) -> URL {
        url([.init(name: "format", value: "json"), .init(name: "key", value: key),
             .init(name: "imei", value: imei), .init(name: "service", value: service)])
    }
    public static func balanceURL(key: String) -> URL {
        url([.init(name: "action", value: "balance"), .init(name: "key", value: key)])
    }

    /// Plain-text balance -> number (nil if it's an error message).
    public static func parseBalance(_ text: String) -> Double? {
        let t = stripTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
    }

    public static let errorCodes: [String: String] = [
        "E01": "IMEI failed the Luhn checksum", "E02": "IMEI/SN invalid format or length",
        "R01": "Service offline or IMEI/SN not found", "B01": "Insufficient SICKW balance",
        "S01": "Service ID doesn't exist or is inactive", "S02": "Service ID doesn't exist or is inactive",
        "S03": "Service is not instant", "A01": "Invalid API key", "A02": "Invalid API key", "A03": "Invalid API key",
    ]

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&nbsp;", " "), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    /// Remove the key from anything we might show or store.
    public static func redact(_ s: String, key: String?) -> String {
        guard let k = key, !k.isEmpty else { return s }
        return s.replacingOccurrences(of: k, with: "•••")
    }
}

public struct SickwResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var fields: [Field]
    public var text: String            // result as plain text lines
    public var errorCode: String?
    public var errorMessage: String?
    public var orderId: String?
    public var price: String?
    public var balance: String?
    public var raw: String
    public struct Field: Codable, Equatable, Sendable { public var key: String; public var value: String }

    public func value(_ keyContains: String) -> String? {
        fields.first { $0.key.lowercased().contains(keyContains.lowercased()) }?.value
    }

    /// Accepts format=json (result = "<br>"-separated string), format=beta (result = object), or html/plain text.
    public static func parse(_ raw: String) -> SickwResponse {
        var resultText = raw, status: String?, order: String?, price: String?, bal: String?
        var fields: [Field] = []
        if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            status = o["status"] as? String
            order = (o["id"] as? String) ?? (o["id"] as? NSNumber)?.stringValue
            price = (o["price"] as? String) ?? (o["price"] as? NSNumber)?.stringValue
            bal = (o["balance"] as? String) ?? (o["balance"] as? NSNumber)?.stringValue
            if let r = o["result"] as? String { resultText = r }
            else if let r = o["result"] as? [String: Any] {
                fields = r.keys.sorted().map { Field(key: $0, value: "\(r[$0]!)") }
                resultText = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            } else { resultText = "" }
        }
        let text = Sickw.stripTags(resultText).trimmingCharacters(in: .whitespacesAndNewlines)
        if fields.isEmpty {
            for line in text.split(separator: "\n") {
                guard let c = line.firstIndex(of: ":") else { continue }
                let k = line[..<c].trimmingCharacters(in: .whitespaces), v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty, !v.isEmpty { fields.append(Field(key: k, value: v)) }
            }
        }
        let code = text.range(of: #"Error ([A-Z]\d\d)"#, options: .regularExpression)
            .map { String(text[$0].dropFirst(6)) }
        let ok = code == nil && (status.map { $0.lowercased() == "success" } ?? !fields.isEmpty)
        let msg: String? = ok ? nil : (code.flatMap { Sickw.errorCodes[$0] }.map { "\(code!): \($0)" } ?? (text.isEmpty ? "Empty/unknown response" : text))
        return SickwResponse(ok: ok, fields: fields, text: text, errorCode: code, errorMessage: msg,
                             orderId: order, price: price, balance: bal, raw: raw)
    }
}

/// What a SICKW result proves. nil = not covered / unclear -> the checklist item stays unanswered.
public struct SickwVerdict: Codable, Equatable, Sendable {
    public var icloudClear: Bool?      // true = FMI/iCloud OFF (and not LOST); false = ON or LOST
    public var imeiClean: Bool?        // true = blacklist CLEAN; false = blacklisted / lost / stolen / blocked
    public var simLock: String?
    public var carrier: String?
    public var notes: [String]

    public static func from(_ r: SickwResponse) -> SickwVerdict {
        var v = SickwVerdict(icloudClear: nil, imeiClean: nil, simLock: nil, carrier: nil, notes: [])
        guard r.ok else { v.notes.append("SICKW returned an error — nothing set."); return v }
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).uppercased() }

        // iCloud / Find My
        var fmiOn: [Bool] = [], lost = false
        for f in r.fields {
            let k = f.key.lowercased(), val = norm(f.value)
            if k.contains("find my") || k.contains("icloud lock") || k == "fmi" || k.contains("fmi status") || k.contains("fmip") {
                if val.hasPrefix("OFF") { fmiOn.append(false) }
                else if val.hasPrefix("ON") { fmiOn.append(true) }
                else if val.contains("LOST") { lost = true }
                else { v.notes.append("Unclear iCloud value '\(f.value)' — left unanswered.") }
            }
            if k.contains("icloud status") {
                if val.contains("LOST") || val.contains("STOLEN") { lost = true }
                else if !val.hasPrefix("CLEAN") { v.notes.append("Unclear iCloud status '\(f.value)'.") }
            }
        }
        if lost || fmiOn.contains(true) { v.icloudClear = false }
        else if !fmiOn.isEmpty && fmiOn.allSatisfy({ !$0 }) { v.icloudClear = true }

        // Blacklist
        var clean = false, bad = false
        for f in r.fields {
            let k = f.key.lowercased(), val = norm(f.value)
            if k.contains("blacklist status") || k.contains("gsma") {
                if val.hasPrefix("CLEAN") { clean = true }
                else if ["BLACKLIST", "BLOCK", "LOST", "STOLEN", "BARRED"].contains(where: val.contains) { bad = true }
                else { v.notes.append("Unclear blacklist value '\(f.value)' — left unanswered.") }
            }
            if k.contains("esn status") {   // carrier-specific (Verizon / T-Mobile …): bad is bad; clean is NOT a full blacklist pass
                if ["BLACKLIST", "BLOCK", "LOST", "STOLEN", "BARRED"].contains(where: val.contains) { bad = true }
                else if val.hasPrefix("CLEAN") { v.notes.append("Carrier ESN status clean (one carrier only) — not treated as a full blacklist pass.") }
            }
        }
        if bad { v.imeiClean = false } else if clean { v.imeiClean = true }

        v.simLock = r.value("sim-lock")
        v.carrier = r.value("locked carrier")
        if v.icloudClear == nil { v.notes.append("No clear iCloud/FMI result in this service — iCloud left unanswered.") }
        if v.imeiClean == nil { v.notes.append("No clear blacklist result in this service — IMEI left unanswered.") }
        return v
    }

    /// Apply to checklist values (label -> "PASS"/"FAIL"). A FAIL always wins; a PASS never overwrites a human FAIL.
    /// Returns the labels changed and any conflicts.
    public func apply(to values: inout [String: String]) -> (changed: [String], conflicts: [String]) {
        var changed: [String] = [], conflicts: [String] = []
        for (label, verdict) in [(Checklist.icloud, icloudClear), (Checklist.imei, imeiClean)] {
            guard let ok = verdict else { continue }
            let cur = values[label]
            if ok {
                if cur == "FAIL" { conflicts.append("\(label): you marked FAIL, SICKW says clear — kept your FAIL."); continue }
                if cur != "PASS" { values[label] = "PASS"; changed.append(label) }
            } else {
                if cur == "PASS" { conflicts.append("\(label): you marked PASS, SICKW says NOT clear — set to FAIL.") }
                if cur != "FAIL" { values[label] = "FAIL"; changed.append(label) }
            }
        }
        return (changed, conflicts)
    }
}

/// Receipt stored on the grade record.
public struct ImeiCheckReceipt: Codable, Equatable, Sendable {
    public var source: String          // "SICKW"
    public var serviceId: String
    public var serviceName: String?
    public var imei: String
    public var checkedAt: Date
    public var orderId: String?
    public var price: String?
    public var balanceAfter: String?
    public var ok: Bool
    public var icloudClear: Bool?
    public var imeiClean: Bool?
    public var simLock: String?
    public var raw: String             // full response (the key is never part of it)
    public init(source: String = "SICKW", serviceId: String, serviceName: String?, imei: String, checkedAt: Date,
                response r: SickwResponse, verdict v: SickwVerdict) {
        self.source = source; self.serviceId = serviceId; self.serviceName = serviceName; self.imei = imei
        self.checkedAt = checkedAt; orderId = r.orderId; price = r.price; balanceAfter = r.balance; ok = r.ok
        icloudClear = v.icloudClear; imeiClean = v.imeiClean; simLock = v.simLock; raw = r.raw
    }
}
