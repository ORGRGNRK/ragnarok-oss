// macOS only: the headless `PhoneGrader --cli` / pgctl interface (the iOS app has no CLI).
#if os(macOS)
import Foundation
import PhoneGraderCore

/// `pgctl` — every PhoneGrader action from the terminal. It drives the same
/// AppState / RigSession / HistoryStore the window uses, so a phone graded here
/// shows up in the app's History tab and vice versa. Secrets are never printed.
@MainActor
struct CLI {
    static let usage = """
    pgctl — PhoneGrader from the terminal (same code, settings and history as the app)

    Phone inputs (grade / price / listing / rig):
      --id N              start from history record #N (its photos, checklist, grade)
      --model "iPhone 13 Pro"   --storage 256   --carrier unlocked|att_clean|verizon_locked|tmobile_locked|other_locked|unknown
      --check KEY=VALUE   checklist answer, repeatable. KEY: icloud imei battery screen back buttons touch audio charge
                          VALUE: pass|fail, battery takes a percent (--check battery=87)
      --notes "text"      --grade A-F (only used when there's no AI grade)   --quote 410
      --miles 20 (round trip)   --mpg 24   --gas 4.89 ($/gal override)   --profit 40
      --back-glass none|aftermarket|apple   --screen none|oem|aftermarket   (repair parts for this deal)
      --backend claudeCLI|appleOnDevice|openAICompatible|anthropicAPI|ollama   use this AI for this run only (grade / rig)

    Commands:
      status                              settings, AI backend, price list freshness, history count
      backends                            which grading backends are usable right now (Apple model availability, local server models, key/CLI presence)
      checklist                           the checklist keys and what they mean
      grade --photo F [--photo F …] …     AI-grade photos (max 8); saves a history record
      price …  [--save] [--ask 480]       max buy = floor − gas − parts − profit target, line by line;
                                          with --ask: BUY/THIN/PASS, net profit, cushion. --save writes the breakdown to the record
      gas [--refresh]                     gas price in use (EIA weekly California regular, else manual price from Settings)
      listing … [--ask 450]               Marketplace title + description; saves to the record
      listing --template … [--price 640] [--notes T]   short Marketplace/OfferUp template (title + body); nothing is posted
      comps … [--refresh] [--no-swappa]   Swappa listings / sold / price guide (24h cache) + your saved local asks
            [--asks "640, $699" --asks-source marketplace|offerup|other]  save local asks you saw (never scraped)
            [--clear-asks] [--zip 12345] [--radius 25]
      price … --range [--buy 500] [--margin 40] [--discount 25]   + comps and a suggested local listing range
      rig run FOLDER [FOLDER2] …          grade a recorded rig spin (frames folder), audit, price; saves when graded
      device                              read the connected phone — USB first, else a Wi-Fi-synced iPhone
      history [list|show N|delete N --yes|path]
      history note N TEXT | notes N        append-only memory note on record N | list them
      notes [list | add TEXT]              business-level append-only notes log
      parts [list [--record N] | add --item X --cost N [--supplier S] [--record N] [--date D] [--note T]]   Parts log
      (sale setters + note/notes add accept --at "2026-10-16 19:30" local or ISO 8601)
      history sale N | sales               private listing/sale tracking for N | averages (days to sell, sold vs list %, actual profit)
      history set-listing N PRICE · sold N PRICE · unsold N · bought N PRICE · paid N · stats N CLICKS SAVES MESSAGES
                                          (bought sets the buy date, paid the day the sale money landed; both take --at)
      history cycle [N]                   economic cash conversion cycle: first cash out → cash in, held / payout days,
                                          cash tied, return on cash, annualized; history-wide turns/yr and cash out now
      quotes [list | add --model M --buyer B --amount N [--storage N] [--lock unlocked|carrier locked|att clean]
                         [--date YYYY-MM-DD] [--aftermarket] [--cracked-back] [--note T] | delete ID]
      imei check IMEI [--service 61] [--id N] [--json]   PAID SICKW check; sets iCloud/IMEI checklist only on a clear result, saves a receipt
      imei balance                        SICKW account balance (free). Both refuse without a key saved in Settings.
      imei services                       known SICKW service IDs and public list prices
      imei set-key                        read the SICKW API key from stdin (hidden) into the Keychain;  imei remove-key
      share N --png PATH [--mask-imei]    1080×1080 listing photo for record N (facts + small QR; no grade, no prices)
      receipt N [--png PATH] [--text] [--mask-imei] [--no-price]   QR receipt for record N (plain text inside the QR)
      ladder [status | import FILE | revert]
      config [list | get KEY | set KEY VALUE]
      gradeLog send N --yes               push record #N to Postgres / NocoDB (+ database receipt)

    Add --json to status, checklist, grade, price, comps, listing, rig, device, history, quotes for machine output.
    """

    // MARK: argument parsing
    var positional: [String] = []
    var opts: [String: [String]] = [:]
    var flags: Set<String> = []
    static let flagNames: Set<String> = ["mask-imei", "no-price", "text", "json", "yes", "save", "aftermarket", "cracked-back", "help", "refresh", "range", "template", "no-swappa", "clear-asks"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2)), value: String?
                if let eq = key.firstIndex(of: "=") { value = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
                if CLI.flagNames.contains(key) { flags.insert(key) }
                else if let v = value { opts[key, default: []].append(v) }
                else if i + 1 < args.count { opts[key, default: []].append(args[i + 1]); i += 1 }
                else { opts[key, default: []].append("") }
            } else if a == "-h" { flags.insert("help") }
            else { positional.append(a) }
            i += 1
        }
    }

    func opt(_ k: String) -> String? { opts[k]?.last }
    func all(_ k: String) -> [String] { opts[k] ?? [] }
    var json: Bool { flags.contains("json") }

    struct Failure: Error { let message: String; var code: Int32 = 1 }
    func fail(_ m: String, usage: Bool = false) -> Failure { Failure(message: m, code: usage ? 2 : 1) }

    // MARK: entry
    func run() async -> Int32 {
        guard let cmd = positional.first, !flags.contains("help"), cmd != "help" else { print(CLI.usage); return 0 }
        let rest = Array(positional.dropFirst())
        do {
            switch cmd {
            case "status": try status()
            case "backends": await backends()
            case "checklist": checklist()
            case "grade": try await grade()
            case "price": try await price()
            case "gas": try await gas()
            case "listing": try listing()
            case "comps": try await comps()
            case "rig": try await rig(rest)
            case "device": try await device()
            case "history": try history(rest)
            case "quotes": try quotes(rest)
            case "notes": try businessNotes(rest)
            case "parts": try parts(rest)
            case "ladder": try ladder(rest)
            case "receipt": try receipt(rest)
            case "share": try share(rest)
            case "imei": try await imei(rest)
            case "config": try config(rest)
            case "gradeLog": try await gradeLog(rest)
            default: throw fail("Unknown command '\(cmd)'. Run pgctl help.", usage: true)
            }
            return 0
        } catch let f as Failure {
            FileHandle.standardError.write(Data(("pgctl: " + f.message + "\n").utf8)); return f.code
        } catch {
            FileHandle.standardError.write(Data(("pgctl: " + AIClient.friendly(error) + "\n").utf8)); return 1
        }
    }

    // MARK: output helpers
    func emit(_ obj: Any) {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        print(String(data: d, encoding: .utf8) ?? "{}")
    }
    func plain<T: Encodable>(_ v: T) -> Any {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(v), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return NSNull() }
        return o
    }
    func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

    func gateDict(_ g: PriceResult) -> [String: Any] {
        ["model": g.model, "modelResolved": opt(g.modelResolved), "storage": g.storage, "grade": g.grade, "lock": g.lock,
         "status": g.status, "floor": opt(g.floor), "floorQuotable": g.floorQuotable, "matchedRow": opt(g.matchedRow),
         "ladder": g.ladderFull.map { $0.map { ["column": $0.column, "value": $0.value] } } as Any? ?? NSNull(),
         "quoteSource": opt(g.quoteSource), "quoteDate": opt(g.quoteDate), "note": opt(g.note),
         "warnings": g.warnings, "blockingDisclosures": g.blockingDisclosures,
         "anchoredDate": g.anchoredDate, "deliveryFriday": g.deliveryFriday]
    }
    func dealDict(_ d: DealResult) -> [String: Any] {
        ["maxBuy": opt(d.maxBuy), "breakEven": opt(d.breakEven), "actionable": d.actionable, "floor": opt(d.floor), "source": d.source.rawValue,
         "gasCost": d.gasCost, "partsCost": d.partsCost, "profitTarget": d.profitTarget, "headline": d.headline, "detail": d.detail]
    }

    func gas() async throws {
        let msg = await GasPriceService.refresh(force: flags.contains("refresh"))
        let src = DealSettings.gasSource(override: nil)
        if json { emit(["price": src.price, "source": src.label, "date": opt(src.date), "status": msg]); return }
        print("Gas in use: $\(String(format: "%.3f", src.price))/gal — \(src.label)\(src.date.map { ", week of \($0)" } ?? "")")
        print(msg)
        print("MPG \(usd(DealSettings.mpg)) · default round trip \(usd(DealSettings.defaultMiles)) mi → $\(usd(GasInputs(roundTripMiles: DealSettings.defaultMiles, mpg: DealSettings.mpg, pricePerGallon: src.price).cost)) per deal")
    }
    func printGrade(_ g: GradeResult, backend: String) {
        print("GRADE \(g.overall_grade)   (\(backend))")
        print(g.summary)
        for c in g.categories { print("  \(c.grade)  \(c.name) — \(c.notes)") }
        if !g.concerns.isEmpty { print("Concerns:"); g.concerns.forEach { print("  • \($0)") } }
        if !g.photos_needed.isEmpty { print("Photos needed:"); g.photos_needed.forEach { print("  • \($0)") } }
    }

    // MARK: session setup from --id / phone inputs
    static let checkKeys: [(key: String, label: String)] = [
        ("icloud", Checklist.icloud), ("imei", Checklist.imei), ("battery", Checklist.battery),
        ("screen", Checklist.originalScreen), ("back", Checklist.rearGlassIntact),
        ("buttons", Checklist.items[5].label), ("touch", Checklist.items[6].label),
        ("audio", Checklist.items[7].label), ("charge", Checklist.items[8].label),
    ]

    func makeState() throws -> AppState {
        let s = AppState()
        if let e = s.loadError { throw fail("Price data didn't load: \(e)") }
        return s
    }

    func session(_ s: AppState) throws {
        s.newSession()
        if let idText = opt("id") {
            guard let id = Int(idText), let r = s.history.records.first(where: { $0.id == id }) else { throw fail("No history record #\(idText).") }
            s.load(record: r)
        }
        if let m = opt("model") { s.phoneModel = m }
        if let st = opt("storage") { s.storageText = st }
        if let c = opt("carrier") {
            guard let v = CarrierLock(rawValue: c) else { throw fail("--carrier must be one of: \(CarrierLock.allCases.map(\.rawValue).joined(separator: ", "))", usage: true) }
            s.carrier = v
        }
        if let n = opt("notes") { s.notes = n }
        if let b = opt("backend") {
            guard AIBackend(rawValue: b) != nil else { throw fail("--backend must be one of: \(AIBackend.cliNames)", usage: true) }
            s.backendOverride = AIBackend(rawValue: b)    // this run only; the saved setting is untouched
        }
        if opt("kind") != nil { throw fail("--kind was removed (Oct 16): max buy = floor − gas − parts − profit. Use --miles/--back-glass/--screen/--profit.", usage: true) }
        if let m = opt("miles") { guard let v = Double(m), v >= 0 else { throw fail("--miles takes round-trip miles ≥ 0", usage: true) }; s.dealMilesText = m }
        if let g = opt("gas") { guard let v = Double(g.replacingOccurrences(of: "$", with: "")), v > 0 else { throw fail("--gas takes $/gal > 0", usage: true) }; s.gasOverrideText = g }
        if opt("back-glass") != nil || opt("screen") != nil {
            var r = s.repairs
            if let b = opt("back-glass") { guard let v = BackGlassPart(rawValue: b.lowercased()) else { throw fail("--back-glass must be none, aftermarket or apple", usage: true) }; r.backGlass = v }
            if let sc = opt("screen") { guard let v = ScreenPart(rawValue: sc.lowercased()) else { throw fail("--screen must be none, oem or aftermarket", usage: true) }; r.screen = v }
            s.repairsPicked = r
        }
        if let g = opt("grade") {
            let u = g.uppercased()
            guard ["A", "B", "C", "D", "F"].contains(u) else { throw fail("--grade must be A, B, C, D or F", usage: true) }
            if let ai = s.grade, ai.overall_grade != u {
                FileHandle.standardError.write(Data("note: record has AI grade \(ai.overall_grade); --grade \(u) is ignored\n".utf8))
            }
            s.manualGrade = u
        }
        for c in all("check") {
            let parts = c.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let item = CLI.checkKeys.first(where: { $0.key == parts[0].lowercased() }) else {
                throw fail("Bad --check '\(c)'. Use KEY=pass|fail with KEY one of: \(CLI.checkKeys.map(\.key).joined(separator: " "))", usage: true)
            }
            if item.label == Checklist.battery {
                let n = parts[1].replacingOccurrences(of: "%", with: "")
                guard let v = Int(n), (0...100).contains(v) else { throw fail("--check battery= takes a percent 0–100", usage: true) }
                s.checklistValues[item.label] = String(v)
            } else {
                switch parts[1].lowercased() {
                case "pass", "p", "yes", "y", "ok", "true": s.checklistValues[item.label] = "PASS"
                case "fail", "f", "no", "n", "false": s.checklistValues[item.label] = "FAIL"
                case "", "unknown", "clear": s.checklistValues[item.label] = nil
                default: throw fail("--check \(item.key)= takes pass or fail", usage: true)
                }
            }
        }
    }

    var manualQuote: Double? { opt("quote").flatMap { Double($0.replacingOccurrences(of: "$", with: "")) } }

    // MARK: commands
    func status() throws {
        let s = AppState(), rig = RigSession()
        let ls = s.ladderStatus
        let claude = AIClient.findClaude(custom: s.claudePath)
        let info: [String: Any] = [
            "backend": s.backend.rawValue, "anthropicModel": s.anthropicModel, "claudeModel": s.claudeModel,
            "claudeCLI": opt(claude), "anthropicKeySaved": Keychain.has(.anthropicAPIKey),
            "gradeLogTokenSaved": Keychain.has(.gradeLogToken), "sickwKeySaved": Keychain.has(.sickwAPIKey), "gradeLogEnabled": s.gradeLogEnabled,
            "ollamaHost": s.ollamaHost, "ollamaVisionModel": s.ollamaVisionModel, "ollamaFallback": s.ollamaFallback,
            "location": s.location, "priceList": s.ladderSource, "priceListError": opt(s.loadError),
            "ladderAnchored": opt(ls?.anchoredDate), "ladderDeliveryFriday": opt(ls?.deliveryFriday),
            "ladderQuotable": opt(ls?.quotable), "ladderVerdict": opt(ls?.verdict), "ladderRows": opt(ls?.rowsCached),
            "buyerQuotes": s.userQuotes.count, "historyRecords": s.history.records.count,
            "rigFolder": rig.folder, "rigFrameURLs": rig.frameURLs, "rigAudit": rig.auditEnabled, "rigQwen": rig.qwenEnabled,
            "rigSchemaError": opt(rig.schemaError), "dataDir": Paths.support.path,
        ]
        if json { emit(info); return }
        print("Backend:      \(s.backend.label)\(s.backend == .anthropicAPI ? " · \(s.anthropicModel)" : s.backend == .claudeCLI ? " · \(s.claudeModel.isEmpty ? "default model" : s.claudeModel)" : " · \(s.ollamaVisionModel)")")
        print("claude CLI:   \(claude ?? "not found")")
        print("Keychain:     Anthropic key \(Keychain.has(.anthropicAPIKey) ? "saved" : "none") · Postgres token \(Keychain.has(.gradeLogToken) ? "saved" : "none") · Postgres sending \(s.gradeLogEnabled ? "ON" : "off")")
        print("Ollama:       \(s.ollamaHost) · \(s.ollamaVisionModel)\(s.ollamaFallback ? " (fallback on)" : "")")
        if let e = s.loadError { print("Price list:   FAILED — \(e)") }
        else if let ls { print("Price list:   \(s.ladderSource) · anchored \(ls.anchoredDate) · delivery Fri \(ls.deliveryFriday) · \(ls.rowsCached) rows\n              \(ls.verdict)") }
        print("Quotes:       \(s.userQuotes.count) saved buyer quotes")
        print("History:      \(s.history.records.count) phones")
        print("Rig:          folder \(rig.folder.isEmpty ? "(none)" : rig.folder) · feeds \(rig.frameURLs.isEmpty ? "(none)" : rig.frameURLs) · audit \(rig.auditEnabled ? "on" : "off") · qwen \(rig.qwenEnabled ? "on" : "off")")
        print("Data:         \(Paths.support.path)")
    }

    func backends() async {
        let s = AppState()
        let apple = AppleModelStatus.check()
        let claude = AIClient.findClaude(custom: s.claudePath)
        var models: [String] = [], localErr: String?
        do { models = try await OpenAICompatBackend.models(baseURL: s.openAIBaseURL) } catch { localErr = AIClient.friendly(error) }
        let info: [String: Any] = [
            "selected": s.backend.rawValue,
            "appleOnDevice": ["available": apple.available, "reason": apple.reason, "seesPhotos": false],
            "openAICompatible": ["baseURL": s.openAIBaseURL, "model": s.openAIModel, "reachable": localErr == nil, "models": models,
                                 "error": opt(localErr), "sendsPhotos": s.openAIVisionEnabled],
            "claudeCLI": ["path": opt(claude), "note": "not called here (would spend usage)"],
            "anthropicAPI": ["keySaved": Keychain.has(.anthropicAPIKey), "model": s.anthropicModel],
        ]
        if json { emit(info); return }
        print("Selected:        \(s.backend.rawValue) — \(s.backend.label)")
        print("Apple model:     \(apple.available ? "AVAILABLE" : "unavailable") — \(apple.reason)")
        print("Local server:    \(s.openAIBaseURL) — \(localErr.map { "not reachable: \($0)" } ?? (models.isEmpty ? "running, no models" : models.joined(separator: ", ")))")
        print("                 model \(s.openAIModel.isEmpty ? "(none chosen)" : s.openAIModel), photos \(s.openAIVisionEnabled ? "sent" : "not sent (text-only)")")
        print("Claude CLI:      \(claude ?? "not found") (not invoked by this check)")
        print("Claude API key:  \(Keychain.has(.anthropicAPIKey) ? "saved in Keychain" : "none")")
    }

    func checklist() {
        if json { emit(CLI.checkKeys.map { ["key": $0.key, "label": $0.label, "required": Checklist.required.contains($0.label)] }); return }
        for c in CLI.checkKeys {
            print("\(c.key.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.label)\(Checklist.required.contains(c.label) ? "  *" : "")")
        }
        print("\n* feeds the listing's verified facts. Values: pass / fail; battery takes a percent.")
    }

    func grade() async throws {
        let s = try makeState()
        try session(s)
        let photos = all("photo")
        if !photos.isEmpty {
            s.photos = []
            for p in photos {
                let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: u.path) else { throw fail("Photo not found: \(p)") }
                s.addPhotos([u])
            }
            if photos.count > Grader.maxPhotos { FileHandle.standardError.write(Data("note: only the first \(Grader.maxPhotos) photos are used\n".utf8)) }
            if s.photos.isEmpty { throw fail("None of the photos could be opened as images.") }
        }
        if !json { FileHandle.standardError.write(Data("Grading \(s.photos.count) photo(s) with \(s.backend.rawValue)…\n".utf8)) }
        await s.runGrade()
        if let e = s.gradeError { throw fail(e.components(separatedBy: "\n\nYour photos").first ?? e) }
        guard let g = s.grade else { throw fail("No grade returned.") }
        if json { emit(["record": opt(s.currentRecordId), "backend": s.gradeBackendUsed, "grade": plain(g)]); return }
        printGrade(g, backend: s.gradeBackendUsed)
        print("Saved as history record #\(s.currentRecordId ?? 0). Next: pgctl price --id \(s.currentRecordId ?? 0)")
    }

    func price() async throws {
        let s = try makeState()
        try session(s)
        guard !s.phoneModel.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("Need --model (or --id of a record that has one).", usage: true) }
        let gate = await s.priceGate()
        await s.refreshGasPrice()
        var pfOverride: Double?
        if let p = opt("profit") ?? opt("profit-floor") { guard let v = Double(p.replacingOccurrences(of: "$", with: "")), v >= 0 else { throw fail("--profit takes dollars ≥ 0", usage: true) }; pfOverride = v }
        var mpgOverride: Double?
        if let m = opt("mpg") { guard let v = Double(m), v > 0 else { throw fail("--mpg takes a number > 0", usage: true) }; mpgOverride = v }
        let costs = s.dealCosts(mpg: mpgOverride, profit: pfOverride)
        let d = s.deal(gate: gate, manualQuote: manualQuote, costs: costs)
        let pf = costs.profitTarget
        var askV: Double?
        if let a = opt("ask") { guard let v = Double(a.replacingOccurrences(of: "$", with: "")), v >= 0 else { throw fail("--ask takes dollars", usage: true) }; askV = v }
        let an = ProfitMath.analyze(d, asking: askV)
        if flags.contains("save") { s.saveToHistory(deal: d, gate: gate, analysis: an) }
        var rng: (CompsReport, SuggestedRange)?
        if flags.contains("range") {
            let q = try compsQuery(s)
            let rep = await CompsProvider.shared.report(q, refresh: flags.contains("refresh"), includeSwappa: !flags.contains("no-swappa"))
            rng = (rep, PriceRange.compute(floor: gate?.floor, comps: rep, buyPrice: try buyPrice(), settings: try rangeSettings()))
        }
        if json {
            var o: [String: Any] = ["analysis": an.map { plain($0) } ?? NSNull(), "profitTarget": pf, "deal": dealDict(d), "breakdown": plain(DealBreakdown(d, analysis: an)), "gate": gate.map(gateDict) as Any? ?? NSNull(), "grade": s.effectiveGrade,
                  "record": opt(flags.contains("save") ? s.currentRecordId : nil)]
            if let x = rng { o["comps"] = compsDict(x.0); o["range"] = plain(x.1) }
            emit(o)
            return
        }
        defer { if let x = rng { print(""); printComps(x.0); printRange(x.1) } }
        print("\(s.phoneModel) \(s.storageText.isEmpty ? "" : s.storageText + "GB ")· grade \(s.effectiveGrade)\(s.grade == nil ? " (manual)" : " (AI)") · \(s.carrier.label)")
        print("")
        if let a = an {
            let c = d.costs
            print(a.noDeal ? "NO DEAL — max buy $\(usd(a.targetBuy))" : "MAX BUY $\(usd(a.targetBuy))")
            print("  $\(usd(a.exit).padding(toLength: 8, withPad: " ", startingAt: 0)) \(d.source == .buyerQuote ? "buyer quote" : "Atlas floor")")
            print("− $\(usd(c.gasCost).padding(toLength: 8, withPad: " ", startingAt: 0)) gas: \(c.gas.explanation)  [\(c.gas.priceSource)\(c.gas.priceDate.map { ", week of \($0)" } ?? "")]")
            print("− $\(usd(c.partsCost).padding(toLength: 8, withPad: " ", startingAt: 0)) parts: \(c.partsLabel)\(c.parts.isEmpty || c.actualPartsCost != nil ? "" : " (placeholder costs unless set in Settings)")")
            print("− $\(usd(c.profitTarget).padding(toLength: 8, withPad: " ", startingAt: 0)) profit target")
            print("= $\(usd(a.targetBuy)) max buy   (walk-away / break-even $\(usd(a.breakEven)))")
            print("You make $\(usd(a.profitTarget)) if you pay $\(usd(a.targetBuy)) and Atlas buys at the floor.")
            if c.parts.usesNonApplePart { print(RepairParts.atlasNote) }
            if let ask = a.asking {
                print("Asking $\(usd(ask)) → total cost $\(usd(a.totalCost!)) · gross spread $\(usd(a.grossSpread!)) · you make $\(usd(a.netProfit!)) at floor · cushion $\(usd(a.profitCushion!))")
            }
            print(a.verdict)
        } else {
            print(d.headline)
            print(d.detail)
        }
        if let g = gate {
            print("\nAtlas gate — \(g.status)")
            if let f = g.floor { print("  \(g.floorQuotable ? "Floor" : "EXPIRED REFERENCE — not quotable"): $\(dollars(f))") } else { print("  NO FLOOR") }
            if let row = g.matchedRow { print("  Row: \(row)") }
            if let full = g.ladderFull { print("  " + full.map { "\($0.column) $\(dollars($0.value))" }.joined(separator: "   ")) }
            if let src = g.quoteSource { print("  Quote: \(src), \(g.quoteDate ?? "")") }
            if let n = g.note { print("  \(n)") }
            g.blockingDisclosures.forEach { print("  BLOCKING: \($0)") }
            g.warnings.forEach { print("  warning: \($0)") }
        } else if s.engine == nil { print("(price data not loaded)") }
        if !s.rigBlockers.isEmpty { s.rigBlockers.forEach { print("  RIG BLOCKER: \($0)") } }
        if flags.contains("save") { print("\nSaved to history record #\(s.currentRecordId ?? 0).") }
    }

    func listing() throws {
        let s = try makeState()
        try session(s)
        if flags.contains("template") {
            let q = try compsQuery(s)
            var price: Double?
            if let p = opt("price") ?? opt("ask") {
                guard let v = Double(p.replacingOccurrences(of: "$", with: "")), v > 0 else { throw fail("--price takes a dollar amount", usage: true) }
                price = v
            }
            let notes = opt("notes") ?? s.grade?.summary
            let t = ListingTemplate.make(model: q.model, storage: q.storage, grade: q.grade, gradeNotes: notes,
                                         battery: s.batteryPercent, carrier: q.carrier, price: price, location: q.city)
            if json { emit(["title": t.title, "body": t.body, "posted": false]); return }
            print("TITLE\n\(t.title)\n\nBODY\n\(t.body)\n\n(Not posted anywhere — copy it yourself.)")
            return
        }
        var asking: Double?
        if let a = opt("ask") {
            guard let v = Double(a.replacingOccurrences(of: "$", with: "")) else { throw fail(PipelineError.badAskingPrice.localizedDescription, usage: true) }
            asking = v
        } else if s.currentRecordId != nil, let r = s.history.records.first(where: { $0.id == s.currentRecordId }), let p = r.askingPrice {
            asking = Double(p)
        }
        let r = try s.evaluateListing(asking: asking)
        s.saveToHistory(gate: r.priceGate, assessment: r)
        if json {
            emit(["record": opt(s.currentRecordId), "status": r.loopStatus.rawValue, "title": r.listing.title,
                  "description": r.listing.description, "blocking": r.listing.blockingDisclosures,
                  "notClaimed": r.listing.omittedClaims, "gate": gateDict(r.priceGate)])
            return
        }
        print(r.loopStatus.rawValue.replacingOccurrences(of: "_", with: " ") + (r.priceGate.floor.map { "  ·  \(r.priceGate.floorQuotable ? "wholesale floor" : "expired floor reference") $\(dollars($0))" } ?? "  ·  wholesale gate: \(r.priceGate.status)"))
        r.listing.blockingDisclosures.forEach { print("BLOCKED: \($0)") }
        if r.loopStatus == .NEEDS_HUMAN_PRICE { print("Add --ask N (your asking price) to finish the listing.") }
        print("\nTITLE\n\(r.listing.title)\n\nDESCRIPTION\n\(r.listing.description)")
        if !r.listing.omittedClaims.isEmpty { print("\nNot claimed (verify these to include them):"); r.listing.omittedClaims.forEach { print("  • \($0)") } }
        print("\nSaved to history record #\(s.currentRecordId ?? 0).")
    }

    // MARK: comps / range
    func compsQuery(_ s: AppState) throws -> CompsQuery {
        guard var q = s.compsQuery() else { throw fail("Need --model (or --id of a record that has one).", usage: true) }
        if let z = opt("zip") { q.zip = z }
        if let r = opt("radius") { guard let v = Int(r), v > 0 else { throw fail("--radius takes miles", usage: true) }; q.radiusMiles = v }
        return q
    }
    func buyPrice() throws -> Double? {
        guard let b = opt("buy") else { return nil }
        guard let v = Double(b.replacingOccurrences(of: "$", with: "")), v >= 0 else { throw fail("--buy takes a dollar amount", usage: true) }
        return v
    }
    func rangeSettings() throws -> RangeSettings {
        var r = CompsSettings.range
        if let m = opt("margin") { guard let v = Double(m) else { throw fail("--margin takes dollars", usage: true) }; r.marginOverFloor = v }
        if let d = opt("discount") { guard let v = Double(d) else { throw fail("--discount takes dollars", usage: true) }; r.discount = v }
        return r
    }
    static let iso = ISO8601DateFormatter()
    func compsDict(_ r: CompsReport) -> [String: Any] {
        ["query": plain(r.query), "errors": r.errors, "noComps": r.isEmpty,
         "sets": r.sets.map { c -> [String: Any] in
            var o: [String: Any] = ["source": c.source, "kind": c.kind.rawValue, "count": c.count,
                                    "fetchedAt": CLI.iso.string(from: c.fetchedAt), "url": opt(c.url), "note": opt(c.note),
                                    "prices": c.prices]
            o["stats"] = c.stats.map { ["n": $0.n, "min": $0.min, "max": $0.max, "mean": ($0.mean * 100).rounded() / 100,
                                         "median": $0.median, "p25": $0.p25, "p75": $0.p75] } as Any? ?? NSNull()
            return o
         }]
    }
    func printComps(_ r: CompsReport) {
        let q = r.query
        print("COMPS  \(q.model) \(q.storage > 0 ? "\(q.storage)GB " : "")· \(q.carrier) · grade \(q.grade) · \(q.city) \(q.zip), \(q.radiusMiles) mi")
        if r.isEmpty { print("  NO COMPS\(r.errors.isEmpty ? "" : " (fetch failed)") — no numbers shown rather than guessed.") }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        for c in r.sets {
            let head = "  \(c.source) [\(c.kind.rawValue)] n=\(c.count) fetched \(f.string(from: c.fetchedAt))"
            if let st = c.stats {
                print(head + (c.kind == .avgList ? "  avg $\(dollars(st.mean))"
                    : "  avg $\(dollars((st.mean).rounded())) median $\(dollars(st.median)) p25 $\(dollars(st.p25)) range $\(dollars(st.min))–$\(dollars(st.max))"))
            } else { print(head + "  no comps") }
            if let n = c.note { print("      \(n)") }
            if let u = c.url { print("      \(u)") }
        }
        r.errors.forEach { print("  ERROR: \($0)") }
    }
    func printRange(_ r: SuggestedRange) {
        let rt: String
        switch (r.low, r.high) {
        case let (l?, h?): rt = "$\(dollars(l)) – $\(dollars(h))"
        case let (l?, nil): rt = "≥ $\(dollars(l)) (no market high)"
        default: rt = "no range"
        }
        print("\nSUGGESTED LOCAL RANGE  \(rt)   (Atlas floor \(r.floor.map { "$\(dollars($0))" } ?? "none"))")
        if let pl = r.profitLow { print("  Profit vs $\(dollars(r.buyPrice ?? 0)) buy: $\(dollars(pl))\(r.profitHigh.map { " – $\(dollars($0))" } ?? "")") }
        r.explanation.forEach { print("  • \($0)") }
    }

    func comps() async throws {
        let s = try makeState()
        try session(s)
        let q = try compsQuery(s)
        if flags.contains("clear-asks") { LocalAskStore.clear(q.deviceKey) }
        if let a = opt("asks") {
            let src: String
            switch (opt("asks-source") ?? "marketplace").lowercased() {
            case "marketplace", "fb", "facebook": src = "Marketplace"
            case "offerup": src = "OfferUp"
            case "other": src = "Other"
            default: throw fail("--asks-source must be marketplace, offerup or other", usage: true)
            }
            let p = LocalAsks.parse(a)
            guard !p.isEmpty else { throw fail("No prices found in --asks. Example: --asks \"640, 675, $699\"", usage: true) }
            LocalAskStore.save(q.deviceKey, LocalAskEntry(source: src, prices: p, enteredAt: Date(), note: opt("note")))
            if !json { FileHandle.standardError.write(Data("Saved \(p.count) \(src) asks for \(q.deviceKey).\n".utf8)) }
        }
        let r = await CompsProvider.shared.report(q, refresh: flags.contains("refresh"), includeSwappa: !flags.contains("no-swappa"))
        if json { emit(compsDict(r)); return }
        printComps(r)
    }

    func rig(_ rest: [String]) async throws {
        guard rest.first == "run", rest.count >= 2 else { throw fail("Usage: pgctl rig run FOLDER [FOLDER2] [phone inputs]", usage: true) }
        let s = try makeState()
        try session(s)
        let rig = RigSession()
        if let e = rig.schemaError { throw fail("Rig schema: \(e)") }
        for f in rest.dropFirst() {
            let u = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { throw fail("Not a folder: \(f)") }
            rig.importFolder(u)
        }
        rig.retag()
        guard !rig.frames.isEmpty else { throw fail("No usable image frames in that folder.") }
        let say = { (m: String) in if !self.json { FileHandle.standardError.write(Data((m + "\n").utf8)) } }
        say("Session \(rig.sessionId): \(rig.frames.count) frames (\(rig.best(.exterior).count) exterior angles, \(rig.best(.screen).count) screen).")
        var errors: [String] = []
        for p in CapturePass.allCases where !rig.selection(p).isEmpty {
            say("Grading \(p.rawValue)…")
            await rig.gradePass(p, app: s)
            if let e = rig.lastError { errors.append("\(p.rawValue): \(e)") }
        }
        say("Auditing…")
        await rig.audit(app: s)
        if let e = rig.lastError { errors.append("audit: \(e)") }
        rig.apply(to: s)
        if let e = rig.lastError, !e.hasPrefix("No overall grade"), !errors.contains(where: { $0.hasSuffix(e) }) { errors.append(e) }
        let o = rig.outcome
        // Price in this same run: rig blockers (IMEI / iCloud not established) live only in memory.
        let gate = s.phoneModel.isEmpty ? nil : await s.priceGate()
        let d = s.deal(gate: gate, manualQuote: manualQuote)
        let graded = s.grade != nil || opt("grade") != nil
        if json {
            emit(["session": rig.sessionId, "dir": rig.dir.path, "record": opt(s.currentRecordId), "grade": s.grade.map { plain($0) } ?? NSNull(),
                  "categories": o.categories.map { ["name": $0.name, "grade": opt($0.grade), "notes": $0.notes, "pass": $0.pass.rawValue] },
                  "blockers": rig.blockers, "concerns": o.concerns, "photosNeeded": o.photosNeeded, "log": o.log, "errors": errors,
                  "deal": graded ? dealDict(d) as Any : NSNull()])
            return
        }
        for c in o.categories { print("  \(c.grade ?? "?")  \(c.name) — \(c.notes)") }
        if let g = s.grade { print(""); printGrade(g, backend: s.gradeBackendUsed) }
        else { print("\nNo overall AI grade — some categories need a human look.\(opt("grade").map { " Using your --grade \($0) for the price." } ?? " Re-run with --grade X to price it.")") }
        if !rig.blockers.isEmpty { print("\nBlockers (no buy numbers until cleared):"); rig.blockers.forEach { print("  • \($0)") } }
        if !o.log.isEmpty { print("\nLog:"); o.log.forEach { print("  \($0)") } }
        errors.forEach { print("error: \($0)") }
        if graded {
            print("\n" + (d.actionable && d.maxBuy != nil ? "MAX BUY $\(usd(d.maxBuy!))" : d.headline))
            print(d.detail)
        }
        print("\nFrames + record.json: \(rig.dir.path)")
        if let id = s.currentRecordId { print("Saved as history record #\(id). Next: pgctl price --id \(id)") }
    }

    func device() async throws {
        switch await DeviceReader.readFirst() {
        case .failure(let p): throw fail(p.message)
        case .success(let r):
            let d: [String: Any] = ["platform": r.platform.rawValue, "model": opt(r.marketingModel), "rawModel": r.rawModel,
                                    "storageGb": opt(r.storageGb), "os": opt(r.osVersion), "batteryHealth": opt(r.batteryHealthPercent), "batteryHealthEstimated": r.batteryHealthIsEstimate,
                                    "batteryCycles": opt(r.batteryCycles), "batteryLevel": opt(r.batteryLevel),
                                    "serial": opt(r.serial), "imei": opt(r.imei), "simCarrierHint": opt(r.simCarrierHint),
                                    "connection": opt(r.connection)]
            if json { emit(d); return }
            print("\(r.platform.rawValue): \(r.marketingModel ?? r.rawModel) (\(r.rawModel))")
            let wifi = (r.connection ?? "").lowercased() == "network"
            print("Via:      \(wifi ? "Wi-Fi (NOT plugged in — a synced iPhone nearby)" : r.connection ?? "USB")")
            if let s = r.storageGb { print("Storage:  \(s) GB") } else if r.storageUnreadable { print("Storage:  unreadable") }
            if let b = r.batteryHealthPercent { print("Battery:  \(b)% health\(r.batteryHealthIsEstimate ? " (est.)" : " (device-reported)")\(r.batteryCycles.map { ", \($0) cycles" } ?? "")") }
            else if r.batteryHealthUnreadable { print("Battery:  health unreadable") }
            if let o = r.osVersion { print("OS:       \(o)") }
            if let s = r.serial { print("Serial:   \(s)") }
            if let i = r.imei { print("IMEI:     \(i)") }
            if let c = r.simCarrierHint { print("SIM:      \(c) (SIM carrier, NOT a lock status)") }
            print("iCloud, carrier lock, original screen and pass/fail items are NOT read — check them by hand.")
        }
    }

    func history(_ rest: [String]) throws {
        let store = HistoryStore()
        let sub = rest.first ?? "list"
        func record(_ i: Int) throws -> HistoryRecord {
            guard rest.count > i, let id = Int(rest[i]), let r = store.records.first(where: { $0.id == id }) else { throw fail("No such record. Run pgctl history.") }
            return r
        }
        switch sub {
        case "list":
            if json { emit(plain(store.records)); return }
            if store.records.isEmpty { print("No phones graded yet."); return }
            let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
            for r in store.records {
                let bits = [r.maxBuy.map { "max $\(dollars($0))" }, r.loopStatus, r.gradeLogSyncedAt.map { _ in "synced to Postgres" }].compactMap { $0 }
                print("#\(r.id)  \(r.grade?.overall_grade ?? "–")  \(r.phoneModel)\(r.storageGb.map { " \($0)GB" } ?? "")  \(f.string(from: r.createdAt))\(bits.isEmpty ? "" : "  · " + bits.joined(separator: " · "))")
            }
        case "show":
            let r = try record(1)
            if json { emit(plain(r)); return }
            print("#\(r.id)  \(r.phoneModel)\(r.storageGb.map { " \($0)GB" } ?? "")  · \(CarrierLock(rawValue: r.carrierLock)?.label ?? r.carrierLock) · \(r.createdAt.formatted())")
            if let g = r.grade { printGrade(g, backend: r.backend) } else { print("No AI grade.") }
            if !r.checklist.isEmpty { print("Checklist:"); r.checklist.forEach { print("  \($0.value)  \($0.label)") } }
            if let n = r.notes { print("Notes: \(n)") }
            if let b = r.dealBreakdown { print("Max buy: \(b.formula)") }
            else if let m = r.maxBuy { print("Walk-away (old buffer rule) $\(dollars(m)) (floor \(r.floor.map { "$" + dollars($0) } ?? "?")\(r.flipKind.map { ", \($0)" } ?? ""))") }
            if let p = r.repairs, !p.isEmpty { print("Repairs: \(p.summary)") }
            if let s = r.floorStatus { print("Atlas: \(s)\(r.floorQuotable == false ? " (not quotable)" : "")") }
            if let l = r.loopStatus { print("Listing: \(l)\(r.askingPrice.map { " · asking $\($0)" } ?? "")") }
            if let t = r.listingTitle { print("  \(t)") }
            if !r.photoFiles.isEmpty { print("Photos: \(r.photoFiles.map { Paths.photos.appendingPathComponent($0).path }.joined(separator: "\n        "))") }
            if let a = r.gradeLogRecordId { print("Postgres: \(a)\(r.gradeLogSyncedAt.map { " (sent \($0.formatted()))" } ?? " (pending / unconfirmed)")") }
        case "delete":
            let r = try record(1)
            guard flags.contains("yes") else { throw fail("This deletes record #\(r.id) and its photos. Re-run with --yes.", usage: true) }
            store.delete(r); print("Deleted #\(r.id).")
        case "path": print(Paths.history.path)
        case _ where SaleCommand.names.contains(sub):
            let (id, cmd): (Int, SaleCommand)
            do { (id, cmd) = try SaleCommand.parse(rest) } catch let e as SaleCommand.ParseError { throw fail(e.message, usage: true) }
            guard var r = store.records.first(where: { $0.id == id }) else { throw fail("No such record. Run pgctl history.") }
            let at = try atDate() ?? Date()
            r.applySale { cmd.apply(to: &$0, at: at) }; store.upsert(r)
            printSale(r)
        case "note":
            guard rest.count > 2, let id = Int(rest[1]) else { throw fail("history note N TEXT", usage: true) }
            guard var r = store.records.first(where: { $0.id == id }) else { throw fail("No such record. Run pgctl history.") }
            do { r.notesLog = try MemoryNotes.appending(r.notesLog, rest.dropFirst(2).joined(separator: " "), at: try atDate() ?? Date()) }
            catch is MemoryNotes.EmptyNote { throw fail("Note text is empty.", usage: true) }
            store.upsert(r)
            if json { emit(["id": r.id, "notes": plain(r.notesLog ?? [])]) } else { (r.notesLog ?? []).forEach { print("\($0.at.formatted())  \($0.text)") } }
        case "notes":
            let r = try record(1)
            if json { emit(["id": r.id, "notes": plain(r.notesLog ?? [])]) } else { (r.notesLog ?? []).forEach { print("\($0.at.formatted())  \($0.text)") } }
        case "sale":
            let r = try record(1); printSale(r)
        case "sales":
            let m = store.saleSummary
            if json { emit(["sold": m.soldCount, "listed": m.listedCount, "avgDaysToSell": m.avgDaysToSell as Any,
                            "avgSoldVsListedPct": m.avgSoldVsListedPct as Any, "avgActualProfit": opt(m.avgActualProfit),
                            "totalRevenue": m.totalRevenue, "totalPurchase": m.totalPurchase, "totalActualProfit": m.totalActualProfit,
                            "phones": store.records.count]); return }
            print(m.text)
        case "cycle":
            let parts = PartsLogStore.all
            if rest.count > 1 {
                let r = try record(1), c = r.cashCycle(parts: parts)
                if json { emit(cycleJSON(c)); return }
                print("#\(r.id)  \(r.phoneModel)"); c.lines.forEach { print($0) }
                return
            }
            let m = store.cashCycleSummary
            if json { emit(["closed": m.closed.count, "open": m.open.count, "unknown": m.unknown.count,
                            "avgCycleDays": opt(m.avgCycleDays), "cashWeightedCycleDays": opt(m.cashWeightedCycleDays),
                            "avgDaysHeld": opt(m.avgDaysHeld), "avgDaysToCash": opt(m.avgDaysToCash), "turnsPerYear": opt(m.turnsPerYear),
                            "totalProfit": m.totalProfit, "annualizedReturn": opt(m.annualizedReturn), "cashOutNow": m.cashOutNow,
                            "assumedPayouts": m.assumedPayouts, "phones": (m.closed + m.open + m.unknown).map(cycleJSON)]); return }
            m.lines.forEach { print($0) }
        case "titles": for r in store.records { print("#\(r.id)  \(r.facts.title)") }   // read-only preview
        default: throw fail("history list | show N | delete N --yes | path | sale N | sales | cycle [N] | note N TEXT | notes N | set-listing N PRICE | sold N PRICE | unsold N | bought N PRICE | paid N | stats N CLICKS SAVES MESSAGES", usage: true)
        }
    }

    /// --at DATE (local "2026-10-16 19:30" or ISO 8601).
    func atDate() throws -> Date? {
        guard let s = opt("at") else { return nil }
        guard let d = CLIDate.parse(s) else { throw fail("--at: use \"2026-10-16 19:30\" (local) or ISO 8601", usage: true) }
        return d
    }

    func businessNotes(_ rest: [String]) throws {
        switch rest.first ?? "list" {
        case "list":
            let n = BusinessNotesStore.all
            if json { emit(["notes": plain(n)]) } else if n.isEmpty { print("No business notes yet.") } else { n.forEach { print("\($0.at.formatted())  \($0.text)") } }
        case "add":
            let n: [MemoryNote]
            do { n = try BusinessNotesStore.add(rest.dropFirst().joined(separator: " "), at: try atDate() ?? Date()) }
            catch is MemoryNotes.EmptyNote { throw fail("Note text is empty.", usage: true) }
            if json { emit(["notes": plain(n)]) } else { print("Added. \(n.count) business notes.") }
        default: throw fail("notes [list | add TEXT]", usage: true)
        }
    }

    func parts(_ rest: [String]) throws {
        switch rest.first ?? "list" {
        case "list":
            var p = PartsLogStore.all
            if let s = opt("record") { guard let id = Int(s) else { throw fail("--record N", usage: true) }; p = p.filter { $0.recordId == id } }
            if json { emit(["parts": plain(p), "total": PartsLedger.total(p), "count": p.count]); return }
            p.forEach { print("\($0.date.formatted(date: .abbreviated, time: .omitted))  $\(dollars($0.cost))  \($0.item) · \($0.supplier)\($0.recordId.map { " · phone #\($0)" } ?? "")") }
            print("Total $\(dollars(PartsLedger.total(p))) · \(p.count) purchases")
        case "add":
            guard let item = opt("item"), !item.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("parts add --item X --cost N", usage: true) }
            guard let c = opt("cost").flatMap({ Double($0.replacingOccurrences(of: "$", with: "")) }), c >= 0 else { throw fail("--cost must be a number ≥ 0", usage: true) }
            var rec: Int?
            if let s = opt("record") { guard let id = Int(s) else { throw fail("--record N", usage: true) }; rec = id }
            var date = Date()
            if let s = opt("date") { guard let d = CLIDate.parse(s) else { throw fail("--date: use 2026-10-16", usage: true) }; date = d }
            let p = PartPurchase(date: date, item: item, supplier: opt("supplier") ?? PartPurchase.defaultSupplier, cost: c, recordId: rec, note: opt("note"))
            PartsLogStore.add([p])
            if json { emit(["added": plain(p)]) } else { print("Added \(item) $\(dollars(c)).") }
        default: throw fail("parts [list | add --item X --cost N …]", usage: true)
        }
    }

    func cycleJSON(_ c: CashCycle) -> [String: Any] {
        ["id": c.recordId, "open": c.isOpen, "cycleDays": c.cycleDays as Any, "daysToList": c.daysToList as Any,
         "daysHeld": c.daysHeld as Any, "daysToCash": c.daysToCash as Any, "partsLeadDays": c.partsLeadDays as Any,
         "cashInAssumed": c.cashInAssumed, "cashTied": opt(c.cashTied), "partsEstimated": c.partsEstimated, "profit": opt(c.profit),
         "returnOnCash": opt(c.returnOnCash), "annualizedReturn": opt(c.annualizedReturn), "profitPerDay": opt(c.profitPerDay),
         "unknowns": c.unknowns]
    }

    /// Private sale tracking for one record (local terminal only; never buyer-facing).
    func printSale(_ r: HistoryRecord) {
        let s = r.sale ?? SaleTracking()
        if json {
            emit(["id": r.id, "sale": plain(s), "daysToSell": s.daysToSell() as Any, "soldVsListedPct": s.soldVsListedPct as Any,
                  "actualProfit": r.actualProfit as Any]); return
        }
        print("#\(r.id)  \(r.phoneModel)")
        print("  Listed: \(s.listingPrice.map { "$\($0)" } ?? "–")\(s.listedAt.map { " since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
        if s.priceHistory.count > 1 { print("  Price history: " + s.priceHistory.map { "$\($0.price)" }.joined(separator: " → ")) }
        print("  Sold: \(s.soldPrice.map { "$\($0)" } ?? "–")\(s.soldAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
        if let d = s.daysToSell() { print("  \(s.isSold ? "Days to sell" : "Days listed so far"): \(d)") }
        if let p = s.soldVsListedPct { print(String(format: "  Sold at %.0f%% of first list price", p)) }
        if let p = s.paidAt { print("  Payout landed \(p.formatted(date: .abbreviated, time: .omitted))") }
        print("  Paid: \(s.purchasePrice.map { "$" + dollars($0) } ?? "–")\(s.boughtAt.map { " on " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")  · Actual profit: \(r.actualProfit.map { "$" + dollars($0) } ?? "–")")
        if s.statsCheckedAt != nil { print("  Stats: \(s.clicks ?? 0) clicks · \(s.saves ?? 0) saves · \(s.messages ?? 0) messages (checked \(s.statsCheckedAt!.formatted()))") }
    }

    func quotes(_ rest: [String]) throws {
        let s = AppState()
        switch rest.first ?? "list" {
        case "list":
            if json { emit(plain(s.userQuotes)); return }
            if s.userQuotes.isEmpty { print("No saved buyer quotes."); return }
            for q in s.userQuotes {
                print("\(q.id.uuidString.prefix(8))  $\(dollars(q.quoted))  \(q.match)\(q.storage.map { " \($0)GB" } ?? "")\(q.lock.map { " · \($0)" } ?? "")  — \(q.buyer), \(q.dateApprox)\(q.requiresCondition.isEmpty ? "" : " · only if " + q.requiresCondition.joined(separator: ", "))")
            }
        case "add":
            guard let m = opt("model"), let b = opt("buyer"), let a = opt("amount").flatMap({ Double($0.replacingOccurrences(of: "$", with: "")) }), a > 0 else {
                throw fail("quotes add needs --model, --buyer and --amount (a real number a buyer said — never a guess)", usage: true)
            }
            let lock = opt("lock")
            if let l = lock, !["unlocked", "carrier locked", "att clean"].contains(l) { throw fail("--lock must be unlocked, \"carrier locked\" or \"att clean\"", usage: true) }
            let match = s.engine?.canonicalizeModel(m, interpreter: nil).0 ?? pyNorm(m)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            var req: [String] = []
            if flags.contains("aftermarket") { req.append("aftermarket_screen") }
            if flags.contains("cracked-back") { req.append("cracked_back") }
            let q = BuyerQuote(match: match, storage: opt("storage").flatMap(Int.init), lock: lock, buyer: b, quoted: a,
                               dateApprox: opt("date") ?? f.string(from: Date()), dateExactRecorded: true,
                               requiresCondition: req, supersedesLadder: true, note: opt("note") ?? "Entered with pgctl.")
            s.addBuyerQuote(q)
            print("Saved quote \(q.id.uuidString.prefix(8)): $\(dollars(a)) for \(match) from \(b).")
        case "delete":
            guard rest.count > 1, let q = s.userQuotes.first(where: { $0.id.uuidString.lowercased().hasPrefix(rest[1].lowercased()) }) else { throw fail("No quote with that ID. Run pgctl quotes.") }
            s.deleteBuyerQuote(q); print("Deleted quote \(q.id.uuidString.prefix(8)).")
        default: throw fail("quotes list | add … | delete ID", usage: true)
        }
    }

    func imei(_ rest: [String]) async throws {
        switch rest.first ?? "" {
        case "services":
            if json { emit(Sickw.knownServices.map { ["id": $0.id, "name": $0.name, "listPrice": $0.listPrice, "covers": $0.covers] }); return }
            for v in Sickw.knownServices { print("\(v.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(v.listPrice.padding(toLength: 7, withPad: " ", startingAt: 0)) \(v.name) — \(v.covers)") }
            print("Default: \(UserDefaults.standard.string(forKey: "sickwServiceId") ?? Sickw.defaultServiceId) (pgctl config set sickwServiceId ID). Prices: sickw.com/sample.txt list; your tier may differ.")
        case "set-key":
            // Reads the key from stdin (no echo on a terminal) straight into the Keychain. Never printed.
            let tty = isatty(STDIN_FILENO) == 1
            var oldT = termios()
            if tty {
                FileHandle.standardError.write(Data("SICKW API key (input hidden): ".utf8))
                tcgetattr(STDIN_FILENO, &oldT); var t = oldT; t.c_lflag &= ~tcflag_t(ECHO); tcsetattr(STDIN_FILENO, TCSANOW, &t)
            }
            let line = readLine(strippingNewline: true)
            if tty { tcsetattr(STDIN_FILENO, TCSANOW, &oldT); FileHandle.standardError.write(Data("\n".utf8)) }
            let key = (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw fail("No key read from stdin — nothing saved.") }
            guard Keychain.set(key, for: .sickwAPIKey) else { throw fail("Couldn't write to the Keychain.") }
            print("Saved SICKW API key to the Keychain (\(key.count) characters\(key.count == 31 ? "" : " — SICKW keys are usually 31; double-check it")). Verify with: pgctl imei balance")
        case "remove-key":
            Keychain.delete(.sickwAPIKey); print("Removed the SICKW API key from the Keychain.")
        case "balance":
            guard Keychain.has(.sickwAPIKey) else { throw fail("No SICKW API key saved. Paste it in PhoneGrader → Settings → SICKW IMEI checks.") }
            let (v, raw) = try await SickwClient.balance()
            if json { emit(["balance": opt(v), "raw": raw]); return }
            print(v.map { String(format: "SICKW balance: $%.2f", $0) } ?? "Unexpected reply: \(raw)")
        case "check":
            guard rest.count > 1 else { throw fail("imei check IMEI [--service ID] [--id N]", usage: true) }
            let imei = IMEI.normalized(rest[1])
            if let p = IMEI.problem(imei) { throw fail(p, usage: true) }
            let svc = opt("service") ?? (UserDefaults.standard.string(forKey: "sickwServiceId") ?? Sickw.defaultServiceId)
            guard Sickw.validServiceId(svc) else { throw fail("--service must be a numeric SICKW service ID (0–250)", usage: true) }
            guard Keychain.has(.sickwAPIKey) else { throw fail("No SICKW API key saved. Paste it in PhoneGrader → Settings → SICKW IMEI checks. Nothing was charged.") }
            let s = try makeState()
            try session(s)
            s.imeiText = imei
            guard let r = await s.runImeiCheck(service: svc) else { throw fail(s.imeiCheckError ?? "IMEI check failed.") }
            if json {
                emit(["record": opt(s.currentRecordId), "receipt": plain(r), "fields": SickwResponse.parse(r.raw).fields.map { [$0.key: $0.value] },
                      "checklist": [Checklist.icloud: opt(s.checklistValues[Checklist.icloud]), Checklist.imei: opt(s.checklistValues[Checklist.imei])],
                      "message": opt(s.imeiCheckMessage), "error": opt(s.imeiCheckError)])
                return
            }
            print("SICKW service \(svc)\(r.serviceName.map { " (\($0))" } ?? "") · \(imei)\(r.price.map { " · charged $\($0)" } ?? "")\(r.balanceAfter.map { " · balance $\($0)" } ?? "")")
            if let e = s.imeiCheckError { print("ERROR: \(e)") }
            print("iCloud/FMI: \(r.icloudClear.map { $0 ? "OFF/clear → PASS" : "ON/LOST → FAIL" } ?? "unclear → unanswered")")
            print("Blacklist:  \(r.imeiClean.map { $0 ? "CLEAN → PASS" : "BLACKLISTED → FAIL" } ?? "unclear → unanswered")")
            if let m = s.imeiCheckMessage, !m.isEmpty { print(m) }
            print("\nRAW\n\(r.raw)\n\nReceipt saved on history record #\(s.currentRecordId ?? 0).")
        default: throw fail("imei check IMEI [--service ID] | imei balance | imei services", usage: true)
        }
    }

    func share(_ rest: [String]) throws {
        guard let idText = rest.first, let id = Int(idText), let out = opt("png") else { throw fail("share N --png PATH [--mask-imei]", usage: true) }
        guard let r = HistoryStore().records.first(where: { $0.id == id }) else { throw fail("No history record #\(idText).") }
        guard let d = ListingPhoto.png(r, maskIMEI: flags.contains("mask-imei")) else { throw fail("Couldn't render the photo.") }
        let u = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try d.write(to: u)
        let t = r.listingText(location: UserDefaults.standard.string(forKey: "location") ?? ListingCopyGenerator.defaultLocation)
        if json { emit(["png": u.path, "title": t.title, "description": t.description]); return }
        print("Saved \(u.path)\n\n\(t.title)\n\n\(t.description)")
    }

    func receipt(_ rest: [String]) throws {
        guard let idText = rest.first, let id = Int(idText) else { throw fail("receipt N [--png PATH] [--text] [--mask-imei] [--no-price]", usage: true) }
        let store = HistoryStore()
        guard let r = store.records.first(where: { $0.id == id }) else { throw fail("No history record #\(id).") }
        let text = Receipt.text(r.receiptInput, ReceiptOptions(maskIMEI: flags.contains("mask-imei"), includeListingPrice: !flags.contains("no-price")))
        var pngPath: String?
        if let p = opt("png") {
            guard let d = ReceiptQR.png(text, scale: 10) else { throw fail("QR generation failed.") }
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            try d.write(to: u); pngPath = u.path
            guard ReceiptQR.decode(png: d) == text else { throw fail("Wrote \(u.path) but it did not decode back to the same text.") }
        }
        if json { emit(["record": id, "text": text, "chars": text.count, "png": opt(pngPath), "decodedOK": pngPath != nil]); return }
        if flags.contains("text") || pngPath == nil { print(text) }
        if let p = pngPath { FileHandle.standardError.write(Data("QR → \(p) (\(text.count) chars, decode check OK)\n".utf8)) }
    }

    func ladder(_ rest: [String]) throws {
        let s = AppState()
        switch rest.first ?? "status" {
        case "status":
            guard let ls = s.ladderStatus else { throw fail("Price data didn't load: \(s.loadError ?? "unknown")") }
            print("\(s.ladderSource): anchored \(ls.anchoredDate), delivery Friday \(ls.deliveryFriday), \(ls.rowsCached) rows.\n\(ls.verdict)")
        case "import":
            guard rest.count > 1 else { throw fail("ladder import FILE.json (atlas-ladder.json format; use scripts/refresh_atlas.py for a sheet export)", usage: true) }
            do {
                let l = try s.importLadder(from: URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath))
                print("Imported \(l.rows.count) rows, delivery Friday \(l.deliveryFriday). Restart the app to see it there.")
            } catch { throw fail("Import refused (nothing changed): \(error.localizedDescription)") }
        case "revert":
            s.revertToBundledLadder(); print("Back to the bundled price list. Restart the app to see it there.")
        default: throw fail("ladder status | import FILE | revert", usage: true)
        }
    }

    // Non-secret settings only. Secrets stay in the app's Settings → Keychain.
    enum Kind { case string, bool, double, int }
    static let settings: [(key: String, kind: Kind)] = [
        ("backend", .string), ("anthropicModel", .string), ("claudePath", .string), ("claudeModel", .string),
        ("ollamaHost", .string), ("ollamaVisionModel", .string), ("ollamaFallback", .bool),
        ("interpreterEnabled", .bool), ("interpreterModel", .string), ("gradeLogEnabled", .bool), ("gradeLogURL", .string), ("location", .string),
        ("autoDetectDevice", .bool), ("rigFolder", .string), ("rigFrameURLs", .string), ("rigPollSeconds", .double),
        ("rigRotation", .int), ("rigAuditEnabled", .bool), ("rigQwenEnabled", .bool),
        ("profitFloor", .double), ("dealMPG", .double), ("dealDefaultMiles", .double), ("gasPriceManual", .double),
        ("gasPriceAlwaysManual", .bool), ("partBackGlassAftermarket", .double), ("partBackGlassApple", .double),
        ("partScreenOEM", .double), ("partScreenAftermarket", .double), ("sickwServiceId", .string), ("openAIBaseURL", .string), ("openAIModel", .string), ("openAIVision", .string),
        ("compsZip", .string), ("compsCity", .string), ("compsRadiusMiles", .int),
        ("rangeMarginOverFloor", .double), ("rangeDiscount", .double),
    ]

    func config(_ rest: [String]) throws {
        _ = AppState()     // registers nothing, but keeps defaults identical to the app's
        let d = UserDefaults.standard
        switch rest.first ?? "list" {
        case "list":
            for s in CLI.settings { print("\(s.key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(d.object(forKey: s.key).map { "\($0)" } ?? "(default)")") }
        case "get":
            guard rest.count > 1, CLI.settings.contains(where: { $0.key == rest[1] }) else { throw fail("Unknown key. Run pgctl config list.", usage: true) }
            print(d.object(forKey: rest[1]).map { "\($0)" } ?? "(default)")
        case "set":
            guard rest.count > 2, let s = CLI.settings.first(where: { $0.key == rest[1] }) else { throw fail("config set KEY VALUE (keys: pgctl config list)", usage: true) }
            let v = rest[2]
            switch s.kind {
            case .string:
                if s.key == "backend", AIBackend(rawValue: v) == nil { throw fail("backend must be one of: \(AIBackend.cliNames)", usage: true) }
                if s.key == "sickwServiceId", !Sickw.validServiceId(v) { throw fail("sickwServiceId must be numeric 0–250", usage: true) }
                if s.key == "openAIVision", !["auto", "yes", "no"].contains(v) { throw fail("openAIVision must be auto, yes or no", usage: true) }
                d.set(v, forKey: s.key)
            case .bool:
                guard let b = ["true": true, "on": true, "yes": true, "1": true, "false": false, "off": false, "no": false, "0": false][v.lowercased()] else { throw fail("\(s.key) takes on/off", usage: true) }
                d.set(b, forKey: s.key)
            case .double: guard let x = Double(v) else { throw fail("\(s.key) takes a number", usage: true) }; d.set(x, forKey: s.key)
            case .int: guard let x = Int(v) else { throw fail("\(s.key) takes a whole number", usage: true) }; d.set(x, forKey: s.key)
            }
            print("\(s.key) = \(v)  (restart the app if it's open so it re-reads settings)")
        default: throw fail("config list | get KEY | set KEY VALUE", usage: true)
        }
    }

    func gradeLog(_ rest: [String]) async throws {
        guard rest.first == "send", rest.count > 1, let id = Int(rest[1]) else { throw fail("gradeLog send N --yes", usage: true) }
        let s = AppState()
        guard s.gradeLogEnabled else { throw fail("Postgres sending is off. Turn it on with: pgctl config set gradeLogEnabled on") }
        guard let r = s.history.records.first(where: { $0.id == id }) else { throw fail("No history record #\(id).") }
        guard flags.contains("yes") else {
            throw fail("This writes grade #\(id) to the configured Postgres endpoint plus a database receipt — \(r.gradeLogRecordId == nil ? "creates a new record" : "updates \(r.gradeLogRecordId!)"). Re-run with --yes.", usage: true)
        }
        let recId = try await GradeLogClient.send(r) { recId in
            try s.history.persistGradeLogIdentity(recordId: id, identity: recId)
        }
        if var cur = s.history.records.first(where: { $0.id == id }) {
            cur.gradeLogSyncedAt = Date(); s.history.upsert(cur)
        }
        print("Sent #\(id) → Postgres \(recId) (database receipt written).")
    }
}
#endif
