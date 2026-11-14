import SwiftUI
import PhoneGraderCore

struct RigView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var rig: RigSession
    var goTo: (Tab) -> Void
    #if os(iOS)
    @State private var showFolderImporter = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FlexRow {
                    Text("Rig — two-spin capture").font(.largeTitle.bold())
                    Spacer()
                    Button("New rig session") { rig.reset() }
                }
                if let e = rig.schemaError { Text("Schema error: \(e)").foregroundStyle(.red) }
                sources
                capture
                framesCard(.exterior)
                framesCard(.screen)
                gradeCard
                claimsCard
                if let e = rig.lastError { Text(e).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(20)
        }
        #if os(iOS)
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let u) = result { withSecurityScope(u) { rig.importFolder(u) } }
        }
        #endif
    }

    var sources: some View {
        Card(title: "1 · Frame sources") {
            #if os(macOS)
            HStack {
                TextField("Watch folder (new images are ingested)", text: $rig.folder).textFieldStyle(.roundedBorder)
                Button("Choose…") { if let u = pickFolder() { rig.folder = u.path } }
            }
            #else
            Text("On iPhone/iPad the rig reads the browser-fed camera slots below (e.g. the alexus cams) or a recorded folder from Files. Live folder watching is Mac-only.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            TextField("Browser-fed slots, comma-separated (e.g. https://alexus:8443/frame?cam=grader)", text: $rig.frameURLs)
                .textFieldStyle(.roundedBorder)
            FlexRow {
                Picker("Upright rotation", selection: $rig.rotationSetting) {
                    Text("Auto (portrait)").tag(-1); Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                }.pgWidth(260)
                Stepper("Poll every \(String(format: "%.1f", rig.pollSeconds)) s", value: $rig.pollSeconds, in: 0.2...10, step: 0.2)
                Spacer()
                #if os(macOS)
                Button("Import a recorded folder…") { if let u = pickFolder() { rig.importFolder(u) } }
                #else
                Button("Import a recorded folder…") { showFolderImporter = true }
                #endif
            }
        }
    }

    var capture: some View {
        Card(title: "2 · Capture (two spins)") {
            Text("Pass 1: screen OFF, start the turntable, then Start. Stop after one full revolution.").font(.callout)
            Text("Pass 2: wake the phone, Settings → Display & Brightness → Auto-Lock → Never, open Settings → General → About (then Battery → Battery Health, Parts and Service). Start, spin once, Stop.").font(.callout)
            FlexRow {
                ForEach(CapturePass.allCases, id: \.self) { p in
                    if rig.capturing == p {
                        Button("Stop \(p.rawValue)") { rig.stopCapture() }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button("Start \(p.label)") { rig.startCapture(p) }.disabled(rig.capturing != nil)
                    }
                }
                Spacer()
                Button("Re-tag by hash") { rig.retag() }
                Text("\(rig.frames.count) frames · passes done: \(rig.outcome.record.passesDone.map(\.rawValue).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func framesCard(_ p: CapturePass) -> some View {
        let best = rig.best(p)
        return Card(title: "\(p.label) — \(rig.frames.filter { $0.pass == p }.count) frames, best per angle: \(best.count)") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(best) { f in
                        VStack(spacing: 2) {
                            if let t = rig.thumbnail(f) { Image(platformImage: t).resizable().scaledToFit().frame(height: 120).cornerRadius(6) }
                            Text("\(f.slot) \(f.hashRef.prefix(6))").font(.caption2.monospaced())
                        }
                    }
                }
            }
        }
    }

    var gradeCard: some View {
        Card(title: "3 · Grade") {
            FlexRow {
                Text("Grader: \(rig.grader(state)?.label ?? "none — manual review")").font(.caption)
                Text("Screen OCR: \(rig.qwen(state)?.label ?? "off")").font(.caption)
                Text("Auditor: \(rig.auditor(state)?.label ?? "off")").font(.caption)
                Spacer()
                Toggle("Local Qwen OCR", isOn: $rig.qwenEnabled)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                Toggle("Auditor pass", isOn: $rig.auditEnabled)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            FlexRow {
                Button("Grade pass 1") { Task { await rig.gradePass(.exterior, app: state) } }
                Button("Read + grade pass 2") { Task { await rig.gradePass(.screen, app: state) } }
                Button("Audit") { Task { await rig.audit(app: state) } }
                if let b = rig.busy { ProgressView().controlSize(.small); Text(b).font(.caption) }
            }.disabled(rig.busy != nil || rig.capturing != nil)
            ForEach(Array(rig.outcome.categories.enumerated()), id: \.offset) { i, c in
                FlexRow {
                    Text(c.name).pgWidth(190, alignment: .leading)
                    Picker("", selection: Binding(get: { rig.outcome.categories[i].grade ?? "?" },
                                                  set: { rig.outcome.categories[i].grade = $0 == "?" ? nil : $0 })) {
                        ForEach(["?", "A", "B", "C", "D", "F"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).pgWidth(240).labelsHidden()
                    Text(c.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if rig.outcome.categories.isEmpty {
                Button("Grade by hand (no AI)") { rig.ensureManualCategories(.exterior); rig.ensureManualCategories(.screen) }
            }
            let agg = GradeAggregator.overall(rig.outcome.categories, checklist: state.checklistEntries)
            HStack {
                Text("Overall: \(agg.overall ?? "needs review")").font(.title2.bold()).foregroundStyle(gradeColor(agg.overall ?? "F"))
                Text(agg.reasons.joined(separator: " · ")).font(.caption)
            }
            let concerns = rig.outcome.concerns + agg.concerns + rig.blockers
            if !concerns.isEmpty { bullets(concerns, color: .orange) }
            FlexRow {
                Button("Use this grade → Price") { rig.apply(to: state); if state.grade != nil { goTo(.price) } }
                    .buttonStyle(.borderedProminent)
                Text("Max buy is blocked while IMEI status or iCloud is unknown.").font(.caption).foregroundStyle(.secondary)
            }
            if !rig.outcome.log.isEmpty {
                DisclosureGroup("Log") { ForEach(rig.outcome.log, id: \.self) { Text($0).font(.caption.monospaced()) } }
            }
        }
    }

    var claimsCard: some View {
        Card(title: "4 · Domain record (phone.schema.json \(rig.schema?.version.split(separator: "/").last.map(String.init) ?? ""))") {
            FlexRow {
                Picker("IMEI Status", selection: Binding(get: { rig.outcome.record.value("IMEI Status").description },
                                                         set: { rig.setHumanClaim("IMEI Status", $0) })) {
                    ForEach(["UNKNOWN", "Clean", "Flagged", "Unknown", "N/A"], id: \.self) { Text($0).tag($0) }
                }.pgWidth(230)
                Picker("iCloud", selection: Binding(get: { rig.outcome.record.value("icloud_lock").description },
                                                    set: { rig.setHumanClaim("icloud_lock", $0) })) {
                    ForEach(["UNKNOWN", "clean", "Activation Locked"], id: \.self) { Text($0).tag($0) }
                }.pgWidth(230)
                Text("(you, verified — immovable by camera/AI)").font(.caption).foregroundStyle(.secondary)
            }
            if let s = rig.schema {
                ForEach(s.order.filter { s.fields[$0]?.pass != nil || rig.outcome.record.claims[$0] != nil }, id: \.self) { f in
                    let st = rig.outcome.record.state(of: f, schema: s)
                    let c = rig.outcome.record.claims[f]
                    FlexRow {
                        Text(f).pgWidth(150, alignment: .leading).font(.callout.monospaced())
                        Text(c?.value.description ?? "UNKNOWN").pgWidth(200, alignment: .leading).textSelection(.enabled)
                        Text(st.rawValue).foregroundStyle(st == .terminal ? .orange : st == .known ? .green : .secondary).pgWidth(70)
                        Text(c.map { "\($0.source.rawValue) \($0.ref ?? "")" } ?? "").font(.caption).foregroundStyle(.secondary)
                        if let n = c?.note { Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            if !rig.outcome.record.rejected.isEmpty {
                DisclosureGroup("Refused claims (\(rig.outcome.record.rejected.count))") {
                    ForEach(Array(rig.outcome.record.rejected.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                }
            }
        }
    }

    #if os(macOS)
    func pickFolder() -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }
    #endif
}
