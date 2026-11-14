import Foundation
import PhoneGraderCore

/// Price → max-buy math shared by the Price tab and the CLI, so both always agree.
extension AppState {
    /// Atlas gate for the current session (nil = no price data or no model).
    func priceGate() async -> PriceResult? {
        guard let engine else { return nil }
        let (model, storage) = ListingPipeline.normalizeModelAndStorage(phoneModel, storageGb)
        guard !model.isEmpty else { return nil }
        let grade = effectiveGrade
        let lock = ListingPipeline.priceLock(ListingPipeline.normalizeCarrierLock(carrier.rawValue))
        let f = ListingPipeline.deriveVerifiedFacts(checklistEntries)
        let interp = interpreter
        return await Task.detached {
            engine.getAtlasFloor(model: model, storage: storage, grade: grade,
                                 lock: lock == "unknown" ? "unlocked" : lock,
                                 battery: f.battery.map(String.init), imeiClean: f.imeiClean,
                                 aftermarketScreen: f.aftermarketScreen, crackedBack: f.crackedBack,
                                 interpreter: interp)
        }.value
    }

    static func money(_ t: String) -> Double? {
        Double(t.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
    }
    var dealMiles: Double? { AppState.money(dealMilesText).flatMap { $0 >= 0 ? $0 : nil } }
    var gasOverride: Double? { AppState.money(gasOverrideText).flatMap { $0 > 0 ? $0 : nil } }
    var rearGlassFailed: Bool { checklistValues[Checklist.rearGlassIntact] == "FAIL" }
    /// Parts for this deal: what was picked, else aftermarket back glass when the rear glass failed.
    var repairs: RepairParts { repairsPicked ?? RepairParts.defaults(rearGlassFailed: rearGlassFailed) }

    /// Every number in the formula, from the shared settings store + this deal's inputs.
    func dealCosts(miles: Double? = nil, mpg: Double? = nil, gas: Double? = nil, profit: Double? = nil) -> DealCosts {
        DealSettings.costs(miles: miles ?? dealMiles, mpgOverride: mpg, gasOverride: gas ?? gasOverride,
                           parts: repairs, profitOverride: profit,
                           actualParts: PartsLedger.actualCost(PartsLogStore.all, recordId: currentRecordId))
    }

    func deal(gate: PriceResult?, manualQuote: Double?, costs: DealCosts? = nil) -> DealResult {
        DealRule.applyChecklistGate(DealRule.compute(gate: gate, manualQuote: manualQuote, costs: costs ?? dealCosts()),
                                    checklist: checklistEntries, rigBlockers: rigBlockers)
    }

    func refreshGasPrice(force: Bool = false) async {
        gasStatus = await GasPriceService.refresh(force: force)
        objectWillChange.send()
    }

    /// Listing pipeline for the current session (same as the Listing tab's Generate).
    func evaluateListing(asking: Double?) throws -> AssessmentResult {
        guard let engine else { throw PipelineError.modelRequired }
        let input = AssessmentInput(phoneModel: phoneModel, storageGb: storageGb, carrierLock: carrier.rawValue,
                                    checklist: checklistEntries, overallGrade: effectiveGrade,
                                    concerns: grade?.concerns ?? [], notes: notes.isEmpty ? nil : notes,
                                    askingPrice: asking)
        var r = try ListingPipeline.evaluate(input, engine: engine, interpreter: nil)
        if location != ListingCopyGenerator.defaultLocation {
            r.listing.description = r.listing.description.replacingOccurrences(
                of: "📍 \(ListingCopyGenerator.defaultLocation) — local pickup", with: "📍 \(location) — local pickup")
        }
        // Buyer-facing text comes from PhoneFacts — the same model the QR receipt and share photo use.
        let t = PhoneFacts(sessionReceiptInput).listing(location: location)
        r.listing.title = t.title; r.listing.description = t.description
        return r
    }

    /// The current session in the same shape a saved record produces (HistoryRecord.receiptInput).
    var sessionReceiptInput: ReceiptInput {
        let im = IMEI.normalized(imeiText)
        let g = grade ?? GradeResult(overall_grade: manualGrade, categories: [], concerns: [], photos_needed: [], summary: "")
        return ReceiptInput(recordId: currentRecordId ?? 0, date: Date(), model: phoneModel, storageGb: storageGb, color: nil,
                            carrier: carrier.label, imei: im.isEmpty ? imeiChecks.last?.imei : im, serial: device?.serial,
                            grade: g, checklist: checklistEntries, sickw: imeiChecks,
                            backend: gradeBackendUsed.isEmpty ? nil : gradeBackendUsed, listingPrice: Int(askingPriceText),
                            repairs: repairs, batteryCycles: device?.batteryCycles)
    }
}
