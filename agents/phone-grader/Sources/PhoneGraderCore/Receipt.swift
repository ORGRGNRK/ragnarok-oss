import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// QR "receipt": compact plain text encoded straight into a QR code, so any phone
// camera shows it with no app, network or server. Contains grading facts only —
// NEVER Atlas floor / buy prices, max buy, profit, raw API responses, IPs or keys.

public struct ReceiptInput: Sendable {
    public var recordId: Int
    public var date: Date
    public var model: String
    public var storageGb: Int?
    public var color: String?
    public var carrier: String            // label, e.g. "Unlocked"
    public var imei: String?
    public var serial: String?
    public var grade: GradeResult?
    public var checklist: [ChecklistEntry]
    public var sickw: [ImeiCheckReceipt]
    public var backend: String?
    public var listingPrice: Int?
    /// Parts used (types only — never their cost). Aftermarket back glass adds a disclosure line.
    public var repairs: RepairParts?
    public var batteryCycles: Int?
    public init(recordId: Int, date: Date, model: String, storageGb: Int?, color: String? = nil, carrier: String,
                imei: String?, serial: String?, grade: GradeResult?, checklist: [ChecklistEntry],
                sickw: [ImeiCheckReceipt] = [], backend: String?, listingPrice: Int?, repairs: RepairParts? = nil, batteryCycles: Int? = nil) {
        self.recordId = recordId; self.date = date; self.model = model; self.storageGb = storageGb; self.color = color
        self.carrier = carrier; self.imei = imei; self.serial = serial; self.grade = grade; self.checklist = checklist
        self.sickw = sickw; self.backend = backend; self.listingPrice = listingPrice
        self.repairs = repairs; self.batteryCycles = batteryCycles
    }
}

public struct ReceiptOptions: Sendable, Equatable {
    public var maskIMEI: Bool
    public var includeListingPrice: Bool
    public var maxChars: Int
    public init(maskIMEI: Bool = false, includeListingPrice: Bool = true, maxChars: Int = 1500) {
        self.maskIMEI = maskIMEI; self.includeListingPrice = includeListingPrice; self.maxChars = maxChars
    }
}

public enum Receipt {
    static let checkShort: [String: String] = [
        Checklist.icloud: "iCloud/Activation lock off", Checklist.imei: "IMEI clean",
        Checklist.originalScreen: "Original screen", Checklist.rearGlassIntact: "Rear glass intact",
        "All buttons + Face ID/Touch ID work": "Buttons + Face/Touch ID",
        "Touchscreen fully responsive (all corners)": "Touchscreen", "Speakers, mic, cameras tested": "Speakers/mic/cameras",
        "Charges when plugged in": "Charging",
    ]

    public static func mask(_ s: String) -> String { s.count <= 4 ? s : String(repeating: "*", count: s.count - 4) + s.suffix(4) }

    static func ptDate(_ d: Date, time: Bool = true) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles"); f.dateFormat = time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: d) + (time ? " PT" : "")
    }

    /// Strip anything that looks like an IPv4 address or a long key-like token (defense in depth).
    static func scrub(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\b\d{1,3}(\.\d{1,3}){3}\b"#, with: "[ip]", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(sk-[A-Za-z0-9_-]{8,}|pat[A-Za-z0-9.]{14,}|[A-Z0-9]{3}(-[A-Z0-9]{3}){7})\b"#, with: "[redacted]", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)https?://\S+"#, with: "[link]", options: .regularExpression)
        return t.replacingOccurrences(of: "\n", with: " ")
    }
    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    /// Build the text. Optional sections are trimmed (in this order) until it fits `maxChars`:
    /// per-area notes → concerns → summary → unanswered checklist lines → backend.
    public static func text(_ i: ReceiptInput, _ o: ReceiptOptions = ReceiptOptions()) -> String {
        for level in 0...5 {
            let t = build(i, o, trim: level)
            if t.count <= o.maxChars { return t }
        }
        return String(build(i, o, trim: 5).prefix(o.maxChars))
    }

    static func build(_ i: ReceiptInput, _ o: ReceiptOptions, trim: Int) -> String {
        var L: [String] = ["PhoneGrader receipt", "Record #\(i.recordId) - \(ptDate(i.date))", ""]
        // Buyer-facing facts come from PhoneFacts (shared with Listing text and the share photo).
        let facts = PhoneFacts(i)
        L.append(facts.headline + ((i.color ?? "").isEmpty ? "" : " \(i.color!)"))
        if !facts.unlocked { L.append("Carrier/lock: \(i.carrier)") }
        L += facts.lines(imeiNumber: true, maskIMEI: o.maskIMEI).filter { !$0.hasPrefix("Condition:") }
        if let s = i.serial, !s.isEmpty { L.append("Serial: \(o.maskIMEI ? mask(s) : s)") }
        if let g = i.grade {
            L.append(""); L.append("GRADE \(g.overall_grade)")
            for c in g.categories {
                L.append(trim >= 1 || c.notes.isEmpty ? "  \(c.grade) \(c.name)" : "  \(c.grade) \(c.name): \(clip(scrub(c.notes), 70))")
            }
            if trim < 2, !g.concerns.isEmpty { L.append("Concerns: " + g.concerns.prefix(3).map { clip(scrub($0), 90) }.joined(separator: "; ")) }
            if trim < 3, !g.summary.isEmpty { L.append("Summary: \(clip(scrub(g.summary), 200))") }
        } else { L.append(""); L.append("GRADE: not graded") }
        L.append(""); L.append("Checklist (human-verified):")
        let inFacts: Set<String> = [Checklist.icloud, Checklist.imei]
        for item in Checklist.items where !item.isBattery && !inFacts.contains(item.label) {
            let v = i.checklist.first(where: { $0.label == item.label })?.value
            let word = v == "PASS" ? "Pass" : v == "FAIL" ? "FAIL" : "unanswered"
            if word == "unanswered" && trim >= 4 { continue }
            L.append("  \(word) - \(checkShort[item.label] ?? item.label)")
        }
        if let s = i.sickw.last {
            L.append("")
            func yn(_ b: Bool?, _ y: String, _ n: String) -> String { b.map { $0 ? y : n } ?? "unclear" }
            L.append("SICKW IMEI check \(ptDate(s.checkedAt)) (service \(s.serviceId)\(s.orderId.map { ", order \($0)" } ?? ""))")
            if s.ok {
                // iCloud / blacklist results already appear in the facts lines above.
                if s.icloudClear == nil || s.imeiClean == nil { L.append("  iCloud: \(yn(s.icloudClear, "OFF", "ON/LOST")) · blacklist: \(yn(s.imeiClean, "CLEAN", "BLACKLISTED"))") }
                if let sl = s.simLock { L.append("  SIM-lock: \(clip(scrub(sl), 40))") }
            } else { L.append("  error - no result") }
        }
        if let r = i.repairs, !r.isEmpty { L.append(""); L.append("Repairs: \(r.summary)") }
        if trim < 5, let b = i.backend, !b.isEmpty { L.append(""); L.append("Graded with: \(clip(scrub(b), 40))") }
        if o.includeListingPrice, let p = i.listingPrice { L.append("Listing price: $\(p)") }
        return L.joined(separator: "\n")
    }
}

public enum ReceiptQR {
    /// QR as a CGImage, each module scaled to `scale` px with nearest-neighbor (crisp). Error correction M.
    public static func image(_ text: String, scale: CGFloat = 8) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // quiet zone: 4 modules of white
        let pad = 4 * scale
        let bg = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -pad, dy: -pad))
        let img = scaled.composited(over: bg)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(img, from: img.extent)
    }

    public static func png(_ text: String, scale: CGFloat = 8) -> Data? {
        guard let cg = image(text, scale: scale) else { return nil }
        let d = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, nil)
        return CGImageDestinationFinalize(dst) ? d as Data : nil
    }

    /// Decode the first QR in an image (for tests / smoke checks).
    public static func decode(_ cg: CGImage) -> String? {
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (det?.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString
    }
    public static func decode(png: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return decode(cg)
    }
}
