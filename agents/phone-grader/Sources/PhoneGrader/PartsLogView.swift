import SwiftUI
import UniformTypeIdentifiers
import PhoneGraderCore

/// Parts log: every part purchase, totals, and links to phones (linked actual cost replaces the
/// placeholder part costs in that phone's max buy / profit).
struct PartsLogView: View {
    @EnvironmentObject var state: AppState
    @State private var parts: [PartPurchase] = PartsLogStore.all
    @State private var date = Date()
    @State private var item = ""
    @State private var supplier = PartPurchase.defaultSupplier
    @State private var costText = ""
    @State private var recordId: Int?
    @State private var preview: AmazonBusinessCSV.Preview?
    @State private var importError: String?
    #if os(iOS)
    @State private var showCSVImporter = false
    #endif

    var records: [HistoryRecord] { state.history.records }
    func recordLabel(_ id: Int) -> String {
        records.first { $0.id == id }.map { "#\($0.id) \($0.phoneModel)\($0.storageGb.map { " \($0)GB" } ?? "")" } ?? "#\(id)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FlexRow {
                    Text("Parts log").font(.largeTitle.bold())
                    Spacer()
                    Button("Import Amazon Business CSV…") { importCSV() }
                }
                if let e = importError { Text(e).foregroundStyle(.red) }
                Card(title: "Add a purchase") {
                    FlexRow {
                        DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                        TextField("Item (e.g. iPhone 15 Pro back glass)", text: $item).textFieldStyle(.roundedBorder)
                        TextField("Supplier", text: $supplier).textFieldStyle(.roundedBorder).pgWidth(120)
                        HStack { Text("$"); TextField("cost", text: $costText).textFieldStyle(.roundedBorder).pgWidth(80) }
                    }
                    HStack {
                        recordPicker($recordId)
                        Spacer()
                        Button("Add") { add() }.buttonStyle(.borderedProminent)
                            .disabled(item.trimmingCharacters(in: .whitespaces).isEmpty || AppState.money(costText) == nil)
                    }
                }
                Card(title: "Totals") {
                    Text("Running total: $\(usd(PartsLedger.total(parts))) · \(parts.count) purchases").font(.title3.bold())
                    ForEach(PartsLedger.byMonth(parts), id: \.month) { m in
                        Text("\(m.month): $\(usd(m.total)) (\(m.count))").font(.body.monospacedDigit())
                    }
                }
                Card(title: "Purchases") {
                    if parts.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
                    ForEach(parts) { p in
                        FlexRow {
                            Text(p.date.formatted(date: .abbreviated, time: .omitted)).pgWidth(100, alignment: .leading)
                            Text(p.item).lineLimit(1)
                            Spacer()
                            Text(p.supplier).foregroundStyle(.secondary)
                            Text("$\(usd(p.cost))").monospacedDigit().pgWidth(80, alignment: .trailing)
                            recordPicker(Binding(get: { p.recordId }, set: { v in var u = p; u.recordId = v; PartsLogStore.update(u); reload() }))
                                .pgWidth(220)
                            Button(role: .destructive) { PartsLogStore.delete(p.id); reload() } label: { Image(systemName: "trash") }
                        }
                    }
                    Text("Linking a part to a phone makes its actual cost replace the placeholder parts cost in that phone's max buy and profit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .onAppear { state.history.load(); reload() }
        .sheet(item: Binding(get: { preview.map { PreviewBox(p: $0) } }, set: { if $0 == nil { preview = nil } })) { box in
            importSheet(box.p)
        }
        #if os(iOS)
        .fileImporter(isPresented: $showCSVImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let u): withSecurityScope(u) { previewCSV(u) }
            case .failure(let e): importError = "Import failed: \(e.localizedDescription) (nothing saved)"
            }
        }
        #endif
    }

    struct PreviewBox: Identifiable { let id = UUID(); let p: AmazonBusinessCSV.Preview }

    func recordPicker(_ b: Binding<Int?>) -> some View {
        Picker("Phone", selection: b) {
            Text("No phone").tag(Int?.none)
            ForEach(records) { r in Text(recordLabel(r.id)).tag(Int?.some(r.id)) }
        }
    }

    func importSheet(_ p: AmazonBusinessCSV.Preview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview: \(p.rows.count) purchases, $\(usd(PartsLedger.total(p.rows)))").font(.title2.bold())
            Text("Columns used — date: \(p.columns.date) · item: \(p.columns.item) · total: \(p.columns.total)").font(.caption)
            List(p.rows) { r in
                HStack { Text(r.date.formatted(date: .abbreviated, time: .omitted)); Text(r.item).lineLimit(1); Spacer(); Text("$\(usd(r.cost))") }
            }.frame(minHeight: 260)
            if !p.skipped.isEmpty { Text("Skipped: " + p.skipped.prefix(5).joined(separator: "; ") + (p.skipped.count > 5 ? " …" : "")).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { preview = nil }
                Button("Save \(p.rows.count) purchases") { PartsLogStore.add(p.rows); preview = nil; reload() }
                    .buttonStyle(.borderedProminent).disabled(p.rows.isEmpty)
            }
        }.padding(20)
        #if os(macOS)
        .frame(width: 640)
        #endif
    }

    func reload() { parts = PartsLogStore.all }

    func add() {
        guard let c = AppState.money(costText) else { return }
        PartsLogStore.add([PartPurchase(date: date, item: item.trimmingCharacters(in: .whitespaces),
                                        supplier: supplier.isEmpty ? PartPurchase.defaultSupplier : supplier,
                                        cost: cents(c), recordId: recordId)])
        item = ""; costText = ""; recordId = nil; reload()
    }

    func importCSV() {
        importError = nil
        #if os(iOS)
        showCSVImporter = true
        #else
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; p.allowsMultipleSelection = false
        p.message = "Choose an Amazon Business order history report (CSV)"
        guard p.runModal() == .OK, let u = p.url else { return }
        previewCSV(u)
        #endif
    }

    func previewCSV(_ u: URL) {
        do {
            let text = try String(contentsOf: u, encoding: .utf8)
            preview = try AmazonBusinessCSV.preview(text)
        } catch { importError = "Import failed: \(error.localizedDescription) (nothing saved)" }
    }
}
