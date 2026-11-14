import SwiftUI
import PhoneGraderCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("backend") var backendRaw = AIBackend.anthropicAPI.rawValue
    @AppStorage("anthropicModel") var anthropicModel = Grader.defaultModel
    @AppStorage("claudePath") var claudePath = ""
    @AppStorage("claudeModel") var claudeModel = ""
    @AppStorage("ollamaHost") var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ollamaVisionModel") var ollamaVisionModel = "qwen2.5vl:7b"
    @AppStorage("ollamaFallback") var ollamaFallback = false
    @AppStorage("interpreterEnabled") var interpreterEnabled = false
    @AppStorage("interpreterModel") var interpreterModel = "qwen2.5:3b-instruct"
    @AppStorage("gradeLogURL") var gradeLogURL = ""
    @AppStorage("gradeLogEnabled") var gradeLogEnabled = false
    @AppStorage("location") var location = ListingCopyGenerator.defaultLocation
    @AppStorage("openAIBaseURL") var openAIBaseURL = OpenAICompat.lmStudioBase
    @AppStorage("openAIModel") var openAIModel = ""
    @AppStorage("openAIVision") var openAIVision = "auto"
    @AppStorage(DealSettings.Key.profitTarget) var profitTarget = DealDefaults.profitTarget
    @AppStorage(DealSettings.Key.mpg) var mpg = DealDefaults.mpg
    @AppStorage(DealSettings.Key.defaultMiles) var defaultMiles = DealDefaults.roundTripMiles
    @AppStorage(DealSettings.Key.manualGasPrice) var manualGas = DealDefaults.manualGasPrice
    @AppStorage(DealSettings.Key.alwaysManualGas) var alwaysManualGas = false
    @AppStorage(DealSettings.Key.backGlassAftermarket) var bgAftermarket = PartCosts.placeholder.backGlassAftermarket
    @AppStorage(DealSettings.Key.backGlassApple) var bgApple = PartCosts.placeholder.backGlassApple
    @AppStorage(DealSettings.Key.screenOEM) var scOEM = PartCosts.placeholder.screenOEM
    @AppStorage(DealSettings.Key.screenAftermarket) var scAftermarket = PartCosts.placeholder.screenAftermarket
    @State private var gasMessage = ""
    @State private var localModels: [String] = []
    @State private var localStatus = ""
    @State private var appleStatus = AppleModelStatus.check()
    @AppStorage("sickwServiceId") var sickwServiceId = Sickw.defaultServiceId
    @State private var sickwField = ""
    @State private var hasSickw = Keychain.has(.sickwAPIKey)
    @State private var sickwBalance = ""

    @State private var keyField = ""
    @State private var hasKey = Keychain.has(.anthropicAPIKey)
    @State private var patField = ""
    @State private var hasPAT = Keychain.has(.gradeLogToken)
    @State private var cliStatus = ""
    @State private var ollamaStatus = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("SICKW API key") {
                    HStack {
                        SecureField("SICKW API key", text: $sickwField,
                                    prompt: Text(hasSickw ? "saved — paste a new key to replace" : "paste key (XXX-XXX-XXX-…)"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            #if os(macOS)
                            .frame(minWidth: 280)
                            #endif
                            .accessibilityIdentifier("sickwKeyField")
                        Button("Save") {
                            if Keychain.set(sickwField.trimmingCharacters(in: .whitespacesAndNewlines), for: .sickwAPIKey) { hasSickw = true }
                            sickwField = ""; sickwBalance = ""
                        }.disabled(sickwField.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") { Keychain.delete(.sickwAPIKey); hasSickw = false; sickwBalance = "" }.disabled(!hasSickw)
                    }
                }
                Text(hasSickw ? "✓ Key stored in \(keychainName) — never shown, logged or saved in history." : "No key stored yet. Get it from sickw.com → API access, paste it above, press Save.\(onMac ? " (Terminal alternative: pgctl imei set-key)" : "")")
                    .font(.caption).foregroundStyle(hasSickw ? .green : .orange)
                LabeledContent("Check balance") {
                    HStack {
                        Button("Check balance (free)") { checkSickwBalance() }.disabled(!hasSickw)
                        Text(sickwBalance).font(.caption).textSelection(.enabled)
                    }
                }
                Picker("Service", selection: $sickwServiceId) {
                    ForEach(Sickw.knownServices) { s in Text("\(s.id) · \(s.name) · \(s.listPrice) — \(s.covers)").tag(s.id) }
                    if Sickw.service(sickwServiceId) == nil { Text("\(sickwServiceId) · custom").tag(sickwServiceId) }
                }
                LabeledContent("Custom service ID") {
                    TextField("Service ID", text: $sickwServiceId).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                }
                Text("Prices are sickw.com's public list (sample.txt); your account tier may differ — the real charge is shown on each result. Checks run only when you press 'Check IMEI (SICKW)' on the Grade tab.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("SICKW IMEI checks (paid, sickw.com)", systemImage: "checkmark.shield").font(.headline)
            }
            Section("AI backend for grading") {
                Picker("Backend", selection: $backendRaw) {
                    ForEach(AIBackend.available) { Text($0.label).tag($0.rawValue) }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.inline)
                #endif
                Text("Used by Grade, pgctl grade, and the Rig grader/auditor where the backend can see photos (text-only backends leave rig damage to manual review).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple on-device model (Apple Intelligence)") {
                HStack {
                    Image(systemName: appleStatus.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appleStatus.available ? .green : .orange)
                    Text(appleStatus.reason).textSelection(.enabled)
                    Spacer()
                    Button("Re-check") { appleStatus = AppleModelStatus.check() }
                }
                Text("Free and private, but text-only: it grades from your checklist, device info, notes and text read off the photos (e.g. Settings → Battery). It can't judge cosmetic damage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local server (OpenAI-compatible)") {
                HStack {
                    TextField("Base URL", text: $openAIBaseURL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                    Button("LM Studio") { openAIBaseURL = OpenAICompat.lmStudioBase }
                    Button("Ollama") { openAIBaseURL = OpenAICompat.ollamaBase }
                }
                HStack {
                    if localModels.isEmpty { TextField("Model", text: $openAIModel) }
                    else {
                        Picker("Model", selection: $openAIModel) {
                            if !localModels.contains(openAIModel) { Text(openAIModel.isEmpty ? "(choose)" : openAIModel).tag(openAIModel) }
                            ForEach(localModels, id: \.self) { Text($0 + (OpenAICompat.looksVisionCapable($0) ? "  👁" : "")).tag($0) }
                        }
                    }
                    Button("Load models") { loadLocalModels() }
                }
                Picker("Send photos", selection: $openAIVision) {
                    Text("Auto (by model name)").tag("auto"); Text("Yes — vision model").tag("yes"); Text("No — text-only").tag("no")
                }
                Text(localStatus).font(.caption).textSelection(.enabled)
                if !onMac {
                    Text("On iPhone/iPad, localhost / 127.0.0.1 is this device. Use your server's address instead, e.g. http://your-fedora-box.tailnet-name.ts.net:1234/v1 over Tailscale.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Anthropic API") {
                HStack {
                    SecureField(hasKey ? "Key saved in Keychain (enter a new one to replace)" : "sk-ant-…", text: $keyField)
                    Button("Save") { if Keychain.set(keyField.trimmingCharacters(in: .whitespacesAndNewlines), for: .anthropicAPIKey) { hasKey = true }; keyField = "" }
                        .disabled(keyField.isEmpty)
                    Button("Remove") { Keychain.delete(.anthropicAPIKey); hasKey = false }.disabled(!hasKey)
                }
                Text(hasKey ? "✓ API key stored in \(keychainName)." : "No key stored.").font(.caption)
                TextField("Model", text: $anthropicModel)
            }
            #if os(macOS)
            Section("claude CLI (uses your Claude subscription)") {
                TextField("Path (blank = auto-detect)", text: $claudePath)
                TextField("Model override (blank = CLI default)", text: $claudeModel)
                HStack {
                    Button("Check CLI") { checkCLI() }
                    Text(cliStatus).font(.caption)
                }
            }
            #endif
            Section("Ollama (optional, local)") {
                TextField("Host", text: $ollamaHost)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                if !onMac {
                    Text("Base URL of your Ollama server. On iPhone/iPad 127.0.0.1 is this device — enter e.g. http://your-fedora-box.tailnet-name.ts.net:11434 (Tailscale) or http://192.168.x.x:11434.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Vision model for grading", text: $ollamaVisionModel)
                Toggle("Fall back to Ollama if the main backend fails", isOn: $ollamaFallback)
                Toggle("Use Ollama to interpret odd model names (price-mcp pass 4, labelled as a guess)", isOn: $interpreterEnabled)
                TextField("Interpreter model", text: $interpreterModel)
                HStack { Button("Check Ollama") { checkOllama() }; Text(ollamaStatus).font(.caption) }
            }
            Section("Max buy = Atlas floor − gas − repair parts − profit target") {
                money("Profit target", $profitTarget, key: DealSettings.Key.profitTarget, step: 5)
                number("MPG", $mpg, key: DealSettings.Key.mpg)
                number("Default round-trip miles (per deal, editable on the Price tab)", $defaultMiles, key: DealSettings.Key.defaultMiles)
                LabeledContent("Gas price") {
                    VStack(alignment: .trailing) {
                        let src = DealSettings.gasSource(override: nil)
                        Text("In use: $\(String(format: "%.3f", src.price))/gal — \(src.label)\(src.date.map { ", week of \($0)" } ?? "")")
                        if let f = DealSettings.eiaFetchedAt { Text("EIA last fetched \(f.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        if let e = DealSettings.eiaLastError { Text("Last EIA error: \(e)").font(.caption).foregroundStyle(.orange) }
                        HStack { Button("Refresh from EIA") { Task { gasMessage = await GasPriceService.refresh(force: true) } }; Text(gasMessage).font(.caption) }
                    }
                }
                money("Manual gas price $/gal (fallback)", $manualGas, key: DealSettings.Key.manualGasPrice, step: 0.10, decimals: 3)
                Toggle("Always use the manual gas price (ignore EIA)", isOn: $alwaysManualGas)
                Text("Gas price source: EIA weekly California regular gasoline average (series \(EIAGasPrice.seriesId)), read from EIA's public history page — no API key. If that fails, the last EIA value is used, then the manual price above. The Price tab also takes a per-deal $/gal override.")
                    .font(.caption).foregroundStyle(.secondary)
                money("Back glass — aftermarket", $bgAftermarket, key: DealSettings.Key.backGlassAftermarket)
                money("Back glass — Apple", $bgApple, key: DealSettings.Key.backGlassApple)
                money("Screen — OEM ($0 = enter your cost)", $scOEM, key: DealSettings.Key.screenOEM)
                money("Screen — aftermarket", $scAftermarket, key: DealSettings.Key.screenAftermarket)
                Text("PLACEHOLDER part costs (not researched prices) until you change them. \(RepairParts.atlasNote)")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("Listing") {
                TextField("Pickup location", text: $location)
            }
            Section("Buyer quotes (beat the ladder)") {
                if state.userQuotes.isEmpty { Text("None saved. Add from the Price tab.").font(.caption) }
                ForEach(state.userQuotes) { q in
                    HStack {
                        Text("\(q.match)\(q.storage.map { " \($0)GB" } ?? "")\(q.lock.map { " \($0)" } ?? "") — \(q.buyer) $\(dollars(q.quoted)) (\(q.dateApprox))")
                        Spacer()
                        Button(role: .destructive) { state.deleteBuyerQuote(q) } label: { Image(systemName: "trash") }
                    }
                }
            }
            Section("Postgres / NocoDB log (off by default)") {
                TextField("Grade log HTTPS endpoint", text: $gradeLogURL)
                Toggle("Enable the manual 'Send to Postgres' button", isOn: $gradeLogEnabled)
                HStack {
                    SecureField(hasPAT ? "Token saved in Keychain" : "Grade log service token", text: $patField)
                    Button("Save") { if Keychain.set(patField.trimmingCharacters(in: .whitespacesAndNewlines), for: .gradeLogToken) { hasPAT = true }; patField = "" }
                        .disabled(patField.isEmpty)
                    Button("Remove") { Keychain.delete(.gradeLogToken); hasPAT = false }.disabled(!hasPAT)
                }
                Text("Nothing is ever sent automatically. Destination \(GradeLogClient.destination), table Phone Grades.").font(.caption)
            }
            DataTransferSection()
        }
        .formStyle(.grouped)
        #if os(macOS)
        .padding()
        #else
        .buttonStyle(.borderless)     // several buttons in one Form row must stay separately tappable on iOS
        #endif
    }

    #if os(macOS)
    let onMac = true
    let keychainName = "your login Keychain"
    #else
    let onMac = false
    let keychainName = "this device's Keychain"
    #endif

    func placeholderTag(_ key: String) -> some View {
        Text(DealSettings.isPlaceholder(key) ? "placeholder" : "set").font(.caption2)
            .foregroundStyle(DealSettings.isPlaceholder(key) ? .orange : .secondary)
    }
    func money(_ label: String, _ v: Binding<Double>, key: String, step: Double = 1, decimals: Int = 2) -> some View {
        LabeledContent(label) {
            HStack {
                placeholderTag(key)
                Text("$")
                TextField(label, value: v, format: .number.precision(.fractionLength(0...decimals))).labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Stepper("", value: v, in: 0...10_000, step: step).labelsHidden()
            }
        }
    }
    func number(_ label: String, _ v: Binding<Double>, key: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(DealSettings.isPlaceholder(key) ? "default" : "set").font(.caption2).foregroundStyle(.secondary)
                TextField(label, value: v, format: .number.precision(.fractionLength(0...1))).labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
        }
    }

    func loadLocalModels() {
        localStatus = "checking…"
        Task {
            do {
                localModels = try await OpenAICompatBackend.models(baseURL: openAIBaseURL)
                localStatus = localModels.isEmpty ? "Server running, no models loaded." : "✓ \(localModels.count) models. 👁 = looks vision-capable (sends photos)."
                if openAIModel.isEmpty, let f = localModels.first { openAIModel = f }
            } catch { localStatus = "Not reachable: \(AIClient.friendly(error))" }
        }
    }

    func checkSickwBalance() {
        sickwBalance = "checking…"
        Task {
            do {
                let (v, raw) = try await SickwClient.balance()
                sickwBalance = v.map { String(format: "Balance: $%.2f", $0) } ?? "Unexpected reply: \(raw)"
            } catch { sickwBalance = error.localizedDescription }
        }
    }

    func checkCLI() {
        guard let exe = AIClient.findClaude(custom: claudePath) else { cliStatus = "claude not found"; return }
        cliStatus = "checking…"
        Task {
            do {
                let (code, out, _) = try await AIClient.run(exe, ["--version"], timeout: 15)
                cliStatus = code == 0 ? "✓ \(exe) — \(out.trimmingCharacters(in: .whitespacesAndNewlines))" : "claude exited \(code)"
            } catch { cliStatus = "failed: \(error.localizedDescription)" }
        }
    }

    func checkOllama() {
        ollamaStatus = "checking…"
        Task {
            guard let u = URL(string: ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags") else { ollamaStatus = "bad host"; return }
            var r = URLRequest(url: u); r.timeoutInterval = 4
            do {
                let (d, _) = try await URLSession.shared.data(for: r)
                let names = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                ollamaStatus = names.isEmpty ? "running, no models pulled" : "✓ " + names.joined(separator: ", ")
            } catch { ollamaStatus = "not reachable" }
        }
    }
}
