import Foundation

/// THE buyer-facing facts for one phone, built from a saved record (via ReceiptInput).
/// Listing text, the QR payload and the share photo all render from this — nothing else
/// formats model/storage/lock/battery/IMEI/iCloud/condition/disclosures for a buyer.
/// Never contains a letter grade, Atlas floor, max buy, costs or profit.
public struct PhoneFacts: Equatable, Sendable {
    public var model: String
    public var storageGb: Int?
    public var carrier: String            // label, e.g. "Unlocked"
    public var unlocked: Bool
    public var battery: Int?
    public var batteryCycles: Int?
    public var imei: String?
    public var imeiClean: Bool?
    public var icloudOff: Bool?
    public var condition: String
    /// Short plain condition word for the title ("Excellent", "Good", …) — mapped from the grade, never the grade itself.
    public var conditionWord: String?
    public var color: String?
    public var disclosures: [String]

    public init(_ i: ReceiptInput) {
        model = i.model.isEmpty ? "(model not set)" : i.model
        storageGb = i.storageGb
        carrier = i.carrier
        unlocked = i.carrier.lowercased() == "unlocked"
        battery = i.checklist.first { $0.label == Checklist.battery }.flatMap { Int($0.value.replacingOccurrences(of: "%", with: "")) }
        batteryCycles = i.batteryCycles
        imei = i.imei.flatMap { $0.isEmpty ? nil : $0 }
        func check(_ k: String) -> Bool? {
            switch i.checklist.first(where: { $0.label == k })?.value.uppercased() { case "PASS": return true; case "FAIL": return false; default: return nil }
        }
        let s = i.sickw.last
        imeiClean = check(Checklist.imei) ?? s?.imeiClean
        icloudOff = check(Checklist.icloud) ?? s?.icloudClear
        let notes = (i.grade?.categories ?? []).filter { $0.grade.uppercased() != "A" && !$0.notes.isEmpty }.map(\.notes)
        condition = i.grade.map { MarketplaceCopy.condition(grade: $0.overall_grade, notes: notes) } ?? "See photos for condition"
        conditionWord = i.grade.flatMap { PhoneFacts.conditionWords[$0.overall_grade.uppercased()] }
        color = i.color.flatMap { let c = $0.trimmingCharacters(in: .whitespaces); return c.isEmpty ? nil : c }
        var d = i.repairs?.disclosures ?? []
        if check(Checklist.originalScreen) == false { d.append("Screen is not the original Apple screen") }
        if let b = battery, b < 80 { d.append("Battery below 80% — iPhone will show a Service message") }
        if imeiClean == false { d.append("IMEI is NOT clean (blacklisted / reported)") }
        if icloudOff == false { d.append("Activation locked — for parts only") }
        disclosures = d
    }

    public var storageText: String? {
        storageGb.map { $0 >= 1024 && $0 % 1024 == 0 ? "\($0 / 1024)TB" : "\($0)GB" }
    }
    /// "iPhone 16 Pro 128GB Unlocked"
    public var headline: String { [model, storageText, unlocked ? "Unlocked" : nil].compactMap { $0 }.joined(separator: " ") }
    /// Grade → short buyer word for the title (matches MarketplaceCopy.plainCondition wording).
    public static let conditionWords: [String: String] = ["A": "Excellent", "B": "Good", "C": "Fair", "D": "Worn", "F": "For Parts"]
    public static let titleLimit = 80

    /// Marketplace title, search-first: model, storage, Unlocked/carrier, battery, condition word, color, iCloud Off.
    /// e.g. "iPhone 16 Pro 128GB Unlocked - 91% Battery - Excellent - Black Titanium - iCloud Off"
    /// Under `titleLimit` chars: optional parts drop lowest-priority first. Never IMEI, prices, Atlas data or grades.
    /// Unknown fields are omitted, not shown as placeholders.
    public var title: String {
        let known = !model.isEmpty && model != "(model not set)"
        var head = [known ? model : "iPhone", storageText].compactMap { $0 }
        let c = carrier.trimmingCharacters(in: .whitespaces)
        if unlocked { head.append("Unlocked") }
        else if !c.isEmpty, !["unknown", "not checked"].contains(c.lowercased()) { head.append(c) }
        var core = [head.joined(separator: " ")]
        if icloudOff == false { core.append("PARTS ONLY") }              // always kept: buyer safety
        // Optional parts, highest priority first.
        var opt: [String] = []
        if let b = battery { opt.append("\(b)% Battery") }
        if let w = conditionWord, icloudOff != false || w != "For Parts" { opt.append(w) }
        if let col = color { opt.append(col) }
        if icloudOff == true { opt.append("iCloud Off") }
        while !opt.isEmpty, (core + opt).joined(separator: " - ").count > PhoneFacts.titleLimit { opt.removeLast() }
        if (core + opt).joined(separator: " - ").count > PhoneFacts.titleLimit {   // only the headline itself is too long
            let tail = core.dropFirst().map { " - " + $0 }.joined()
            core[0] = String(core[0].prefix(max(0, PhoneFacts.titleLimit - tail.count))).trimmingCharacters(in: .whitespaces)
        }
        return (core + opt).joined(separator: " - ")
    }
    public var batteryText: String? {
        battery.map { "Battery health \($0)%" + (batteryCycles.map { " · \($0) cycles" } ?? "") }
    }
    public var lockText: String {
        unlocked ? "Unlocked — works on any carrier" : (carrier.lowercased() == "unknown" ? "Carrier lock not checked" : carrier)
    }
    public var imeiText: String? {
        imeiClean.map { $0 ? "IMEI clean (blacklist checked)" : "IMEI NOT clean" }
    }
    public var icloudText: String? { icloudOff.map { $0 ? "iCloud / Activation Lock off" : "Activation Lock ON" } }

    /// Fact lines (no model line). `imeiNumber`: include the IMEI digits (masked if `maskIMEI`).
    public func lines(emoji: Bool = false, imeiNumber: Bool = false, maskIMEI: Bool = false) -> [String] {
        func e(_ s: String, _ ok: Bool? = true) -> String { emoji ? "\(ok == false ? "⚠️" : "✅") \(s)" : s }
        var L: [String] = []
        L.append(e(lockText, unlocked ? true : nil).replacingOccurrences(of: "✅ Carrier lock not checked", with: "• Carrier lock not checked"))
        if let b = batteryText { L.append(emoji ? "🔋 \(b)" : b) }
        if let t = imeiText { L.append(e(t, imeiClean)) }
        if imeiNumber, let m = imei { L.append("IMEI: \(maskIMEI ? Receipt.mask(m) : m)") }
        if let t = icloudText { L.append(e(t, icloudOff)) }
        L.append(emoji ? "✨ \(condition)" : "Condition: \(condition)")
        L.append(contentsOf: disclosures.map { emoji ? "⚠️ \($0)" : "Disclosure: \($0)" })
        return L
    }

    /// Facebook Marketplace text.
    public func listing(location: String, concerns: [String] = []) -> (title: String, description: String) {
        var L = ["📱 \(headline)"] + lines(emoji: true)
        let c = concerns.map(MarketplaceCopy.clean).filter { !$0.isEmpty }
        if !c.isEmpty { L.append("📋 Worth knowing:"); L += c.map { "   • " + $0.prefix(1).uppercased() + $0.dropFirst() } }
        L.append("📍 \(location) — local pickup")
        L.append("💬 Message for more photos or a video of it powering on")
        return (title, L.joined(separator: "\n"))
    }

    /// Small QR payload for the share photo: the facts only (no grade, no prices).
    public func qrText(recordId: Int, maskIMEI: Bool) -> String {
        (["PhoneGrader #\(recordId)", headline] + lines(imeiNumber: true, maskIMEI: maskIMEI)).joined(separator: "\n")
    }
}
