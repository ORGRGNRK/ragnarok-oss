import SwiftUI
import PhoneGraderCore

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var history: HistoryStore
    var goTo: (Tab) -> Void
    @State private var selection: Int?
    @State private var confirmSend: HistoryRecord?
    @State private var confirmDelete: HistoryRecord?
    @State private var gradeLogMessage: String?
    @State private var sending = false

    var body: some View {
        content
        .onAppear { history.load() }      // pick up phones graded from the CLI
        .alert("Send to Postgres?", isPresented: Binding(get: { confirmSend != nil }, set: { if !$0 { confirmSend = nil } }), presenting: confirmSend) { r in
            Button("Send", role: .destructive) { send(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("This writes grade #\(r.id) to Postgres endpoint \(GradeLogClient.destination) (Phone Grades) with an atomic database receipt. \(r.gradeLogRecordId == nil ? "Creates a new record." : "Updates record \(r.gradeLogRecordId!).")")
        }
        .alert("Delete this record?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { r in
            Button("Delete", role: .destructive) { history.delete(r); selection = nil }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Removes it from local history only.") }
    }

    #if os(macOS)
    var content: some View {
        HSplitView {
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(history.saleSummary.text)
                Text(history.cashCycleSummary.text)
            }.font(.caption).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            if let err = history.decodeError {
                Text("History file could not be read. It was backed up and not replaced.\n\(err)")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(6)
            }
            List(history.records, selection: $selection) { r in
                row(r).tag(r.id)
            }
            }
            .frame(minWidth: 280, idealWidth: 320)
            ScrollView {
                if let id = selection, let r = history.records.first(where: { $0.id == id }) { detail(r).padding(20) }
                else { Text(history.decodeError != nil ? "History file could not be read." : (history.records.isEmpty ? "No phones graded yet." : "Select a phone.")).foregroundStyle(.secondary).padding(40) }
            }.frame(minWidth: 420)
        }
    }
    #else
    /// iPhone/iPad: list → push the same detail view.
    var content: some View {
        List {
            Section {
                Text(history.saleSummary.text).font(.caption).foregroundStyle(.secondary)
                Text(history.cashCycleSummary.text).font(.caption).foregroundStyle(.secondary)
            }
            if let err = history.decodeError {
                Text("History file could not be read. It was backed up and not replaced.\n\(err)")
                    .font(.caption).foregroundStyle(.red)
            }
            if history.decodeError == nil && history.records.isEmpty { Text("No phones graded yet.").foregroundStyle(.secondary) }
            ForEach(history.records) { r in
                Button { selection = r.id } label: {
                    HStack { row(r); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationDestination(item: $selection) { id in
            ScrollView {
                if let r = history.records.first(where: { $0.id == id }) { detail(r).padding() }
                else { Text("This record was removed.").foregroundStyle(.secondary).padding(40) }
            }
            .navigationTitle("#\(id)")
        }
    }
    #endif

    func row(_ r: HistoryRecord) -> some View {
                HStack {
                    Text(r.grade?.overall_grade ?? "–").font(.title2.bold()).foregroundStyle(gradeColor(r.grade?.overall_grade ?? "F")).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text("#\(r.id) \(r.phoneModel)\(r.storageGb.map { " \($0)GB" } ?? "")").font(.headline)
                        Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let m = r.maxBuy { Text(r.dealBreakdown != nil ? "max $\(usd(m))" : "walk-away $\(dollars(m))").font(.caption) }
                    if r.gradeLogSyncedAt != nil { Image(systemName: "icloud.and.arrow.up").help("Sent to Postgres") }
                    if r.sale?.isSold == true { Image(systemName: "dollarsign.circle.fill").help("Sold") }
                }
    }

    func detail(_ r: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FlexRow {
                Button("Open in Grade / Price / Listing") { state.load(record: r); goTo(.grade) }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = r }
            }
            if let g = r.grade { GradeCard(grade: g, model: r.phoneModel, backend: r.backend) }
            Card(title: "Details (private)") {
                // carrier / iCloud / IMEI / battery are in "What a buyer sees" below — not repeated here
                ForEach(r.checklist.filter { ![Checklist.icloud, Checklist.imei, Checklist.battery].contains($0.label) }, id: \.self) {
                    Text("\($0.label): \($0.value)").font(.callout)
                }
                if let n = r.notes { Text("Notes: \(n)") }
                if let f = r.floor { Text("Floor $\(dollars(f)) (\(r.floorStatus ?? "")\(r.floorQuotable == false ? ", expired reference" : ""))") }
                if let b = r.dealBreakdown {
                    Text("Max buy: \(b.formula)").textSelection(.enabled)
                    Text("Gas: \(b.gas.priceSource)\(b.gas.priceDate.map { ", week of \($0)" } ?? "") · walk-away \(b.breakEven.map { "$" + usd($0) } ?? "–") · you make $\(usd(b.youMakeAtFloor ?? 0)) at floor\(b.netProfitAtAsking.map { " · at asking $\(usd(b.asking ?? 0)) you make $\(usd($0))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let m = r.maxBuy { Text("Walk-away (old buffer rule) $\(dollars(m))\(r.flipKind.map { " — \($0)" } ?? "")") }
                if let p = r.repairs, !p.isEmpty { Text("Repairs: \(p.summary)\(p.disclosures.isEmpty ? "" : " — " + p.disclosures.joined(separator: "; "))") }
                if let s = r.loopStatus { Text("Listing status: \(s)\(r.askingPrice.map { " at $\($0)" } ?? "")") }
            }
            SaleCard(record: r)
            Card(title: "What a buyer sees") {
                Text(r.facts.headline).font(.headline)
                ForEach(r.facts.lines(), id: \.self) { Text($0).font(.callout) }
                ShareMenu(record: r)
            }
            Card(title: "Postgres (manual only)") {
                if !state.gradeLogEnabled {
                    Text("Postgres logging is OFF. Turn it on in Settings to enable the button.").foregroundStyle(.secondary)
                } else if !Keychain.has(.gradeLogToken) {
                    Text("No Postgres token saved in Settings.").foregroundStyle(.secondary)
                }
                HStack {
                    Button(r.gradeLogSyncedAt == nil ? "Send to Postgres" : "Update in Postgres") { confirmSend = r }
                        .disabled(!state.gradeLogEnabled || !Keychain.has(.gradeLogToken) || r.grade == nil || sending)
                    if sending { ProgressView().controlSize(.small) }
                    if let s = r.gradeLogSyncedAt { Text("last sent \(s.formatted())").font(.caption) }
                }
                if let m = gradeLogMessage { Text(m).font(.caption) }
            }
        }
    }

    func send(_ r: HistoryRecord) {
        guard state.gradeLogEnabled else { return }
        sending = true; gradeLogMessage = nil
        Task {
            do {
                let id = try await GradeLogClient.send(r, persistRecordId: { recId in
                    try history.persistGradeLogIdentity(recordId: r.id, identity: recId)
                })
                var u = history.records.first(where: { $0.id == r.id }) ?? r
                u.gradeLogRecordId = id; u.gradeLogSyncedAt = Date(); history.upsert(u)
                gradeLogMessage = "Sent → \(id)"
            } catch { gradeLogMessage = error.localizedDescription }
            sending = false
        }
    }
}
