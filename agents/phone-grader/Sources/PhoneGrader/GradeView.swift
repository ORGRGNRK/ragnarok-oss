import SwiftUI
import UniformTypeIdentifiers
import PhoneGraderCore
#if os(iOS)
import PhotosUI
#endif

struct GradeView: View {
    @EnvironmentObject var state: AppState
    var goTo: (Tab) -> Void
    @State private var dropTargeted = false
    #if os(iOS)
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Grade a phone").font(.largeTitle.bold())
                #if os(macOS)
                DevicePanel()     // USB reader (libimobiledevice / adb) — Mac only
                #endif
                photos
                FlexRow(alignment: .top, spacing: 14) {
                    checklist
                    details
                }
                ImeiCheckPanel()
                FlexRow {
                    Button {
                        Task { await state.runGrade() }
                    } label: {
                        Label(state.isGrading ? "Grading…" : "Grade with \(state.backend.shortName)", systemImage: "wand.and.stars")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(state.isGrading || state.photos.isEmpty)
                    if state.isGrading { ProgressView().controlSize(.small); Text("usually 15–30 seconds…").foregroundStyle(.secondary) }
                    Spacer()
                    Text("Backend: \(state.backend.label)").font(.caption).foregroundStyle(.secondary)
                }
                if state.backend == .appleOnDevice || (state.backend == .openAICompatible && !state.openAIVisionEnabled) {
                    Text("Text-only backend: it reads your checklist, device info, notes and on-screen text in the photos (Apple Vision OCR), but it cannot see cracks, scratches or dents. Check cosmetics yourself.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let e = state.gradeError {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Grading failed").font(.headline).foregroundStyle(.red)
                            Spacer()
                            Button("Copy error") { copyToPasteboard(e) }
                        }
                        ScrollView {
                            Text(e).font(.callout.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 60, maxHeight: 220)
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                }
                if let g = state.grade { GradeCard(grade: g, model: state.phoneModel, backend: state.gradeBackendUsed)
                    HStack {
                        Button("Price it →") { goTo(.price) }.buttonStyle(.borderedProminent)
                        Button("Listing →") { goTo(.listing) }
                    }
                }
            }.padding(20)
        }
        #if os(iOS)
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for (i, it) in items.enumerated() {
                    if let d = try? await it.loadTransferable(type: Data.self) { state.addPhotoData(d, name: "library-\(i + 1).jpg") }
                }
                libraryItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                if let d = img.jpegData(compressionQuality: 0.95) { state.addPhotoData(d, name: "camera-\(state.photos.count + 1).jpg") }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls { withSecurityScope(u) { if let d = try? Data(contentsOf: u) { state.addPhotoData(d, name: u.lastPathComponent) } } }
        }
        #endif
    }

    #if os(iOS)
    /// iPhone/iPad: camera, photo library or Files instead of the Mac's open panel / drag-and-drop.
    var addPhotoTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            PhotosPicker(selection: $libraryItems, maxSelectionCount: max(1, Grader.maxPhotos - state.photos.count), matching: .images) {
                Label("Photo library", systemImage: "photo.on.rectangle")
            }
            Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
        }
        .font(.callout)
        .frame(width: 160, height: 120)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(.secondary))
    }
    #endif

    var photos: some View {
        Card(title: "Photos (\(state.photos.count)/\(Grader.maxPhotos))") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(state.photos) { p in
                        ZStack(alignment: .topTrailing) {
                            Image(platformImage: p.thumbnail).resizable().scaledToFill().frame(width: 120, height: 120).clipped().cornerRadius(8)
                            Button { state.photos.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                                .buttonStyle(.plain).padding(4)
                        }
                    }
                    if state.photos.count < Grader.maxPhotos {
                        #if os(iOS)
                        addPhotoTile
                        #else
                        Button { pickPhotos() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.badge.plus").font(.largeTitle)
                                Text("Drop photos here\nor click to choose").font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(width: 160, height: 120)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary))
                        }.buttonStyle(.plain)
                        #endif
                    }
                }.padding(2)
            }
            Text("Front screen-on (white background), back, all four edges, camera lenses zoomed 2.5–3×, charging port, Settings → About parts & service, battery health.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for prov in providers {
                _ = prov.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { state.addPhotos([url]) } }
                }
            }
            return true
        }
    }

    #if os(macOS)
    func pickPhotos() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.message = "Choose up to \(Grader.maxPhotos - state.photos.count) phone photos"
        if p.runModal() == .OK { state.addPhotos(p.urls) }
    }
    #endif

    var checklist: some View {
        Card(title: "Human checklist (ground truth — you verified in person)") {
            ForEach(Checklist.items, id: \.label) { item in
                HStack {
                    Text(item.label).frame(maxWidth: .infinity, alignment: .leading)
                    if state.autoFilled.contains(item.label) { AutoTag() }
                    if item.isBattery {
                        TextField("e.g. 87", text: Binding(get: { state.checklistValues[item.label] ?? "" }, set: { state.setManualBattery($0) }))
                            .pgWidth(70).textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Text("%")
                        if state.batteryIsManual { Text("manual").font(.caption.bold()).foregroundStyle(.blue) }
                        else if state.autoFilled.contains(item.label), state.device?.batteryHealthIsEstimate == true { Text("est.").font(.caption.bold()).foregroundStyle(.orange) }
                    } else {
                        Picker("", selection: binding(item.label)) {
                            Text("—").tag(""); Text("Pass").tag("PASS"); Text("Fail").tag("FAIL")
                        }.pickerStyle(.segmented).pgWidth(170).labelsHidden()
                    }
                }
            }
            Text("Unanswered items are left out — nothing is ever claimed on a default. iCloud + IMEI are required before a normal listing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func binding(_ label: String) -> Binding<String> {
        Binding(get: { state.checklistValues[label] ?? "" }, set: { state.checklistValues[label] = $0 })
    }

    var details: some View {
        Card(title: "Phone") {
            HStack {
                TextField("Model (required), e.g. iPhone 14 Pro Max", text: $state.phoneModel).textFieldStyle(.roundedBorder)
                if state.autoFilled.contains("model") { AutoTag() }
            }
            HStack {
                TextField("Storage GB, e.g. 128", text: $state.storageText).textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if state.autoFilled.contains("storage") { AutoTag() }
            }
            Picker("Carrier / SIM", selection: $state.carrier) {
                ForEach(CarrierLock.allCases) { Text($0.label).tag($0) }
            }
            FlexRow {
                TextField("IMEI (15 digits)", text: $state.imeiText).textFieldStyle(.roundedBorder).font(.body.monospacedDigit())
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if state.autoFilled.contains("imei") { AutoTag() }
                Button(state.imeiChecking ? "Checking…" : "Check IMEI (SICKW)") { Task { await state.runImeiCheck() } }
                    .disabled(state.imeiChecking || IMEI.problem(state.imeiText) != nil || !Keychain.has(.sickwAPIKey))
            }
            Group {
                if let p = IMEI.problem(state.imeiText), !state.imeiText.isEmpty { Text(p).foregroundStyle(.red) }
                else if !Keychain.has(.sickwAPIKey) { Text("Add your SICKW API key in Settings to enable paid checks.").foregroundStyle(.secondary) }
                else { Text("Paid: service \(state.sickwService.id) \(state.sickwService.name) — list \(state.sickwService.listPrice) per check. Runs only when you press the button.").foregroundStyle(.secondary) }
            }.font(.caption)
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $state.notes).frame(height: 70).font(.body)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        }.pgWidth(340)
    }
}

struct GradeCard: View {
    let grade: GradeResult
    var model: String
    var backend: String
    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(grade.overall_grade).font(.system(size: 54, weight: .heavy)).foregroundStyle(gradeColor(grade.overall_grade))
                VStack(alignment: .leading) {
                    Text("Overall grade\(model.isEmpty ? "" : " — \(model)")").font(.title2.bold())
                    if !backend.isEmpty { Text("via \(backend)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            ForEach(grade.categories, id: \.self) { c in
                HStack(alignment: .top) {
                    Text(c.grade).font(.headline.monospaced()).foregroundStyle(gradeColor(c.grade)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.headline)
                        Text(c.notes).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !grade.concerns.isEmpty { Divider(); Text("Concerns").font(.headline); bullets(grade.concerns, color: .orange) }
            if !grade.photos_needed.isEmpty { Divider(); Text("Photos that would help").font(.headline); bullets(grade.photos_needed) }
            if !grade.summary.isEmpty { Divider(); Text("Summary").font(.headline); Text(grade.summary).textSelection(.enabled) }
        }
    }
}


struct AutoTag: View {
    var body: some View {
        Text("AUTO").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.2))).foregroundStyle(.blue)
            .help("Read from the device over USB — check it")
    }
}

#if os(macOS)
/// USB "Plug in phone" reader — macOS only (needs Process + libimobiledevice / adb).
struct DevicePanel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Card(title: "Phone connection") {
            HStack {
                Button { Task { await state.readDevice() } } label: {
                    Label(state.readingDevice ? "Reading…" : "Plug in phone", systemImage: "cable.connector")
                }
                .buttonStyle(.borderedProminent).disabled(state.readingDevice)
                if state.readingDevice { ProgressView().controlSize(.small) }
                Toggle("Auto-detect when a phone connects", isOn: Binding(get: { state.autoDetectDevice }, set: { state.setAutoDetect($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
            }
            if let p = state.deviceProblem {
                Label(p.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let d = state.device {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    row("Device", "\(d.marketingModel ?? "Unknown model") (\(d.rawModel))\(d.connection.map { " · \($0)" } ?? "")")
                    if let s = d.storageGb { row("Storage", "\(s) GB") }
                    else if d.platform == .iOS && d.storageUnreadable { row("Storage", "not readable from this phone — enter it from Settings > General > About") }
                    if let v = d.osVersion { row("OS", d.platform == .iOS ? "iOS \(v)" : v) }
                    if let s = d.serial { row("Serial", s, copy: true) }
                    if let i = d.imei { row("IMEI", i + "  (run your blacklist check — not auto-verified)", copy: true, copyValue: i) }
                    if let h = d.batteryHealthPercent { row("Battery", "\(d.batteryHealthIsEstimate ? "~\(h)% health (est. — floor of nominal ÷ design capacity; Settings may differ ±1)" : "\(h)% health (device-reported)")\(d.batteryCycles.map { ", \($0) cycles" } ?? "")\(d.batteryLevel.map { ", \($0)% charged" } ?? "")") }
                    else if d.platform == .iOS && d.batteryHealthUnreadable {
                        row("Battery", ([d.batteryLevel.map { "\($0)% charged" }, d.batteryCycles.map { "\($0) cycles" }].compactMap { $0 } + ["health not readable on this iOS — check Settings > Battery"]).joined(separator: ", "))
                    }
                    else if d.batteryLevel != nil || d.batteryHealthText != nil {
                        row("Battery", [d.batteryLevel.map { "\($0)% charged" }, d.batteryHealthText.map { "health: \($0)" }, d.batteryCycles.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: ", "))
                    }
                    if let c = d.simCarrierHint { row("SIM carrier", "\(c) — SIM info only, NOT a carrier-lock check") }
                }
                Text("Auto-filled: \(state.autoFilled.isEmpty ? "nothing" : state.autoFilled.map { $0 == Checklist.battery ? "battery health" : $0 }.sorted().joined(separator: ", ")). iCloud / FRP, IMEI blacklist, carrier lock and original screen are never read from the device — check them yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder func row(_ k: String, _ v: String, copy: Bool = false, copyValue: String? = nil) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            HStack {
                Text(v).textSelection(.enabled)
                if copy { Button("Copy") { copyToPasteboard(copyValue ?? v) }.controlSize(.small) }
            }
        }
    }
}

#endif

/// Latest SICKW result: parsed fields + full raw response (selectable), plus what it changed.
struct ImeiCheckPanel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.imeiCheckError != nil || !state.imeiChecks.isEmpty {
            Card(title: "IMEI check (SICKW)") {
                if let e = state.imeiCheckError { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                if let m = state.imeiCheckMessage, !m.isEmpty { Text(m).font(.callout).textSelection(.enabled) }
                if let r = state.imeiChecks.last {
                    let parsed = SickwResponse.parse(r.raw)
                    Text("Service \(r.serviceId)\(r.serviceName.map { " · \($0)" } ?? "") · \(r.checkedAt.formatted(date: .abbreviated, time: .standard))\(r.price.map { " · charged $\($0)" } ?? "")\(r.balanceAfter.map { " · balance $\($0)" } ?? "")\(r.orderId.map { " · order \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    FlexRow(spacing: 16) {
                        verdict("iCloud / FMI", r.icloudClear, yes: "OFF / clear", no: "ON or LOST")
                        verdict("Blacklist", r.imeiClean, yes: "CLEAN", no: "BLACKLISTED")
                        if let s = r.simLock { Text("SIM-lock: \(s)").font(.callout) }
                    }
                    if !parsed.fields.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                            ForEach(Array(parsed.fields.enumerated()), id: \.offset) { _, f in
                                GridRow { Text(f.key).foregroundStyle(.secondary); Text(f.value).textSelection(.enabled) }
                            }
                        }.font(.callout)
                    }
                    DisclosureGroup("Raw response") {
                        ScrollView { Text(r.raw).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 180)
                        Button("Copy raw") { copyToPasteboard(r.raw) }
                    }
                }
            }
        }
    }
    func verdict(_ name: String, _ v: Bool?, yes: String, no: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: v == true ? "checkmark.seal.fill" : v == false ? "xmark.octagon.fill" : "questionmark.circle")
                .foregroundStyle(v == true ? .green : v == false ? .red : .secondary)
            Text("\(name): \(v == true ? yes : v == false ? no : "unclear — left unanswered")")
        }.font(.callout)
    }
}
