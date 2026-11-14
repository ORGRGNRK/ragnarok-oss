import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
import CoreImage
import PhoneGraderCore

/// One two-spin rig session: ingest → tag → best frames → grade per pass → audit → grade/price.
@MainActor
final class RigSession: ObservableObject {
    @AppStorage("rigFolder") var folder = ""
    @AppStorage("rigFrameURLs") var frameURLs = ""             // comma-separated, e.g. https://alexus:8443/frame?cam=grader
    @AppStorage("rigPollSeconds") var pollSeconds = 1.0
    @AppStorage("rigRotation") var rotationSetting = -1          // -1 auto, else 0/90/180/270
    @AppStorage("rigAuditEnabled") var auditEnabled = true
    @AppStorage("rigQwenEnabled") var qwenEnabled = true

    let schema: DomainSchema?
    let schemaError: String?
    @Published var frames: [RigFrame] = []
    @Published var capturing: CapturePass?
    @Published var outcome = RigOutcome()
    @Published var busy: String?
    @Published var lastError: String?
    @Published var sessionId = RigSession.newId()
    private var captureTask: Task<Void, Never>?
    private var seenFiles: Set<String> = []
    private var t0 = Date()
    private var thumbs: [String: PlatformImage] = [:]

    init() {
        if let u = Paths.bundled("phone.schema", "json"), let d = try? Data(contentsOf: u) {
            do { schema = try DomainSchema(data: d); schemaError = nil } catch { schema = nil; schemaError = error.localizedDescription }
        } else { schema = nil; schemaError = "phone.schema.json missing from the app bundle" }
    }

    static func newId() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
    var dir: URL {
        let u = Paths.support.appendingPathComponent("rig/\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func reset() {
        stopCapture(); frames = []; outcome = RigOutcome(); seenFiles = []; thumbs = [:]; lastError = nil
        sessionId = RigSession.newId(); t0 = Date()
    }

    // MARK: capture
    func startCapture(_ pass: CapturePass) {
        stopCapture()
        if frames.isEmpty { t0 = Date() }
        capturing = pass
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(mark: pass)
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, self.pollSeconds) * 1_000_000_000))
            }
        }
    }

    func stopCapture() {
        captureTask?.cancel(); captureTask = nil
        if let p = capturing { outcome.record.markDone(p) }
        capturing = nil
        retag()
    }

    private func pollOnce(mark: CapturePass) async {
        // 1) folder: new image files by name
        if !folder.isEmpty {
            let u = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in items.filter({ ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { mtime($0) < mtime($1) }) where !seenFiles.contains(f.path) {
                seenFiles.insert(f.path)
                if let d = try? Data(contentsOf: f) { ingest(d, slot: "folder", mark: mark) }
            }
        }
        // 2) browser-fed /frame?cam= slots (crew vision.sh contract: one current JPEG per slot)
        for s in frameURLs.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !s.isEmpty {
            guard let url = URL(string: s) else { continue }
            var r = URLRequest(url: url); r.timeoutInterval = 5; r.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let slot = URLComponents(string: s)?.queryItems?.first(where: { $0.name == "cam" })?.value ?? url.host ?? "cam"
            ingest(d, slot: slot, mark: mark)
        }
    }

    private func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    /// One-shot import of an existing folder of frames (e.g. a recorded spin). Unmarked → hash-tagged.
    func importFolder(_ u: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if frames.isEmpty { t0 = Date() }
        for (i, f) in items.filter({ ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) })
            .sorted(by: { mtime($0) < mtime($1) }).enumerated() {
            if let d = try? Data(contentsOf: f) { ingest(d, slot: u.lastPathComponent, mark: nil, time: Double(i)) }
        }
        outcome.record.markDone(.exterior)
        if frames.contains(where: { $0.pass == .screen }) { outcome.record.markDone(.screen) }
    }

    func ingest(_ data: Data, slot: String, mark: CapturePass?, time: Double? = nil) {
        #if os(macOS)
        guard let src = NSImage(data: data) else { return }
        var rect = CGRect(origin: .zero, size: src.size)
        guard var cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        #else
        guard var cg = PlatformImaging.raw(data) else { return }
        #endif
        let rot = Upright.rotation(width: cg.width, height: cg.height, cameraRotation: rotationSetting < 0 ? nil : rotationSetting)
        if rot != 0, let r = RigImage.rotate(cg, degrees: rot) { cg = r }
        guard let gray = RigImage.gray(cg, maxSide: 256), let jpeg = RigImage.jpeg(cg) else { return }
        let h = gray.dHash
        // gate: skip a frame identical to this slot's previous one (a still stream is not new evidence)
        if let last = frames.last(where: { $0.slot == slot }), PHash.hamming(last.hash, h) == 0 { return }
        let idx = frames.count
        let name = String(format: "%04d-%@.jpg", idx, slot.replacingOccurrences(of: "/", with: "_"))
        try? jpeg.write(to: dir.appendingPathComponent(name))
        frames.append(RigFrame(index: idx, slot: slot, time: time ?? Date().timeIntervalSince(t0), hash: h,
                               sharpness: gray.sharpness, centerLuma: gray.centerLuma, file: name, markedPass: mark))
    }

    func retag() { frames = PassTagger.tag(frames) }

    func best(_ p: CapturePass) -> [RigFrame] { PassTagger.bestPerAngle(frames, pass: p) }
    func selection(_ p: CapturePass) -> [(RigFrame, Data)] {
        PassTagger.selection(frames, pass: p, cap: Grader.maxPhotos).compactMap { f in
            (try? Data(contentsOf: dir.appendingPathComponent(f.file))).map { (f, $0) }
        }
    }
    func thumbnail(_ f: RigFrame) -> PlatformImage? {
        if let t = thumbs[f.file] { return t }
        #if os(macOS)
        let t = NSImage(contentsOf: dir.appendingPathComponent(f.file)); thumbs[f.file] = t; return t
        #else
        let t = UIImage(contentsOfFile: dir.appendingPathComponent(f.file).path); thumbs[f.file] = t; return t
        #endif
    }

    // MARK: models (nil = not configured → manual review)
    func grader(_ app: AppState) -> RigModel? {
        switch app.backend {
        case .anthropicAPI: return Keychain.has(.anthropicAPIKey) ? AnthropicJSONModel(model: app.anthropicModel) : nil
        case .claudeCLI: return AIClient.findClaude(custom: app.claudePath) != nil ? ClaudeCLIJSONModel(path: app.claudePath, model: app.claudeModel, role: "grader") : nil
        case .ollama: return nil     // damage/identity are never the 7B's (crew probes); manual review instead
        case .appleOnDevice: return nil   // text-only: can't judge damage from frames → manual review
        case .openAICompatible: return app.openAIVisionEnabled ? OpenAICompatJSONModel(baseURL: app.openAIBaseURL, model: app.openAIModel) : nil
        }
    }
    /// Auditor follows the chosen backend (a lapsed Claude subscription shouldn't be called behind your back).
    func auditor(_ app: AppState) -> RigModel? {
        guard auditEnabled else { return nil }
        switch app.backend {
        case .claudeCLI: return AIClient.findClaude(custom: app.claudePath) != nil ? ClaudeCLIJSONModel(path: app.claudePath, model: app.claudeModel, role: "auditor") : nil
        case .anthropicAPI: return Keychain.has(.anthropicAPIKey) ? AnthropicJSONModel(model: app.anthropicModel) : nil
        case .openAICompatible: return app.openAIVisionEnabled ? OpenAICompatJSONModel(baseURL: app.openAIBaseURL, model: app.openAIModel) : nil
        case .appleOnDevice, .ollama: return nil
        }
    }
    func qwen(_ app: AppState) -> RigModel? { qwenEnabled ? OllamaJSONModel(host: app.ollamaHost, model: app.ollamaVisionModel) : nil }

    // MARK: grading steps
    func syncChecklist(_ app: AppState) {
        guard let schema else { return }
        for (f, c) in ChecklistClaims.claims(from: app.checklistEntries) { outcome.record.merge(f, c, schema: schema) }
    }

    func gradePass(_ p: CapturePass, app: AppState) async {
        guard let schema else { return }
        lastError = nil
        syncChecklist(app)
        let sel = selection(p)
        guard !sel.isEmpty else { lastError = "No \(p.rawValue) frames yet."; return }
        if p == .screen, let q = qwen(app) {
            busy = "Reading screens with \(q.label)…"
            var o = outcome; await RigPipeline.screenText(&o, frames: sel, qwen: q, schema: schema); outcome = o
        }
        guard let g = grader(app) else {
            outcome.log.append("No grader configured — manual review: set each category below.")
            ensureManualCategories(p); busy = nil; return
        }
        busy = "Grading \(p.rawValue) with \(g.label)…"
        var o = outcome
        do { try await RigPipeline.gradePass(&o, pass: p, frames: sel, grader: g, rubric: app.rubric, schema: schema, checklist: app.checklistEntries); outcome = o }
        catch { lastError = AIClient.friendly(error); ensureManualCategories(p) }
        busy = nil
    }

    func audit(app: AppState) async {
        guard let a = auditor(app) else { outcome.log.append("Auditor not configured — review the claims by hand."); return }
        lastError = nil
        busy = "Auditing with \(a.label)…"
        let sel = selection(.exterior) + selection(.screen)
        var o = outcome
        do { try await RigPipeline.audit(&o, frames: Array(sel.prefix(Grader.maxPhotos)), auditor: a); outcome = o }
        catch { lastError = AIClient.friendly(error) }
        busy = nil
    }

    static let defaultCategories: [CapturePass: [String]] = [
        .exterior: ["Screen glass", "Back glass / housing", "Frame / edges", "Cameras"],
        .screen: ["Display / authenticity"],
    ]
    func ensureManualCategories(_ p: CapturePass) {
        for n in RigSession.defaultCategories[p] ?? [] where !outcome.categories.contains(where: { $0.name == n }) {
            outcome.categories.append(RigCategory(name: n, grade: nil, notes: "manual review", pass: p))
        }
    }

    func setHumanClaim(_ field: String, _ value: String) {
        guard let schema else { return }
        if let e = outcome.record.merge(field, Claim(.text(value), source: .human, ref: "rig tab"), schema: schema) { lastError = e.description }
    }

    var blockers: [String] { schema.map { RigBlockers.blockers(outcome.record, schema: $0) } ?? ["schema missing"] }

    /// Push the rig result into the normal Grade → Price → Listing session.
    func apply(to app: AppState) {
        guard let schema else { return }
        syncChecklist(app)
        let (g, agg) = RigPipeline.gradeResult(outcome, checklist: app.checklistEntries, schema: schema)
        if let g { app.grade = g; app.gradeBackendUsed = "rig (\(sessionId))" }
        else { app.grade = nil; lastError = "No overall grade: " + agg.reasons.joined(separator: "; ") + " — pick one on the Price tab." }
        if app.phoneModel.isEmpty, case .text(let m) = outcome.record.value("model_exact") { app.phoneModel = m }
        if app.storageText.isEmpty, case .text(let s) = outcome.record.value("storage") {
            app.storageText = s.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        }
        if app.checklistValues[Checklist.battery] == nil, case .int(let b) = outcome.record.value("Battery %") {
            app.checklistValues[Checklist.battery] = String(b)   // camera-read; shown as auto-filled
            app.autoFilled.insert(Checklist.battery)
        }
        if case .text(let c) = outcome.record.value("carrier_lock"), app.carrier == .unknown {
            if c == "Unlocked" { app.carrier = .unlocked }
        }
        app.rigBlockers = blockers
        app.photos = selection(.exterior).prefix(6).compactMap { PhotoItem.load(url: dir.appendingPathComponent($0.0.file)) }
            + selection(.screen).prefix(2).compactMap { PhotoItem.load(url: dir.appendingPathComponent($0.0.file)) }
        if app.grade != nil { app.saveToHistory() }
        try? JSONEncoder().encode(outcome.record).write(to: dir.appendingPathComponent("record.json"))
    }
}

enum RigImage {
    static func rotate(_ cg: CGImage, degrees: Int) -> CGImage? {
        let d = ((degrees % 360) + 360) % 360
        let (w, h) = d == 180 ? (cg.width, cg.height) : (cg.height, cg.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(d) * .pi / 180)      // clockwise
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }
    static func gray(_ cg: CGImage, maxSide: Int) -> GrayImage? {
        let s = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(9, Int(Double(cg.width) * s)), h = max(8, Int(Double(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? GrayImage(width: w, height: h, pixels: px) : nil
    }
    static func jpeg(_ cg: CGImage) -> Data? {
        let s = min(1, 2048 / Double(max(cg.width, cg.height)))
        let w = Int(Double(cg.width) * s), h = Int(Double(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        return PlatformImaging.jpeg(img, quality: 0.85)
    }
}
