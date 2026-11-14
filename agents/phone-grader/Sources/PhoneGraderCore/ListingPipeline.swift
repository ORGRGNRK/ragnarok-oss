import Foundation

/// Port of phone-grader-bot/listing-pipeline.js (evaluatePhoneAssessment and
/// helpers). The bot shells out to the two Python servers; here both are
/// called in-process (PriceEngine / ListingCopyGenerator).
public enum Checklist {
    public static let icloud = "Activation lock OFF / signed out of iCloud"
    public static let imei = "IMEI clean (checked against blacklist)"
    public static let battery = "Battery health"
    public static let originalScreen = "Screen is original / OEM"
    public static let rearGlassIntact = "Rear glass intact (not cracked)"

    /// scenes.js CHECKLIST_ITEMS, verbatim and in order.
    public static let items: [(label: String, isBattery: Bool)] = [
        (icloud, false),
        (imei, false),
        (battery, true),
        (originalScreen, false),
        (rearGlassIntact, false),
        ("All buttons + Face ID/Touch ID work", false),
        ("Touchscreen fully responsive (all corners)", false),
        ("Speakers, mic, cameras tested", false),
        ("Charges when plugged in", false),
    ]
    /// The five items the listing pipeline turns into verified facts.
    public static let required = [icloud, imei, battery, originalScreen, rearGlassIntact]
}

public struct ChecklistEntry: Codable, Equatable, Sendable, Hashable {
    public var label: String
    public var value: String   // "PASS" / "FAIL" / "87%"
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct VerifiedFacts: Equatable, Sendable, Codable {
    public var icloudClear: Bool?
    public var imeiClean: Bool?
    public var battery: Int?
    public var aftermarketScreen: Bool
    public var crackedBack: Bool
    public var failedChecks: [String]
}

public enum CarrierLock: String, CaseIterable, Codable, Sendable, Identifiable {
    case unlocked, att_clean, verizon_locked, tmobile_locked, other_locked, unknown
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .unlocked: return "Unlocked"
        case .att_clean: return "AT&T clean"
        case .verizon_locked: return "Verizon locked"
        case .tmobile_locked: return "T-Mobile locked"
        case .other_locked: return "Other locked"
        case .unknown: return "Unknown"
        }
    }
}

public struct AssessmentInput: Sendable {
    public var phoneModel: String
    public var storageGb: Int?
    public var carrierLock: String
    public var checklist: [ChecklistEntry]
    public var overallGrade: String
    public var concerns: [String]
    public var notes: String?
    public var askingPrice: Double?
    public init(phoneModel: String, storageGb: Int?, carrierLock: String, checklist: [ChecklistEntry],
                overallGrade: String, concerns: [String], notes: String?, askingPrice: Double?) {
        self.phoneModel = phoneModel; self.storageGb = storageGb; self.carrierLock = carrierLock
        self.checklist = checklist; self.overallGrade = overallGrade; self.concerns = concerns
        self.notes = notes; self.askingPrice = askingPrice
    }
}

public enum LoopStatus: String, Sendable, Codable { case BLOCKED, NEEDS_HUMAN_PRICE, READY }

public struct AssessmentResult: Sendable {
    public var model: String
    public var storageGb: Int?
    public var carrierLock: String
    public var verifiedFacts: VerifiedFacts
    public var priceGate: PriceResult
    public var listing: ListingCopy
    public var loopStatus: LoopStatus
    public var askingPrice: Int?
}

public enum PipelineError: Error, LocalizedError, Equatable {
    case modelRequired, unsupportedGrade(String), badAskingPrice
    public var errorDescription: String? {
        switch self {
        case .modelRequired: return "Phone model is required before pricing and listing."
        case .unsupportedGrade(let g): return "Unsupported overall grade: \(g.isEmpty ? "missing" : g)"
        case .badAskingPrice: return "asking price must be a whole-dollar amount from 1 to 100000"
        }
    }
}

public enum ListingPipeline {
    static func verifiedBoolean(_ v: String?) -> Bool? {
        if v == "PASS" { return true }
        if v == "FAIL" { return false }
        return nil
    }

    static func batteryValue(_ v: String?) -> Int? {
        guard let v else { return nil }
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("%") { s.removeLast() }
        // JS Number(): accepts "87", " 87 ", "87.0"; Number.isInteger + 0..100
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }       // Number("") === 0 in JS
        guard let d = Double(s), d == d.rounded(), d >= 0, d <= 100 else { return nil }
        return Int(d)
    }

    public static func normalizeModelAndStorage(_ phoneModel: String?, _ storageGb: Int?) -> (model: String, storage: Int) {
        let text = (phoneModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let re = try! NSRegularExpression(pattern: #"(?:^|\s)(\d{2,4})\s*(?:gb|g)\b"#, options: [.caseInsensitive])
        let ns = text as NSString
        let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        let storage: Int
        if let s = storageGb, s > 0 { storage = s }
        else if let m { storage = Int(ns.substring(with: m.range(at: 1))) ?? 0 }
        else { storage = 0 }
        var model = text
        if let m {
            model = ns.replacingCharacters(in: m.range, with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return (model, storage)
    }

    public static func deriveVerifiedFacts(_ checklist: [ChecklistEntry]) -> VerifiedFacts {
        func v(_ k: String) -> String? { checklist.first(where: { $0.label == k })?.value }
        let originalScreen = verifiedBoolean(v(Checklist.originalScreen))
        let rear = verifiedBoolean(v(Checklist.rearGlassIntact))
        let failed = checklist
            .filter { $0.value == "FAIL" && ![Checklist.icloud, Checklist.imei].contains($0.label) }
            .map { "Human check failed: \($0.label)" }
        return VerifiedFacts(icloudClear: verifiedBoolean(v(Checklist.icloud)),
                             imeiClean: verifiedBoolean(v(Checklist.imei)),
                             battery: batteryValue(v(Checklist.battery)),
                             aftermarketScreen: originalScreen == false,
                             crackedBack: rear == false,
                             failedChecks: failed)
    }

    public static func normalizeCarrierLock(_ value: String?) -> String {
        let c = (value ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["unlocked", "att_clean", "verizon_locked", "tmobile_locked", "other_locked"].contains(c) ? c : "unknown"
    }

    /// listing-pipeline.js priceLock(). DECISION: the bot passes "carrier_locked"
    /// / "att_clean", but atlas-ladder.json keys are SPACE-separated ("carrier
    /// locked", "att clean") per its own _KEY_FORMAT note, so the bot's value never
    /// matched exactly and fell through to the first row for that storage (often
    /// the UNLOCKED row) with a warning. The app passes the ladder's spelling.
    public static func priceLock(_ carrier: String) -> String {
        if carrier == "unlocked" { return "unlocked" }
        if carrier == "att_clean" { return "att clean" }
        if carrier.hasSuffix("_locked") { return "carrier locked" }
        return "unknown"
    }

    public static func evaluate(_ a: AssessmentInput, engine: PriceEngine,
                                today: String = PriceEngine.todayString(),
                                interpreter: ModelInterpreter? = nil) throws -> AssessmentResult {
        let (model, storage) = normalizeModelAndStorage(a.phoneModel, a.storageGb)
        if model.isEmpty { throw PipelineError.modelRequired }
        let grade = a.overallGrade.uppercased()
        guard ["A", "B", "C", "D", "F"].contains(grade) else { throw PipelineError.unsupportedGrade(grade) }

        var asking: Int?
        if let p = a.askingPrice {
            guard p == p.rounded(), p > 0, p <= 100000 else { throw PipelineError.badAskingPrice }
            asking = Int(p)
        }

        let facts = deriveVerifiedFacts(a.checklist)
        let carrier = normalizeCarrierLock(a.carrierLock)
        var concerns = a.concerns
        concerns += facts.failedChecks
        if let n = a.notes, !n.isEmpty { concerns.append("Buyer note: \(n)") }

        let gate = engine.getAtlasFloor(
            model: model, storage: storage, grade: grade, lock: priceLock(carrier),
            battery: facts.battery.map(String.init), imeiClean: facts.imeiClean,
            aftermarketScreen: facts.aftermarketScreen, crackedBack: facts.crackedBack,
            today: today, interpreter: interpreter)

        var listing = ListingCopyGenerator.generate(
            model: model, storage: storage, grade: grade,
            battery: facts.battery.map(String.init),
            icloudClear: facts.icloudClear, imeiClean: facts.imeiClean,
            carrierLock: carrier == "unknown" ? nil : carrier,
            concerns: concerns, priceFBM: asking)

        var blocking: [String] = []
        func add(_ s: String) { if !blocking.contains(s) { blocking.append(s) } }
        gate.blockingDisclosures.forEach(add)
        listing.blockingDisclosures.forEach(add)
        if facts.icloudClear == false { add("activation lock is still on") }
        if facts.imeiClean == false { add("IMEI is not clean") }
        if !listing.claimsVerified { add("iCloud and IMEI checks are required before listing") }
        if !listing.carrierVerified { add("carrier lock status and exact carrier must be verified before listing") }
        listing.blockingDisclosures = blocking

        let status: LoopStatus = !blocking.isEmpty ? .BLOCKED : (asking == nil ? .NEEDS_HUMAN_PRICE : .READY)
        return AssessmentResult(model: model, storageGb: storage == 0 ? nil : storage, carrierLock: carrier,
                                verifiedFacts: facts, priceGate: gate, listing: listing,
                                loopStatus: status, askingPrice: asking)
    }
}
