import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
import PhoneGraderCore

@MainActor
final class AppState: ObservableObject {
    // MARK: settings (UserDefaults; secrets are in Keychain only)
    @AppStorage("backend") var backendRaw = AIBackend.anthropicAPI.rawValue
    @AppStorage("anthropicModel") var anthropicModel = Grader.defaultModel
    @AppStorage("claudePath") var claudePath = ""
    @AppStorage("claudeModel") var claudeModel = ""
    @AppStorage("ollamaHost") var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ollamaVisionModel") var ollamaVisionModel = "qwen2.5vl:7b"
    @AppStorage("ollamaFallback") var ollamaFallback = false
    @AppStorage("interpreterEnabled") var interpreterEnabled = false
    @AppStorage("interpreterModel") var interpreterModel = "qwen2.5:3b-instruct"
    @AppStorage("gradeLogEnabled") var gradeLogEnabled = false     // OFF by default
    @AppStorage("location") var location = ListingCopyGenerator.defaultLocation
    @AppStorage("openAIBaseURL") var openAIBaseURL = OpenAICompat.lmStudioBase
    @AppStorage("openAIModel") var openAIModel = ""
    @AppStorage("openAIVision") var openAIVision = "auto"      // auto | yes | no
    var openAIVisionEnabled: Bool {
        !openAIModel.isEmpty && (openAIVision == "yes" || (openAIVision == "auto" && OpenAICompat.looksVisionCapable(openAIModel)))
    }

    /// One-run override (CLI --backend); never saved.
    var backendOverride: AIBackend?
    var backend: AIBackend { backendOverride ?? AIBackend(rawValue: backendRaw) ?? .anthropicAPI }

    // MARK: data
    @Published var engine: PriceEngine?
    @Published var ladderSource = ""
    @Published var loadError: String?
    @Published var userQuotes: [BuyerQuote] = []
    let history = HistoryStore()
    var rubric = ""

    // MARK: current session (Grade → Price → Listing)
    @Published var photos: [PhotoItem] = []
    @Published var checklistValues: [String: String] = [:]     // label -> PASS / FAIL / "87"
    @Published var phoneModel = ""
    @Published var storageText = ""
    @Published var carrier: CarrierLock = .unknown
    @Published var notes = ""
    @Published var grade: GradeResult?
    @Published var gradeBackendUsed = ""
    @Published var isGrading = false
    @Published var gradeError: String?
    @Published var currentRecordId: Int?
    @Published var manualGrade = "B"           // for pricing without an AI grade
    /// Per-deal max-buy inputs (blank = the default from Settings).
    @Published var dealMilesText = ""
    @Published var gasOverrideText = ""
    /// nil = not picked yet → defaults from the checklist (cracked back → aftermarket back glass).
    @Published var repairsPicked: RepairParts?
    @Published var gasStatus = ""
    @Published var manualQuoteText = ""
    @Published var askingPriceText = ""
    /// Set by the Rig tab: terminal UNKNOWN / bad IMEI status or iCloud → no max buy.
    @Published var rigBlockers: [String] = []
    // MARK: IMEI check (SICKW, paid — only on an explicit button press / pgctl command)
    @Published var imeiText = ""
    @Published var imeiChecks: [ImeiCheckReceipt] = []
    @Published var imeiChecking = false
    @Published var imeiCheckError: String?
    @Published var imeiCheckMessage: String?
    @AppStorage("sickwServiceId") var sickwServiceId = Sickw.defaultServiceId

    // MARK: USB device read
    @Published var device: DeviceReadout?
    @Published var deviceProblem: DeviceProblem?
    @Published var readingDevice = false
    /// Manual battery % keyed by device identifier ("" = no device). Persisted; always beats auto.
    var batteryManualByDevice: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "batteryManualByDevice") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "batteryManualByDevice") }
    }
    @Published var batteryIsManual = false
    func setManualBattery(_ v: String) {
        checklistValues[Checklist.battery] = v.isEmpty ? nil : v
        autoFilled.remove(Checklist.battery)
        var d = batteryManualByDevice; let key = device?.identifier ?? ""
        if v.trimmingCharacters(in: .whitespaces).isEmpty { d[key] = nil; batteryIsManual = false } else { d[key] = v; batteryIsManual = true }
        batteryManualByDevice = d
    }
    @Published var autoFilled: Set<String> = []      // "model", "storage", Checklist.battery
    @AppStorage("autoDetectDevice") var autoDetectDevice = true
    private var lastSeenDevices: [String] = []
    private var pollTask: Task<Void, Never>?

    /// Set by the CLI (`PhoneGrader --cli …`) before AppState is created: no background polling.
    static var headless = false

    init() {
        rubric = Paths.bundled("rubric", "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        reloadPriceData()
        startPolling()
    }

    // MARK: price data
    func reloadPriceData() {
        loadError = nil
        do {
            let ladderURL: URL
            if FileManager.default.fileExists(atPath: Paths.importedLadder.path) {
                ladderURL = Paths.importedLadder; ladderSource = "Imported price list"
            } else if let b = Paths.bundled("atlas-ladder", "json") {
                ladderURL = b; ladderSource = "Bundled atlas-ladder.json (resale-op-mcp)"
            } else { throw AtlasLadder.LoadError.invalid("bundled atlas-ladder.json missing") }
            let ladder = try AtlasLadder(data: Data(contentsOf: ladderURL))
            var book = QuoteBook()
            if let q = Paths.bundled("actual-quotes", "json") { book = try QuoteBook(data: Data(contentsOf: q)) }
            if let d = try? Data(contentsOf: Paths.userQuotes) {
                userQuotes = (try? JSONDecoder().decode([BuyerQuote].self, from: d)) ?? []
            }
            engine = PriceEngine(ladder: ladder, quotes: book.merged(withUserQuotes: userQuotes))
        } catch {
            engine = nil
            loadError = error.localizedDescription
        }
    }

    /// Validate then install a new Atlas price list (same JSON format as atlas-ladder.json).
    func importLadder(from url: URL) throws -> AtlasLadder {
        let data = try Data(contentsOf: url)
        let ladder = try AtlasLadder(data: data)         // throws on anything malformed
        try data.write(to: Paths.importedLadder, options: .atomic)
        reloadPriceData()
        return ladder
    }

    func revertToBundledLadder() {
        try? FileManager.default.removeItem(at: Paths.importedLadder)
        reloadPriceData()
    }

    func addBuyerQuote(_ q: BuyerQuote) {
        userQuotes.insert(q, at: 0); persistQuotes()
    }
    func deleteBuyerQuote(_ q: BuyerQuote) {
        userQuotes.removeAll { $0.id == q.id }; persistQuotes()
    }
    private func persistQuotes() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(userQuotes) { try? d.write(to: Paths.userQuotes, options: .atomic) }
        reloadPriceData()
    }

    var ladderStatus: LadderStatus? { engine?.ladderStatus() }

    // MARK: derived inputs
    var checklistEntries: [ChecklistEntry] {
        Checklist.items.compactMap { item in
            guard let v = checklistValues[item.label], !v.isEmpty else { return nil }
            if item.isBattery {
                let t = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                guard let n = Int(t), (0...100).contains(n) else { return nil }
                return ChecklistEntry(item.label, "\(n)%")
            }
            return ChecklistEntry(item.label, v)
        }
    }
    var storageGb: Int? { Int(storageText.lowercased().replacingOccurrences(of: "gb", with: "").trimmingCharacters(in: .whitespaces)) }
    var effectiveGrade: String { grade?.overall_grade ?? manualGrade }
    var interpreter: ModelInterpreter? {
        interpreterEnabled ? AIClient.ollamaInterpreter(host: ollamaHost, model: interpreterModel) : nil
    }

    func newSession() {
        photos = []; checklistValues = [:]; batteryIsManual = false; phoneModel = ""; storageText = ""; carrier = .unknown; notes = ""
        grade = nil; gradeError = nil; currentRecordId = nil; manualQuoteText = ""; askingPriceText = ""
        manualGrade = "B"; rigBlockers = []
        dealMilesText = ""; gasOverrideText = ""; repairsPicked = nil
        imeiText = ""; imeiChecks = []; imeiCheckError = nil; imeiCheckMessage = nil
        device = nil; deviceProblem = nil; autoFilled = []
    }

    func readDevice() async {
        guard !readingDevice else { return }
        readingDevice = true; deviceProblem = nil
        defer { readingDevice = false }
        switch await DeviceReader.readFirst() {
        case .success(let r): apply(r)
        case .failure(let p): deviceProblem = p
        }
    }

    /// Fill ONLY what the device can prove. iCloud/FRP, carrier lock, original
    /// screen and every pass/fail item stay manual.
    func apply(_ r: DeviceReadout) {
        device = r
        var filled: Set<String> = []
        if let m = r.marketingModel ?? (r.rawModel.isEmpty ? nil : r.rawModel) { phoneModel = m; filled.insert("model") }
        if let s = r.storageGb { storageText = String(s); filled.insert("storage") }
        let manual = batteryManualByDevice[r.identifier] ?? (batteryIsManual ? checklistValues[Checklist.battery] : nil)
        let res = DeviceParsing.resolveBattery(auto: r.batteryHealthPercent, manual: manual)
        if let h = res.value {
            checklistValues[Checklist.battery] = String(h)
            if res.isManual { batteryIsManual = true } else { filled.insert(Checklist.battery) }
        }
        if let i = r.imei, imeiText.isEmpty { imeiText = i; filled.insert("imei") }
        autoFilled = filled
    }

    func setAutoDetect(_ on: Bool) {
        autoDetectDevice = on
        on ? startPolling() : (pollTask?.cancel())
    }

    func startPolling() {
        #if os(macOS)     // iPhone/iPad: no USB device reading
        pollTask?.cancel()
        guard autoDetectDevice, !AppState.headless else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let ids = await DeviceReader.listConnected()
                    .filter { $0.platform == .android || $0.state.uppercased() == "USB" }   // ignore Wi-Fi-synced iPhones
                    .map { "\($0.platform.rawValue):\($0.id):\($0.state)" }
                guard let self else { return }
                let new = ids.filter { !self.lastSeenDevices.contains($0) }
                self.lastSeenDevices = ids
                if !new.isEmpty, !self.readingDevice, self.grade == nil { await self.readDevice() }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        #endif
    }

    func addPhotos(_ urls: [URL]) {
        for u in urls where photos.count < Grader.maxPhotos {
            if let p = PhotoItem.load(url: u) { photos.append(p) }
        }
    }

    #if os(iOS)
    /// Camera / photo library / Files on iPhone & iPad.
    func addPhotoData(_ data: Data, name: String) {
        guard photos.count < Grader.maxPhotos, let p = PhotoItem.load(data: data, name: name) else { return }
        photos.append(p)
    }
    #endif

    // MARK: grading
    /// Auto-filled device facts for text-only backends.
    var deviceInfoText: String? {
        guard let d = device else { return nil }
        var p: [String] = []
        if let m = d.marketingModel ?? (d.rawModel.isEmpty ? nil : d.rawModel) { p.append("model \(m)") }
        if let s = d.storageGb { p.append("\(s)GB") }
        if let o = d.osVersion { p.append("OS \(o)") }
        if let b = d.batteryHealthPercent { p.append(d.batteryHealthIsEstimate ? "battery health ~\(b)% (est.)" : "battery health \(b)% (device-reported)") }
        if let c = d.batteryCycles { p.append("\(c) cycles") }
        if let h = d.batteryHealthText { p.append("battery: \(h)") }
        return p.isEmpty ? nil : p.joined(separator: "; ")
    }

    func runGrade() async {
        gradeError = nil
        guard !photos.isEmpty else { gradeError = GradingError.noPhotos.localizedDescription; return }
        guard !phoneModel.trimmingCharacters(in: .whitespaces).isEmpty else {
            gradeError = "The phone model is required for pricing. Enter the full model name."; return
        }
        isGrading = true
        defer { isGrading = false }
        let req = GradeRequest(photos: photos.map(\.jpeg), checklist: checklistEntries,
                               phoneModel: phoneModel, notes: notes.isEmpty ? nil : notes, rubric: rubric)
        let cfg = BackendConfig(anthropicModel: anthropicModel, claudePath: claudePath, claudeModel: claudeModel,
                                ollamaHost: ollamaHost, ollamaVisionModel: ollamaVisionModel,
                                openAIBaseURL: openAIBaseURL, openAIModel: openAIModel, openAIVision: openAIVision,
                                deviceInfo: deviceInfoText)
        do {
            let (g, used) = try await AIClient.grade(req, backend: backend, config: cfg, ollamaFallback: ollamaFallback)
            grade = g; gradeBackendUsed = used
            saveToHistory()
        } catch {
            gradeError = AIClient.friendly(error) + "\n\nYour photos and answers are still here — fix the backend (or pick another in Settings) and press Grade to retry."
        }
    }

    /// Save/update the current session as a local history record (never leaves the Mac).
    func saveToHistory(deal: DealResult? = nil, gate: PriceResult? = nil, assessment: AssessmentResult? = nil,
                       analysis: DealAnalysis? = nil) {
        let id = currentRecordId ?? history.nextId
        var rec = history.records.first(where: { $0.id == id }) ?? HistoryRecord(
            id: id, createdAt: Date(), phoneModel: phoneModel, storageGb: storageGb, carrierLock: carrier.rawValue,
            checklist: checklistEntries, notes: notes.isEmpty ? nil : notes, grade: grade, backend: gradeBackendUsed,
            photoFiles: [])
        if rec.photoFiles.isEmpty && !photos.isEmpty { rec.photoFiles = history.savePhotos(photos, id: id) }
        rec.phoneModel = phoneModel; rec.storageGb = storageGb; rec.carrierLock = carrier.rawValue
        rec.checklist = checklistEntries; rec.notes = notes.isEmpty ? nil : notes
        if let grade { rec.grade = grade; rec.backend = gradeBackendUsed }
        if !imeiChecks.isEmpty { rec.imeiChecks = imeiChecks }
        let im = IMEI.normalized(imeiText)
        if !im.isEmpty { rec.imei = im }
        if let s = device?.serial, !s.isEmpty { rec.serial = s }
        if let c = device?.batteryCycles { rec.batteryCycles = c }
        if let deal {
            rec.maxBuy = deal.maxBuy; rec.floor = deal.floor
            rec.dealBreakdown = DealBreakdown(deal, analysis: analysis)
        }
        rec.repairs = repairs
        if let gate { rec.floorStatus = gate.status; rec.floorQuotable = gate.floorQuotable }
        if let assessment {
            rec.loopStatus = assessment.loopStatus.rawValue; rec.askingPrice = assessment.askingPrice
            rec.listingTitle = assessment.listing.title; rec.listingDescription = assessment.listing.description
        }
        history.upsert(rec)
        currentRecordId = id
    }

    func load(record r: HistoryRecord) {
        newSession()
        currentRecordId = r.id
        phoneModel = r.phoneModel; storageText = r.storageGb.map(String.init) ?? ""
        carrier = CarrierLock(rawValue: r.carrierLock) ?? .unknown; notes = r.notes ?? ""
        for e in r.checklist { checklistValues[e.label] = e.label == Checklist.battery ? e.value.replacingOccurrences(of: "%", with: "") : e.value }
        grade = r.grade; gradeBackendUsed = r.backend
        repairsPicked = r.repairs ?? r.dealBreakdown?.parts
        if let m = r.dealBreakdown?.gas.roundTripMiles, m != DealSettings.defaultMiles { dealMilesText = usd(m) }
        askingPriceText = r.askingPrice.map(String.init) ?? ""
        imeiChecks = r.imeiChecks ?? []
        imeiText = imeiChecks.last?.imei ?? ""
        photos = r.photoFiles.compactMap { PhotoItem.load(url: Paths.photos.appendingPathComponent($0)) }
    }
}
