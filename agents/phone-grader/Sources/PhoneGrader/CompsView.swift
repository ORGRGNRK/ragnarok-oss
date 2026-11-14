import SwiftUI
import PhoneGraderCore

/// Market comps → suggested local range → listing template.
/// Atlas buyback is the floor; comps say how far above it the local market is.
struct CompsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("rangeMarginOverFloor") var margin = 40.0
    @AppStorage("rangeDiscount") var discount = 25.0
    @AppStorage("compsZip") var zip = LocalPlace.zip
    @AppStorage("compsCity") var city = LocalPlace.city
    @AppStorage("compsRadiusMiles") var radius = 25

    @State private var report: CompsReport?
    @State private var gate: PriceResult?
    @State private var loading = false
    @State private var buyText = ""
    @State private var askSource = "Marketplace"
    @State private var askText = ""
    @State private var listPriceText = ""
    @State private var gradeNotes = ""
    @State private var template: ListingTemplate?

    var query: CompsQuery? { state.compsQuery(zip: zip, radius: radius) }
    var buy: Double? { Double(buyText.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) }
    var range: SuggestedRange {
        PriceRange.compute(floor: gate?.floor, comps: report, buyPrice: buy,
                           settings: RangeSettings(marginOverFloor: margin, discount: discount))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FlexRow {
                    Text("Comps & resale range").font(.largeTitle.bold())
                    Spacer()
                    Button(loading ? "Fetching…" : "Fetch comps") { Task { await load(refresh: false) } }.disabled(loading || query == nil)
                    Button("Refresh (ignore 24h cache)") { Task { await load(refresh: true) } }.disabled(loading || query == nil)
                }
                deviceCard
                compsCard
                localAsksCard
                rangeCard
                listingCard
            }.padding(20)
        }
        .onAppear { Task { await load(refresh: false, swappa: false) } }
    }

    var deviceCard: some View {
        Card(title: "Device (edit on the Price tab)") {
            if let q = query {
                Text("\(q.model) \(q.storage > 0 ? "\(q.storage)GB" : "(storage?)") · \(state.carrier.label) · grade \(q.grade)\(state.batteryPercent.map { " · battery \($0)%" } ?? "")")
            } else { Text("Enter a model on the Price tab first.").foregroundStyle(.orange) }
            FlexRow {
                HStack { Text("Location"); TextField("City", text: $city).pgWidth(130) }
                TextField("ZIP", text: $zip).pgWidth(70)
                Stepper("radius \(radius) mi", value: $radius, in: 5...100, step: 5).pgWidth(170)
                HStack { Text("Your buy price $"); TextField("optional", text: $buyText).pgWidth(80) }
            }.textFieldStyle(.roundedBorder)
        }
    }

    var compsCard: some View {
        Card(title: "Comps") {
            if let r = report {
                if r.isEmpty && r.errors.isEmpty { Text("No comps yet — press Fetch comps, or enter local asks below.").foregroundStyle(.secondary) }
                if r.isEmpty && !r.errors.isEmpty { Text("NO COMPS — fetch failed. No numbers are shown rather than guessed.").font(.headline).foregroundStyle(.red) }
                ForEach(Array(r.sets.enumerated()), id: \.offset) { _, s in compRow(s) }
                ForEach(r.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            } else { Text("No comps fetched.").foregroundStyle(.secondary) }
            Text("Swappa: public listing, price-guide and recent-sales pages, max one request every 2 s, cached on disk 24 h. Marketplace/OfferUp are never fetched — enter what you see below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func compRow(_ s: CompSet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.source).bold()
                Text("· \(s.kind == .sold ? "sold" : s.kind == .ask ? "asks" : "avg list") · n=\(s.count) · fetched \(s.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                Spacer()
                if let u = s.url.flatMap(URL.init(string:)) { Link("open", destination: u).font(.caption) }
            }
            if let st = s.stats {
                Text(s.kind == .avgList ? "avg $\(dollars(st.mean.rounded()))"
                     : "avg $\(dollars(st.mean.rounded())) · median $\(dollars(st.median.rounded())) · p25 $\(dollars(st.p25.rounded())) · $\(dollars(st.min))–$\(dollars(st.max))")
                    .font(.body.monospacedDigit())
            } else { Text("no comps").foregroundStyle(.orange) }
            if let n = s.note { Text(n).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }

    var localAsksCard: some View {
        Card(title: "Local asks (Marketplace / OfferUp) — typed or pasted by you") {
            HStack {
                Picker("", selection: $askSource) { ForEach(["Marketplace", "OfferUp", "Other"], id: \.self) { Text($0) } }.labelsHidden().pgWidth(140)
                if let q = query {
                    if let u = CompsSettings.marketplaceURL(q) { Link("Search Marketplace ↗", destination: u) }
                    if let u = CompsSettings.offerUpURL(q) { Link("Search OfferUp ↗", destination: u) }
                }
                Spacer()
            }
            TextEditor(text: $askText).font(.body.monospaced()).frame(height: 60).border(.quaternary)
            let parsed = LocalAsks.parse(askText)
            HStack {
                Text(parsed.isEmpty ? "Paste listing text or type prices (e.g. 640, 675, $699)." : "Will save \(parsed.count): " + parsed.map { "$\(dollars($0))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save \(askSource) asks") {
                    guard let q = query else { return }
                    LocalAskStore.save(q.deviceKey, LocalAskEntry(source: askSource, prices: parsed, enteredAt: Date()))
                    askText = ""; Task { await load(refresh: false, swappa: report?.sets.contains { $0.source.hasPrefix("Swappa") } ?? false) }
                }.disabled(parsed.isEmpty || query == nil)
                Button("Clear all local asks") {
                    guard let q = query else { return }
                    LocalAskStore.clear(q.deviceKey); Task { await load(refresh: false, swappa: report?.sets.contains { $0.source.hasPrefix("Swappa") } ?? false) }
                }.disabled(query == nil)
            }
        }
    }

    var rangeCard: some View {
        let r = range
        return Card(title: "Suggested local listing range") {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Atlas floor").font(.caption).foregroundStyle(.secondary)
                    Text(gate?.floor.map { "$\(dollars($0))" } ?? "none").font(.title2.bold())
                    if let g = gate, g.floor != nil, !g.floorQuotable { Text("expired reference").font(.caption).foregroundStyle(.orange) }
                }
                VStack(alignment: .leading) {
                    Text("Suggested").font(.caption).foregroundStyle(.secondary)
                    Text(rangeText(r)).font(.title.bold()).foregroundStyle(.green)
                }
                if let pl = r.profitLow {
                    VStack(alignment: .leading) {
                        Text("Profit vs $\(dollars(r.buyPrice ?? 0)) buy").font(.caption).foregroundStyle(.secondary)
                        Text("$\(dollars(pl))\(r.profitHigh.map { " – $\(dollars($0))" } ?? "")").font(.title2.bold())
                            .foregroundStyle(pl >= 0 ? .primary : Color.red)
                    }
                }
            }
            HStack {
                Stepper("Margin over floor $\(Int(margin))", value: $margin, in: 0...300, step: 5)
                Stepper("Discount under market $\(Int(discount))", value: $discount, in: 0...200, step: 5)
            }
            bullets(r.explanation)
            Text("Rule: Atlas buyback is the floor — never list below floor + margin. Anchor = local-ask p25 if you entered local asks, else Swappa sold average, else Swappa listing p25. High = local median ask (else Swappa sold median). Rounded to $5. Floor numbers stay on this Mac — they never go in listings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func rangeText(_ r: SuggestedRange) -> String {
        switch (r.low, r.high) {
        case let (l?, h?): return "$\(dollars(l)) – $\(dollars(h))"
        case let (l?, nil): return "≥ $\(dollars(l))"
        default: return "no range"
        }
    }

    var listingCard: some View {
        Card(title: "Listing template (copy & post yourself — nothing is posted)") {
            FlexRow {
                HStack { Text("Price $"); TextField(range.high.map { dollars($0) } ?? "price", text: $listPriceText).pgWidth(80) }
                TextField("Condition notes (e.g. light scuffs on frame)", text: $gradeNotes)
                Button("Generate") { generate() }.buttonStyle(.borderedProminent).disabled(query == nil)
            }.textFieldStyle(.roundedBorder)
            if let t = template {
                Text(t.title).font(.title3.monospaced()).textSelection(.enabled)
                Text(t.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                FlexRow {
                    Button("Copy title") { copyToPasteboard(t.title) }
                    Button("Copy body") { copyToPasteboard(t.body) }
                    Button("Copy title + body") { copyToPasteboard(t.title + "\n\n" + t.body) }
                }
            }
        }
    }

    func generate() {
        guard let q = query else { return }
        let p = Double(listPriceText.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) ?? range.high
        let notes = gradeNotes.isEmpty ? (state.grade?.summary ?? (state.notes.isEmpty ? nil : state.notes)) : gradeNotes
        template = ListingTemplate.make(model: q.model, storage: q.storage, grade: q.grade, gradeNotes: notes,
                                        battery: state.batteryPercent, carrier: q.carrier, price: p, location: city)
    }

    func load(refresh: Bool, swappa: Bool = true) async {
        guard let q = query else { report = nil; gate = nil; return }
        loading = true
        gate = await state.priceGate()
        report = await CompsProvider.shared.report(q, refresh: refresh, includeSwappa: swappa)
        loading = false
    }
}
