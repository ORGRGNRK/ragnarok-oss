import SwiftUI
import PhoneGraderCore

struct ListingView: View {
    @EnvironmentObject var state: AppState
    @State private var result: AssessmentResult?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Marketplace listing").font(.largeTitle.bold())
                Card {
                    HStack {
                        Text("\(state.phoneModel.isEmpty ? "(no model)" : state.phoneModel)  ·  Grade \(state.effectiveGrade)  ·  \(state.carrier.label)")
                        Spacer()
                    }
                    FlexRow {
                        Text("Your asking price: $")
                        TextField("whole dollars", text: $state.askingPriceText).textFieldStyle(.roundedBorder).pgWidth(110)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Text("Location: \(state.location)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Generate listing") { generate() }.buttonStyle(.borderedProminent)
                    }
                    Text("Copy only claims what you verified on the checklist. Above the Atlas floor is your call — the app never suggests a list price.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let r = result { resultView(r) }
            }.padding(20)
        }
    }

    func resultView(_ r: AssessmentResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                FlexRow {
                    Text(r.loopStatus.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.title.bold())
                        .foregroundStyle(r.loopStatus == .READY ? .green : r.loopStatus == .BLOCKED ? .red : .orange)
                    Spacer()
                    if let f = r.priceGate.floor {
                        Text("\(r.priceGate.floorQuotable ? "wholesale floor" : "expired floor reference"): $\(dollars(f)) · \(r.priceGate.status)")
                    } else { Text("wholesale gate: \(r.priceGate.status)") }
                }
                if !r.listing.blockingDisclosures.isEmpty {
                    Text("Blocked from a normal listing").font(.headline).foregroundStyle(.red)
                    bullets(r.listing.blockingDisclosures, color: .red)
                }
                if r.loopStatus == .NEEDS_HUMAN_PRICE { Text("Enter your asking price to finish the listing.").foregroundStyle(.orange) }
            }
            Card(title: "Title") {
                Text(r.listing.title).font(.title3.monospaced()).textSelection(.enabled)
                Button("Copy title") { copyToPasteboard(r.listing.title) }
            }
            Card(title: "Description") {
                Text(r.listing.description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                FlexRow {
                    Button("Copy description") { copyToPasteboard(r.listing.description) }
                    Button("Copy title + description") { copyToPasteboard(r.listing.title + "\n\n" + r.listing.description) }
                }
            }
            if !r.listing.omittedClaims.isEmpty {
                Card(title: "Deliberately NOT claimed (check these to include them)") { bullets(r.listing.omittedClaims) }
            }
        }
    }

    func generate() {
        error = nil
        guard state.engine != nil else { error = "Price data not loaded."; return }
        var asking: Double?
        let t = state.askingPriceText.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            guard let v = Double(t) else { error = PipelineError.badAskingPrice.localizedDescription; return }
            asking = v
        }
        do {
            let r = try state.evaluateListing(asking: asking)
            result = r
            state.saveToHistory(gate: r.priceGate, assessment: r)
        } catch let e { error = e.localizedDescription }
    }
}
