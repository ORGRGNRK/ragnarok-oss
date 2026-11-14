import SwiftUI
import UniformTypeIdentifiers
import PhoneGraderCore

struct PriceView: View {
    @EnvironmentObject var state: AppState
    @State private var gate: PriceResult?
    @State private var computing = false
    @State private var showQuoteSheet = false
    @State private var importMessage: String?
    #if os(iOS)
    @State private var showLadderImporter = false
    #endif

    var facts: VerifiedFacts { ListingPipeline.deriveVerifiedFacts(state.checklistEntries) }
    var normalized: (model: String, storage: Int) { ListingPipeline.normalizeModelAndStorage(state.phoneModel, state.storageGb) }
    var manualQuote: Double? { Double(state.manualQuoteText.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) }
    var deal: DealResult { state.deal(gate: gate, manualQuote: manualQuote) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FlexRow {
                    Text("Price & max buy").font(.largeTitle.bold())
                    Spacer()
                    Button("Import price list…") { importLadder() }
                    Button("Add buyer quote…") { showQuoteSheet = true }
                }
                if let m = importMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
                inputs
                costInputs
                maxBuyCard
                if let g = gate { gateCard(g) }
                ladderInfo
            }.padding(20)
        }
        .sheet(isPresented: $showQuoteSheet) {
            BuyerQuoteSheet(defaultModel: normalized.model, defaultStorage: normalized.storage).environmentObject(state)
        }
        .onAppear { recompute(); Task { await state.refreshGasPrice() } }
        .onChange(of: state.phoneModel) { _, _ in recompute() }
        .onChange(of: state.storageText) { _, _ in recompute() }
        .onChange(of: state.carrier) { _, _ in recompute() }
        .onChange(of: state.manualGrade) { _, _ in recompute() }
        .onChange(of: state.userQuotes) { _, _ in recompute() }
        #if os(iOS)
        .fileImporter(isPresented: $showLadderImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let u): withSecurityScope(u) { importLadder(from: u) }
            case .failure(let e): importMessage = "Import refused: \(e.localizedDescription) (nothing changed)"
            }
        }
        #endif
    }

    var inputs: some View {
        Card(title: "Device") {
            FlexRow {
                TextField("Model", text: $state.phoneModel).textFieldStyle(.roundedBorder)
                TextField("GB", text: $state.storageText).textFieldStyle(.roundedBorder).pgWidth(80)
                Picker("", selection: $state.carrier) { ForEach(CarrierLock.allCases) { Text($0.label).tag($0) } }.pgWidth(170).labelsHidden()
            }
            FlexRow {
                if let g = state.grade {
                    Text("Grade \(g.overall_grade) (from AI grade)").font(.headline).foregroundStyle(gradeColor(g.overall_grade))
                } else {
                    Picker("Grade", selection: $state.manualGrade) { ForEach(["A", "B", "C", "D", "F"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).pgWidth(260)
                    Text("(no AI grade yet — pick one)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(factsSummary).font(.caption).foregroundStyle(.secondary)
            }
            FlexRow {
                Text("Buyer quote for this unit (optional, beats the ladder): $")
                TextField("e.g. 410", text: $state.manualQuoteText).textFieldStyle(.roundedBorder).pgWidth(90)
                Spacer()
                Button("Recalculate") { recompute() }
                if computing { ProgressView().controlSize(.small) }
            }
        }
    }

    var factsSummary: String {
        var bits: [String] = []
        if let b = facts.battery { bits.append("battery \(b)%") }
        if facts.imeiClean == false { bits.append("IMEI bad") }
        if facts.aftermarketScreen { bits.append("aftermarket screen") }
        if facts.crackedBack { bits.append("cracked back") }
        return bits.isEmpty ? "from checklist: no damage flags" : "from checklist: " + bits.joined(separator: ", ")
    }

    @AppStorage(DealSettings.Key.profitTarget) var profitTarget = DealDefaults.profitTarget
    @AppStorage(DealSettings.Key.mpg) var mpg = DealDefaults.mpg
    @AppStorage(DealSettings.Key.defaultMiles) var defaultMiles = DealDefaults.roundTripMiles
    @AppStorage(DealSettings.Key.eiaPrice) var eiaPriceTick = 0.0          // re-render when the fetch lands
    @State private var askText = ""
    var askValue: Double? { AppState.money(askText).flatMap { $0 >= 0 ? $0 : nil } }

    var repairsBinding: (back: Binding<BackGlassPart>, screen: Binding<ScreenPart>) {
        (Binding(get: { state.repairs.backGlass }, set: { v in var r = state.repairs; r.backGlass = v; state.repairsPicked = r }),
         Binding(get: { state.repairs.screen }, set: { v in var r = state.repairs; r.screen = v; state.repairsPicked = r }))
    }

    var costInputs: some View {
        let src = DealSettings.gasSource(override: state.gasOverride)
        let pc = DealSettings.partCosts
        return Card(title: "This deal's costs") {
            FlexRow {
                HStack {
                    Text("Round-trip miles")
                    TextField(usd(defaultMiles), text: $state.dealMilesText).textFieldStyle(.roundedBorder).pgWidth(70)
                }
                Text("(blank = \(usd(defaultMiles)) from Settings) · \(usd(mpg)) MPG").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            FlexRow {
                Text("Gas $\(String(format: "%.3f", src.price))/gal — \(src.label)\(src.date.map { ", week of \($0)" } ?? "")")
                    .font(.callout).foregroundStyle(src.label == GasPriceSource.placeholderLabel ? .orange : .primary)
                Spacer()
                HStack {
                    Text("Override $/gal")
                    TextField("blank = auto", text: $state.gasOverrideText).textFieldStyle(.roundedBorder).pgWidth(80)
                }
                Button("Refresh EIA") { Task { await state.refreshGasPrice(force: true) } }
            }
            if !state.gasStatus.isEmpty { Text(state.gasStatus).font(.caption).foregroundStyle(.secondary) }
            FlexRow {
                Picker("Back glass", selection: repairsBinding.back) {
                    ForEach(BackGlassPart.allCases) { p in
                        Text(p == .none ? "None" : "\(p.label) $\(usd(RepairParts(backGlass: p).backGlassCost(pc)))").tag(p)
                    }
                }.pgWidth(300)
                Picker("Screen", selection: repairsBinding.screen) {
                    ForEach(ScreenPart.allCases) { p in
                        Text(p == .none ? "None" : "\(p.label) $\(usd(RepairParts(screen: p).screenCost(pc)))").tag(p)
                    }
                }.pgWidth(280)
                Spacer()
            }
            Text("Part costs are placeholders until you set them in Settings → Max buy\(state.rearGlassFailed && state.repairsPicked == nil ? " · rear glass failed on the checklist, so aftermarket back glass is pre-selected" : "").")
                .font(.caption).foregroundStyle(.secondary)
            if state.repairs.usesNonApplePart {
                Text(RepairParts.atlasNote).font(.caption).foregroundStyle(.orange)
            }
            if !state.repairs.disclosures.isEmpty {
                Text("Listing + QR receipt will say: \(state.repairs.disclosures.joined(separator: "; "))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    func line(_ sign: String, _ amount: Double, _ label: String, _ note: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(sign).frame(width: 16, alignment: .leading)
            Text("$\(usd(amount))").frame(width: 90, alignment: .trailing)
            Text(label).bold()
            if !note.isEmpty { Text(note).foregroundStyle(.secondary) }
        }.font(.title3.monospacedDigit())
    }

    var maxBuyCard: some View {
        _ = eiaPriceTick
        let d = deal
        let an = ProfitMath.analyze(d, asking: askValue)
        let color: Color = d.actionable ? .green : (d.maxBuy == nil ? .red : .orange)
        let c = d.costs
        return Card {
            if let a = an {
                Text("MAX BUY").font(.caption.bold()).foregroundStyle(.secondary)
                Text(a.noDeal ? "NO DEAL" : "$\(usd(a.targetBuy))").font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(a.noDeal ? .red : .green)
                VStack(alignment: .leading, spacing: 2) {
                    line(" ", a.exit, d.source == .buyerQuote ? "buyer quote" : "Atlas floor (Grade \(state.effectiveGrade))")
                    line("−", c.gasCost, "gas", "\(c.gas.explanation)")
                    line("−", c.partsCost, "parts", c.partsLabel)
                    line("−", c.profitTarget, "profit target")
                    Divider().pgWidth(360)
                    line("=", a.targetBuy, "max buy")
                }.textSelection(.enabled)
                Text("You make $\(usd(a.profitTarget)) if you pay $\(usd(a.targetBuy)) and Atlas buys at the floor. Walk-away (break-even) $\(usd(a.breakEven)).")
                    .font(.callout)
                HStack {
                    HStack { Text("Asking/buy $"); TextField("optional", text: $askText).textFieldStyle(.roundedBorder).pgWidth(90) }
                    Spacer()
                }
                if let n = a.netProfit {
                    Text("At $\(usd(a.asking!)): total cost $\(usd(a.totalCost!)) · you make $\(usd(n)) if Atlas buys at floor · cushion vs target $\(usd(a.profitCushion!))")
                        .font(.body.monospacedDigit()).textSelection(.enabled)
                }
                Text(a.verdict).font(.title3.bold()).foregroundStyle(a.verdict.hasPrefix("BUY") ? .green : a.verdict.hasPrefix("THIN") ? .orange : a.noDeal || a.verdict.hasPrefix("PASS") ? .red : .primary)
                Text("Gas: \(c.gas.priceSource)\(c.gas.priceDate.map { ", week of \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(d.headline).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(color)
                Text(d.detail).font(.title3).textSelection(.enabled)
            }
            Text("Max buy = floor − gas (miles ÷ MPG × $/gal) − repair parts − profit target ($\(usd(profitTarget)), Settings). Source: \(sourceLabel(d.source)).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save to history") { state.saveToHistory(deal: d, gate: gate, analysis: an) }
                if let id = state.currentRecordId { Text("record #\(id)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 2))
    }

    func sourceLabel(_ s: DealResult.Source) -> String {
        switch s { case .buyerQuote: return "buyer quote"; case .atlasLadder: return "Atlas ladder"; case .none: return "none" }
    }

    func gateCard(_ g: PriceResult) -> some View {
        Card(title: "Atlas gate — \(g.status)") {
            if let f = g.floor {
                Text("\(g.floorQuotable ? "Floor" : "EXPIRED REFERENCE — not quotable"): $\(dollars(f))")
                    .font(.title2.bold()).foregroundStyle(g.floorQuotable ? Color.primary : .orange)
            } else { Text("NO FLOOR").font(.title2.bold()).foregroundStyle(.red) }
            if let row = g.matchedRow { Text("Row: \(row)").font(.callout) }
            if let full = g.ladderFull {
                Text(full.map { "\($0.column) $\(dollars($0.value))" }.joined(separator: "   ")).font(.callout.monospaced())
            }
            if let src = g.quoteSource { Text("Quote: \(src), \(g.quoteDate ?? "")").font(.callout) }
            if let n = g.note { Text(n).textSelection(.enabled) }
            if !g.blockingDisclosures.isEmpty { Text("Blocking").font(.headline).foregroundStyle(.red); bullets(g.blockingDisclosures, color: .red) }
            if !g.warnings.isEmpty { Text("Warnings").font(.headline); bullets(g.warnings, color: .orange) }
            Text(g.retailGuidance).font(.caption).foregroundStyle(.secondary)
        }
    }

    var ladderInfo: some View {
        Card(title: "Price data") {
            if let s = state.ladderStatus {
                Text("\(state.ladderSource): anchored \(s.anchoredDate), delivery Friday \(s.deliveryFriday), \(s.rowsCached) rows.")
                Text(s.verdict).foregroundStyle(s.quotable ? .green : .orange)
                if !s.tabHeader.isEmpty { Text("Tab header: \(s.tabHeader)").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Saved buyer quotes: \(state.userQuotes.count) (manage in Settings).").font(.caption)
            if state.ladderSource.hasPrefix("Imported") {
                Button("Revert to bundled ladder") { state.revertToBundledLadder(); recompute() }
            }
        }
    }

    func recompute() {
        computing = true
        Task {
            let r = await state.priceGate()
            gate = r; computing = false
        }
    }

    func importLadder() {
        #if os(iOS)
        showLadderImporter = true
        #else
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        p.message = "Choose a fresh Atlas price list in atlas-ladder.json format"
        guard p.runModal() == .OK, let u = p.url else { return }
        importLadder(from: u)
        #endif
    }

    func importLadder(from u: URL) {
        do {
            let l = try state.importLadder(from: u)
            importMessage = "Imported \(l.rows.count) rows, delivery Friday \(l.deliveryFriday)."
            recompute()
        } catch { importMessage = "Import refused: \(error.localizedDescription) (nothing changed)" }
    }
}

struct BuyerQuoteSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var defaultModel: String
    var defaultStorage: Int
    @State private var match = ""
    @State private var storage = ""
    @State private var lock = "any"
    @State private var buyer = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var needsAM = false
    @State private var needsBack = false
    @State private var note = ""

    var body: some View {
        Form {
            Text("Add a real buyer quote").font(.title2.bold())
            Text("A number a buyer actually said beats the ladder for matching phones. Never enter a guess.").font(.caption)
            TextField("Model (e.g. iPhone 14 Pro Max)", text: $match)
            TextField("Storage GB (blank = any)", text: $storage)
            Picker("Lock", selection: $lock) {
                Text("Any").tag("any"); Text("Unlocked").tag("unlocked"); Text("Carrier locked").tag("carrier locked"); Text("AT&T clean").tag("att clean")
            }
            TextField("Buyer (e.g. Brett, Atlas Mobile Co)", text: $buyer)
            TextField("Quoted $", text: $amount)
            DatePicker("Quote date", selection: $date, displayedComponents: .date)
            Toggle("Only applies with aftermarket screen", isOn: $needsAM)
            Toggle("Only applies with cracked back", isOn: $needsBack)
            TextField("Note", text: $note)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save quote") { save() }.buttonStyle(.borderedProminent).disabled(!valid)
            }
        }
        #if os(macOS)
        .padding(20).frame(width: 480)
        #else
        .buttonStyle(.borderless)
        #endif
        .onAppear { match = defaultModel; storage = defaultStorage > 0 ? String(defaultStorage) : "" }
    }

    var valid: Bool {
        !buyer.trimmingCharacters(in: .whitespaces).isEmpty && (Double(amount) ?? 0) > 0 && !resolvedMatch.isEmpty
    }
    var resolvedMatch: String {
        guard let e = state.engine else { return pyNorm(match) }
        return e.canonicalizeModel(match, interpreter: nil).0 ?? pyNorm(match)
    }

    func save() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var req: [String] = []
        if needsAM { req.append("aftermarket_screen") }
        if needsBack { req.append("cracked_back") }
        state.addBuyerQuote(BuyerQuote(match: resolvedMatch, storage: Int(storage), lock: lock == "any" ? nil : lock,
                                       buyer: buyer, quoted: Double(amount) ?? 0, dateApprox: f.string(from: date),
                                       dateExactRecorded: true, requiresCondition: req, supersedesLadder: true,
                                       note: note.isEmpty ? "Entered in PhoneGrader." : note))
        dismiss()
    }
}
