import Foundation

/// Port of resale-op-mcp/copy-mcp/server.py `generate_listing_copy`.
/// NEVER ASSERT WHAT NOBODY VERIFIED. Every claim is tri-state:
///   nil   -> not checked: line OMITTED, no claim either way
///   true  -> human verified it passed: claim it
///   false -> human verified it FAILED: disclose it, suppress contradicting claims
public struct ListingCopy: Equatable, Sendable, Codable {
    public var title: String
    public var description: String
    public var keywords: [String]
    public var grade: String
    public var suggestedPrice: Int?
    public var omittedClaims: [String]
    public var claimsVerified: Bool
    public var carrierVerified: Bool
    public var blockingDisclosures: [String]
}

public enum ListingCopyGenerator {
    public static let gradeBlurb: [String: String] = [
        "A": "Excellent condition",
        "B": "Good condition, light signs of use",
        "C": "Fair condition, visible wear",
        "D": "Rough condition, works but cosmetically poor",
        "F": "For parts / not fully functional",
    ]
    /// Pickup place for listings: PICKUP_CITY in ~/.ragnarok/local.conf, else a placeholder to set in Settings.
    public static var defaultLocation: String { LocalPlace.city }

    /// Accepts 87, "87", or "87%". Returns 0-100, or nil if unusable.
    public static func fmtBattery(_ battery: String?) -> Int? {
        guard let v = pyIntPercent(battery) else { return nil }
        return (0...100).contains(v) ? v : nil
    }

    public static func generate(
        model: String,
        storage: Int = 0,
        grade: String = "B",
        battery: String? = nil,
        icloudClear: Bool? = nil,
        imeiClean: Bool? = nil,
        carrierLock: String? = nil,
        defects: [String] = [],
        concerns: [String] = [],
        priceFBM: Int? = nil,
        location: String = defaultLocation
    ) -> ListingCopy {
        var grade = grade.trimmingCharacters(in: .whitespaces).uppercased()
        if grade.isEmpty { grade = "B" }
        if gradeBlurb[grade] == nil { grade = "B" }

        let batteryVal = fmtBattery(battery)
        let isAirpods = model.lowercased().contains("airpod")
        let storageStr = storage != 0 ? " \(storage)GB" : ""
        var omitted: [String] = []

        // ---- Title: each fragment must be earned.
        var titleBits = ["Grade \(grade)", "\(model)\(storageStr)"]
        if let b = batteryVal { titleBits.append("\(b)% Battery") } else { omitted.append("battery health (not provided)") }

        if icloudClear == true { titleBits.append("iCloud Clear") }
        else if icloudClear == false { titleBits.append("ACTIVATION LOCKED - PARTS ONLY") }
        else { omitted.append("iCloud / activation lock status (not checked)") }

        if grade == "F" && icloudClear != false { titleBits.append("For Parts / Repair") }

        let c = (carrierLock ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let carrier: String? = c.isEmpty ? nil : c
        let carrierTitles = [
            "verizon_locked": "Verizon Locked",
            "tmobile_locked": "T-Mobile Locked",
            "att_clean": "AT&T",
            "other_locked": "Carrier Locked",
        ]
        if let carrier, let t = carrierTitles[carrier] { titleBits.append(t) }
        let title = titleBits.joined(separator: " - ")

        // ---- Description
        var lines: [String] = []
        if icloudClear == false {
            lines.append("⚠️ ACTIVATION LOCKED — selling for PARTS ONLY. Cannot be activated.")
        } else if icloudClear == true {
            lines.append("✅ Activation lock OFF — signed out of iCloud, ready to activate")
        }
        if imeiClean == true { lines.append("✅ IMEI checked against blacklist — clean") }
        else if imeiClean == false { lines.append("⚠️ IMEI is NOT clean (bad ESN / reported) — disclosed up front") }
        else { omitted.append("IMEI / blacklist status (not checked)") }

        let carrierLines = [
            "unlocked": "✅ Carrier unlocked — no SIM restrictions reported",
            "att_clean": "📶 Carrier: AT&T — clean status verified",
            "verizon_locked": "⚠️ Carrier locked to Verizon — disclosed up front",
            "tmobile_locked": "⚠️ Carrier locked to T-Mobile — disclosed up front",
            "other_locked": "⚠️ Carrier locked — exact carrier still needs to be named",
        ]
        if let carrier, let l = carrierLines[carrier] { lines.append(l) }
        else { omitted.append("carrier lock / SIM restriction status (not checked)") }

        lines.append("\(isAirpods ? "🎧 Model" : "📱 Model"): \(model)\(storageStr)")
        if let b = batteryVal {
            let warn = b < 80 ? "  (below 80% — will show a Service warning)" : ""
            lines.append("🔋 Battery Health: \(b)%\(warn)")
        }
        lines.append("✨ Grade \(grade) — \(gradeBlurb[grade]!)")
        if !defects.isEmpty { lines.append("🔍 Noted: " + defects.joined(separator: ", ")) }
        if !concerns.isEmpty {
            lines.append("📋 Called out during grading:")
            lines.append(contentsOf: concerns.map { "   • \($0)" })
        }
        omitted.append("functional test claims (Face ID/cameras/speakers) — not tested by grader")
        lines.append("📍 \(location) — local pickup")
        lines.append("💬 Message for more photos or a video of it powering on")
        if let p = priceFBM, p != 0 { lines.append("\nPriced at $\(p) from recent sold comps.") }
        let description = lines.joined(separator: "\n")

        // ---- Keywords
        var keywords = [model, "Grade \(grade)", location]
        if storage != 0 { keywords.append("\(storage)GB") }
        if let b = batteryVal { keywords.append("\(b)% battery") }
        if icloudClear == true { keywords.append("iCloud clear") }
        if icloudClear == false { keywords.append("parts only") }

        var blocking: [String] = []
        if icloudClear == false { blocking.append("activation locked — parts only, cannot be activated") }
        if imeiClean == false { blocking.append("IMEI not clean (bad ESN / reported)") }
        if grade == "F" { blocking.append("grade F — for parts / not fully functional") }
        if carrier == "other_locked" { blocking.append("carrier locked but exact carrier was not recorded") }

        return ListingCopy(
            title: title, description: description, keywords: keywords, grade: grade,
            suggestedPrice: (priceFBM ?? 0) != 0 ? priceFBM : nil,
            omittedClaims: omitted,
            claimsVerified: icloudClear != nil && imeiClean != nil,
            carrierVerified: carrier.map { carrierLines[$0] != nil && $0 != "other_locked" } ?? false,
            blockingDisclosures: blocking)
    }
}


/// Where the seller is: PICKUP_CITY / PICKUP_ZIP in ~/.ragnarok/local.conf (KEY=value, read only, never run).
public enum LocalPlace {
    static let conf: [String: String] = {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ragnarok/local.conf")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] = v
        }
        return out
    }()
    public static var city: String { conf["PICKUP_CITY"].flatMap { $0.isEmpty || $0.count > 60 ? nil : $0 } ?? "Your City, ST" }
    public static var zip: String { conf["PICKUP_ZIP"].flatMap { $0.allSatisfy(\.isNumber) && $0.count == 5 ? $0 : nil } ?? "" }
}
