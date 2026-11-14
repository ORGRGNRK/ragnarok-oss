import SwiftUI
import PhoneGraderCore

/// History detail: private "Listing & Sale" section (never shown to buyers).
struct SaleCard: View {
    @EnvironmentObject var history: HistoryStore
    let record: HistoryRecord
    @State private var listing = ""
    @State private var sold = ""
    @State private var bought = ""
    @State private var clicks = ""
    @State private var saves = ""
    @State private var messages = ""
    @State private var listedAt = Date()
    @State private var soldAt = Date()
    @State private var boughtAt = Date()
    @State private var paidAt = Date()

    var body: some View {
        let s = record.sale ?? SaleTracking()
        Card(title: "Listing & Sale (private)") {
            FlexRow {
                HStack { Text("Listed $"); TextField("price", text: $listing).pgWidth(70) }
                DatePicker("on", selection: $listedAt, displayedComponents: .date).labelsHidden().disabled(s.listedAt != nil)
                Button("Save price") { update { if let p = Int(listing) { $0.setListing(p, at: $0.listedAt == nil ? listedAt : Date()) } } }
            }
            if s.priceHistory.count > 1 {
                Text("Price history: " + s.priceHistory.map { "$\($0.price) \($0.at.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            FlexRow {
                HStack { Text("Paid $"); TextField("purchase", text: $bought).pgWidth(70) }
                DatePicker("on", selection: $boughtAt, displayedComponents: .date).labelsHidden()
                Button("Save") { update { $0.purchasePrice = Double(bought); $0.boughtAt = boughtAt } }
            }
            FlexRow {
                HStack { Text("Sold $"); TextField("price", text: $sold).pgWidth(70) }
                DatePicker("on", selection: $soldAt, displayedComponents: .date).labelsHidden()
                Button(s.isSold ? "Update sale" : "Mark sold") { update { if let p = Int(sold) { $0.markSold(p, at: soldAt) } } }.buttonStyle(.borderedProminent)
                if s.isSold { Button("Undo sold") { update { $0.unmarkSold() } } }
            }
            if s.isSold {
                FlexRow {
                    Text(s.paidAt.map { "Money landed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Money landed")
                    DatePicker("on", selection: $paidAt, displayedComponents: .date).labelsHidden()
                    Button(s.paidAt == nil ? "Mark paid out" : "Update payout") { update { $0.paidAt = paidAt } }
                }
            }
            FlexRow {
                HStack { Text("Clicks"); TextField("", text: $clicks).pgWidth(50) }
                HStack { Text("Saves"); TextField("", text: $saves).pgWidth(50) }
                HStack { Text("Messages"); TextField("", text: $messages).pgWidth(50) }
                Button("Save stats") { update { $0.setStats(clicks: Int(clicks), saves: Int(saves), messages: Int(messages)) } }
            }
            if let c = s.statsCheckedAt { Text("Stats checked \(c.formatted())").font(.caption).foregroundStyle(.secondary) }
            Text(summary(s)).font(.callout)
            Text(record.cashCycle(parts: PartsLogStore.all).lines.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { fill(s) }
        .onChange(of: record) { _ in fill(record.sale ?? SaleTracking()) }
    }

    func summary(_ s: SaleTracking) -> String {
        var b: [String] = []
        if let d = s.daysToSell() { b.append(s.isSold ? "Sold in \(d) days" : "Listed \(d) days so far") }
        if let p = s.soldVsListedPct { b.append(String(format: "%.0f%% of first list price", p)) }
        if let p = record.actualProfit { b.append("Actual profit $\(usd(p)) (sold − paid − parts − gas)") }
        else if s.isSold && s.purchasePrice == nil { b.append("Enter what you paid to see actual profit") }
        return b.isEmpty ? "Not listed yet." : b.joined(separator: " · ")
    }
    func fill(_ s: SaleTracking) {
        listing = s.listingPrice.map(String.init) ?? record.askingPrice.map(String.init) ?? ""
        sold = s.soldPrice.map(String.init) ?? ""
        bought = s.purchasePrice.map { usd($0) } ?? ""
        clicks = s.clicks.map(String.init) ?? ""; saves = s.saves.map(String.init) ?? ""; messages = s.messages.map(String.init) ?? ""
        listedAt = s.listedAt ?? Date(); soldAt = s.soldAt ?? Date()
        boughtAt = s.boughtAt ?? Date(); paidAt = s.paidAt ?? s.soldAt ?? Date()
    }
    func update(_ f: (inout SaleTracking) -> Void) {
        var r = history.records.first(where: { $0.id == record.id }) ?? record
        r.applySale(f); history.upsert(r)
    }
}
