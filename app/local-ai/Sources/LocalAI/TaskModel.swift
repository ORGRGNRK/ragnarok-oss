import Combine
import Foundation
import SwiftUI
import AppKit

// MARK: - Tray

enum Tray: String, Codable, CaseIterable, Identifiable {
    case plan, queue, running, verify, human, done, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plan: "Planning"
        case .queue: "Waiting"
        case .running: "Working"
        case .verify: "Checking"
        case .human: "Needs you"
        case .done: "Done"
        case .failed: "Dead ends"
        }
    }
    var blurb: String {
        switch self {
        case .plan: "two AIs agree the steps first"
        case .queue: "next run takes the oldest"
        case .running: "an AI is on it now"
        case .verify: "a second AI is trying to say no"
        case .human: "only you can decide these"
        case .done: "every check passed"
        case .failed: "kept whole, with every reason"
        }
    }
}

// MARK: - Intent router

enum TaskIntent: String, Codable, CaseIterable, Identifiable {
    case script, code, message, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .script: "Run script"
        case .code: "Create code"
        case .message: "Message only"
        case .unknown: "Needs you"
        }
    }
    var systemImage: String {
        switch self {
        case .script: "terminal"
        case .code: "doc.badge.ellipsis"
        case .message: "bubble.left"
        case .unknown: "questionmark.circle"
        }
    }
    var blurb: String {
        switch self {
        case .script: "uses run_command"
        case .code: "uses write_file"
        case .message: "no tools, chat only"
        case .unknown: "router couldn't decide"
        }
    }
}

// MARK: - Checklist

struct ChecklistStep: Identifiable, Codable, Hashable {
    var id: UUID
    var description: String
    var verify: String
    var expect: String?
    var isHuman: Bool
    var isChecked: Bool
    var tries: Int
    var lastOutput: String?
    var lastExitCode: Int32?
    init(id: UUID = UUID(), description: String, verify: String, expect: String? = nil, isHuman: Bool = false, isChecked: Bool = false, tries: Int = 0) {
        self.id = id; self.description = description; self.verify = verify; self.expect = expect; self.isHuman = isHuman; self.isChecked = isChecked; self.tries = tries
    }
    var isDoNothing: Bool {
        let v = verify.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v.isEmpty || ["true", ":", "echo", "echo \"\"", "echo ''", "/bin/true"].contains(v)
    }
    var isEmptyCheck: Bool { verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct Leg: Identifiable, Codable, Hashable {
    var id: UUID
    var index: Int
    var seat: String
    var startedAt: Date
    var endedAt: Date?
    var verdict: String
    var notes: String
    init(index: Int, seat: String, verdict: String = "running", notes: String = "") {
        self.id = UUID(); self.index = index; self.seat = seat; self.startedAt = Date(); self.verdict = verdict; self.notes = notes
    }
}

struct HarnessBelt: Identifiable, Codable, Hashable {
    var id: String; var displayName: String; var specAlways: Bool; var refPrefix: String
    static let main = HarnessBelt(id: "main", displayName: "Main", specAlways: false, refPrefix: "conveyor:")
    static let incoming = HarnessBelt(id: "incoming", displayName: "Incoming", specAlways: true, refPrefix: "incoming:")
    static let outgoing = HarnessBelt(id: "outgoing", displayName: "Outgoing", specAlways: false, refPrefix: "outgoing:")
    static var defaults: [HarnessBelt] { [main, incoming, outgoing] }
}

struct HarnessTask: Identifiable, Codable, Hashable {
    var id: UUID; var title: String; var tray: Tray; var beltId: String; var createdAt: Date; var updatedAt: Date
    var intent: TaskIntent?; var intentReason: String?; var intentAt: Date?
    var checklist: [ChecklistStep]; var legs: [Leg]; var legCount: Int; var linkedConversationID: UUID?
    init(id: UUID = UUID(), title: String, tray: Tray = .queue, beltId: String = HarnessBelt.main.id, intent: TaskIntent? = nil, intentReason: String? = nil, checklist: [ChecklistStep] = [], legs: [Leg] = [], legCount: Int = 0, linkedConversationID: UUID? = nil) {
        self.id = id; self.title = title; self.tray = tray; self.beltId = beltId; self.createdAt = Date(); self.updatedAt = Date()
        self.intent = intent; self.intentReason = intentReason; self.intentAt = intent != nil ? Date() : nil
        self.checklist = checklist; self.legs = legs; self.legCount = legCount; self.linkedConversationID = linkedConversationID
    }
    var effectiveIntent: TaskIntent { intent ?? .unknown }
    enum ValidationError: LocalizedError, Equatable {
        case noSteps, stepHasNoCheck(Int), emptyCheck(Int), doNothingCheck(Int), humanStepInPlan(Int), alreadyTicked(Int)
        var errorDescription: String? {
            switch self {
            case .noSteps: return "Checklist has no steps"
            case .stepHasNoCheck(let i): return "Step \(i) has no verify field"
            case .emptyCheck(let i): return "Step \(i) has empty verify"
            case .doNothingCheck(let i): return "Step \(i) is a do-nothing check (true/:)"
            case .humanStepInPlan(let i): return "Step \(i) is HUMAN — planner must not create HUMAN steps"
            case .alreadyTicked(let i): return "Step \(i) arrived already ticked"
            }
        }
    }
    func validateForPlan() -> [ValidationError] {
        if effectiveIntent == .message { return [] }
        var errs: [ValidationError] = []
        if checklist.isEmpty { errs.append(.noSteps) }
        for (i, step) in checklist.enumerated() {
            if step.verify.trimmingCharacters(in: .whitespaces).isEmpty { errs.append(.stepHasNoCheck(i)); continue }
            if step.isEmptyCheck { errs.append(.emptyCheck(i)) }
            if step.isDoNothing { errs.append(.doNothingCheck(i)) }
            if step.isHuman { errs.append(.humanStepInPlan(i)) }
            if step.isChecked { errs.append(.alreadyTicked(i)) }
        }
        return errs
    }
    var isValidForQueue: Bool {
        if effectiveIntent == .message { return true }
        return !checklist.isEmpty && checklist.contains { !$0.isHuman && !$0.isEmptyCheck && !$0.isDoNothing }
    }
    var progress: Double {
        guard !checklist.isEmpty else { return effectiveIntent == .message ? 1 : 0 }
        return Double(checklist.filter(\.isChecked).count) / Double(checklist.count)
    }
    var failedSteps: [ChecklistStep] { checklist.filter { $0.tries >= 3 && !$0.isChecked } }
}

struct TaskArchive: Codable { var version: Int; var belts: [HarnessBelt]; var tasks: [HarnessTask] }

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [HarnessTask] = []
    @Published private(set) var belts: [HarnessBelt] = HarnessBelt.defaults
    @Published var selectedBeltId: String = HarnessBelt.main.id
    private static let fileName = "tasks.json"
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAI").appendingPathComponent(fileName)
    }
    init() { load() }
    func tasks(in tray: Tray, beltId: String? = nil) -> [HarnessTask] {
        let bid = beltId ?? selectedBeltId
        return tasks.filter { $0.tray == tray && $0.beltId == bid }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func allTasks(in beltId: String? = nil) -> [HarnessTask] {
        let bid = beltId ?? selectedBeltId
        return tasks.filter { $0.beltId == bid }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var selectedBelt: HarnessBelt { belts.first { $0.id == selectedBeltId } ?? .main }
    @discardableResult
    func add(title: String, beltId: String? = nil, checklist: [ChecklistStep] = []) -> HarnessTask {
        let task = HarnessTask(title: title, tray: .plan, beltId: beltId ?? selectedBeltId, checklist: checklist)
        tasks.append(task); save(); return task
    }
    @discardableResult
    func addStructured(title: String, checklist: [ChecklistStep], beltId: String? = nil) -> HarnessTask {
        let errors = HarnessTask(title: title, checklist: checklist).validateForPlan()
        let tray: Tray = errors.isEmpty ? .queue : .plan
        var task = HarnessTask(title: title, tray: tray, beltId: beltId ?? selectedBeltId, checklist: checklist)
        if !errors.isEmpty { task.legs.append(Leg(index: 1, seat: "runner", verdict: "invalid-plan", notes: errors.map(\.localizedDescription).joined(separator: "\n"))) }
        tasks.append(task); save(); return task
    }
    func setIntent(_ taskId: UUID, intent: TaskIntent, reason: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].intent = intent; tasks[i].intentReason = reason; tasks[i].intentAt = Date(); tasks[i].updatedAt = Date()
        if intent == .unknown { tasks[i].tray = .human }
        else if tasks[i].tray == .plan && intent == .message { tasks[i].tray = .queue }
        save()
    }
    func move(_ task: HarnessTask, to tray: Tray) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].tray = tray; tasks[i].updatedAt = Date(); tasks[i].legCount += (tray == .running ? 1 : 0); save()
    }
    func updateChecklist(_ taskId: UUID, checklist: [ChecklistStep]) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].checklist = checklist; tasks[i].updatedAt = Date(); save()
    }
    func appendLeg(_ taskId: UUID, leg: Leg) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].legs.append(leg); tasks[i].legCount = max(tasks[i].legCount, leg.index); tasks[i].updatedAt = Date(); save()
    }
    func approve(_ task: HarnessTask) {
        guard task.tray == .human else { return }
        if task.intent == .unknown {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].intent = nil; tasks[i].intentReason = nil; tasks[i].tray = .plan; tasks[i].updatedAt = Date(); save(); return
            }
        }
        move(task, to: .queue)
    }
    func link(_ task: HarnessTask, to conversationID: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].linkedConversationID = conversationID; tasks[i].updatedAt = Date(); save()
    }
    func delete(_ task: HarnessTask) { tasks.removeAll { $0.id == task.id }; save() }
    func addBelt(id: String, displayName: String, specAlways: Bool = false) {
        let clean = id.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !belts.contains(where: { $0.id == clean }) else { return }
        belts.append(HarnessBelt(id: clean, displayName: displayName, specAlways: specAlways, refPrefix: "\(clean):")); save()
    }
    private func load() {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(TaskArchive.self, from: data) {
            tasks = archive.tasks; belts = archive.belts.isEmpty ? HarnessBelt.defaults : archive.belts
            if !belts.contains(where: { $0.id == selectedBeltId }) { selectedBeltId = belts.first?.id ?? HarnessBelt.main.id }
            if archive.version < 3 { save() }; return
        }
        struct OldTask: Codable { var id: UUID; var title: String; var tray: Tray; var createdAt: Date; var updatedAt: Date; var linkedConversationID: UUID? }
        struct OldArchive: Codable { var version: Int; var tasks: [OldTask] }
        if let old = try? decoder.decode(OldArchive.self, from: data) {
            tasks = old.tasks.map { HarnessTask(id: $0.id, title: $0.title, tray: $0.tray, beltId: HarnessBelt.main.id, linkedConversationID: $0.linkedConversationID) }
            belts = HarnessBelt.defaults; save(); return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let corrupt = url.deletingLastPathComponent().appendingPathComponent("tasks.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: corrupt)
        tasks = []; belts = HarnessBelt.defaults
    }
    private func save() {
        let url = Self.fileURL
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(TaskArchive(version: 3, belts: belts, tasks: tasks)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Board view with detail inspector

struct TaskBoardView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var seats: SeatRegistry
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var serverManager: ServerManager
    @State private var newTitle = ""
    @State private var showAddBelt = false
    @State private var newBeltName = ""
    @State private var runner = HarnessRunner()
    @State private var isRunning = false
    @State private var lastMessage = ""
    @State private var autoRun = false
    @State private var selectedTaskID: UUID?
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 0) {
            beltPicker
            Divider()
            runBar
            Divider()
            HStack {
                TextField("New task", text: $newTitle).onSubmit { addNewTask() }
                Button("Add") { addNewTask() }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(8)
            Divider()
            List {
                ForEach(Tray.allCases) { tray in
                    let rows = store.tasks(in: tray)
                    if !rows.isEmpty || tray == .plan {
                        Section {
                            ForEach(rows) { task in
                                Button { selectedTaskID = task.id; showDetail = true } label: { TaskRow(task: task) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .contextMenu {
                                    Button("Open Detail") { selectedTaskID = task.id; showDetail = true }
                                    Divider()
                                    Button("Open Folder in Finder") { openFolder(for: task) }
                                    Button("Copy Folder Path") { copyPath(for: task) }
                                    Divider()
                                    if task.tray == .human { Button("Approve (back to queue)") { store.approve(task) } }
                                    ForEach(Tray.allCases) { dest in if dest != task.tray { Button("Move to \(dest.title)") { store.move(task, to: dest) } } }
                                    Divider()
                                    Button("Delete Task", role: .destructive) { store.delete(task) }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(tray.title) — \(tray.blurb)").font(.caption.bold())
                                Spacer()
                                if !rows.isEmpty { Text("\(rows.count)").foregroundStyle(.secondary).font(.caption) }
                            }
                        }
                    }
                }
            }.listStyle(.sidebar)
        }
        .sheet(isPresented: $showAddBelt) {
            VStack(spacing: 12) {
                Text("New Belt").font(.headline)
                TextField("Belt name (e.g. incoming)", text: $newBeltName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showAddBelt = false }
                    Spacer()
                    Button("Create") { store.addBelt(id: newBeltName, displayName: newBeltName); newBeltName = ""; showAddBelt = false }
                        .disabled(newBeltName.trimmingCharacters(in: .whitespaces).isEmpty).buttonStyle(.borderedProminent)
                }
            }.padding().frame(width: 320)
        }
        .sheet(isPresented: $showDetail) {
            if let id = selectedTaskID, let task = store.tasks.first(where: { $0.id == id }) ?? store.allTasks().first(where: { $0.id == id }) {
                TaskDetailView(task: task)
                    .environmentObject(store)
                    .frame(minWidth: 640, minHeight: 520)
            } else {
                Text("Task not found").padding()
            }
        }
        .task { seats.configure(modelManager: modelManager, serverManager: serverManager) }
    }

    private var beltPicker: some View {
        HStack(spacing: 8) {
            Picker("Belt", selection: $store.selectedBeltId) {
                ForEach(store.belts) { belt in Text("\(belt.displayName) (\(belt.id))").tag(belt.id) }
            }.pickerStyle(.menu).frame(maxWidth: 220)
            if store.selectedBelt.specAlways { Label("spec always", systemImage: "doc.badge.ellipsis").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { showAddBelt = true } label: { Image(systemName: "plus") }.help("Add belt")
        }.padding(8).background(.bar)
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            Button { runNext() } label: {
                if isRunning { HStack { ProgressView().controlSize(.small); Text("Running leg…") } }
                else { Label("Run next leg", systemImage: "play.fill") }
            }.buttonStyle(.borderedProminent).disabled(isRunning).help("⇧⌘R")
            Toggle("Auto", isOn: $autoRun).toggleStyle(.switch)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Driver: \(seats.driver?.displayName ?? "none")").font(.caption)
                    Text("· Verifier: \(seats.verifier?.displayName ?? "none")").font(.caption)
                }.foregroundStyle(.secondary)
                if !lastMessage.isEmpty { Text(lastMessage).font(.caption2).lineLimit(1).foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(8).background(Color(nsColor: .controlBackgroundColor))
        .task(id: autoRun) { guard autoRun else { return }; while autoRun { if !isRunning { runNext() }; try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }

    private func addNewTask() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let t = store.add(title: title)
        newTitle = ""
        selectedTaskID = t.id
        showDetail = true
    }
    private func runNext() {
        guard !isRunning else { return }
        isRunning = true
        seats.configure(modelManager: modelManager, serverManager: serverManager)
        Task {
            do {
                let result = try await runner.runNextLeg(in: store, registry: seats)
                await MainActor.run {
                    switch result {
                    case .noWork: lastMessage = "No work — all belts empty"
                    case .moved(let id, let tray, let msg): lastMessage = "Moved \(id.uuidString.prefix(4)) → \(tray.title): \(msg)"; if selectedTaskID == nil { selectedTaskID = id }
                    case .stayed(let id, let tray, let msg): lastMessage = "Stayed \(id.uuidString.prefix(4)) in \(tray.title): \(msg)"
                    case .failed(let id, let msg): lastMessage = "Failed \(id.uuidString.prefix(4)): \(msg)"
                    case .needSeat(let msg): lastMessage = "Need seat: \(msg)"
                    }
                    isRunning = false
                }
            } catch {
                await MainActor.run { lastMessage = "Runner error: \(error.localizedDescription)"; isRunning = false }
            }
        }
    }
    private func openFolder(for task: HarnessTask) {
        if let url = try? TaskFolder.ensure(for: task.id) { NSWorkspace.shared.open(url) }
    }
    private func copyPath(for task: HarnessTask) {
        if let url = try? TaskFolder.ensure(for: task.id) {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(url.path, forType: .string)
        }
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: HarnessTask
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let intent = task.intent {
                    Label(intent.label, systemImage: intent.systemImage).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(colorFor(intent).opacity(0.15))).foregroundStyle(colorFor(intent))
                }
                Text(task.title).lineLimit(1)
                Spacer()
                if !task.checklist.isEmpty || task.intent == .message {
                    ProgressView(value: task.progress).frame(width: 40)
                    Text("\(task.checklist.filter(\.isChecked).count)/\(max(task.checklist.count,1))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Label(task.tray.title, systemImage: trayIcon(task.tray)).font(.caption2).foregroundStyle(.secondary)
                Text(task.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                if task.legCount > 0 { Text("· \(task.legCount) legs").font(.caption2).foregroundStyle(.secondary) }
                if let reason = task.intentReason { Text("· \(reason)").lineLimit(1).font(.caption2).foregroundStyle(.secondary) }
                if !task.failedSteps.isEmpty { Label("\(task.failedSteps.count) stuck", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption2) }
            }
            if !task.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(task.checklist.prefix(3)) { step in
                        HStack(spacing: 4) {
                            Image(systemName: step.isChecked ? "checkmark.square.fill" : "square").foregroundStyle(step.isChecked ? .green : .secondary)
                            Text(step.description).lineLimit(1).strikethrough(step.isChecked)
                            if step.tries > 0 { Text("(\(step.tries)x)").font(.caption2).foregroundStyle(.orange) }
                        }.font(.caption)
                    }
                    if task.checklist.count > 3 { Text("+\(task.checklist.count - 3) more").font(.caption2).foregroundStyle(.secondary) }
                }.padding(.top, 2)
            }
        }.padding(.vertical, 2)
    }
    private func trayIcon(_ tray: Tray) -> String {
        switch tray { case .plan: "lightbulb"; case .queue: "clock"; case .running: "bolt"; case .verify: "checkmark.shield"; case .human: "person"; case .done: "checkmark.circle.fill"; case .failed: "xmark.octagon" }
    }
    private func colorFor(_ intent: TaskIntent) -> Color {
        switch intent { case .script: return .orange; case .code: return .blue; case .message: return .green; case .unknown: return .red }
    }
}

// MARK: - Detail inspector

struct TaskDetailView: View {
    @EnvironmentObject private var store: TaskStore
    let task: HarnessTask
    @State private var selectedFile: URL?
    @State private var fileContent: String = ""
    @State private var fileList: [URL] = []
    @State private var showRaw = false

    var body: some View {
        let liveTask = store.tasks.first(where: { $0.id == task.id }) ?? store.allTasks().first(where: { $0.id == task.id }) ?? task
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header(liveTask)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        checklistSection(liveTask)
                        legsSection(liveTask)
                    }.padding(12)
                }
            }.frame(minWidth: 360)
            VStack(alignment: .leading, spacing: 0) {
                filesHeader(liveTask)
                Divider()
                List(fileList, id: \.self, selection: $selectedFile) { url in
                    HStack {
                        Image(systemName: url.hasDirectoryPath ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                        Spacer()
                        Text(byteCount(url)).font(.caption2).foregroundStyle(.secondary)
                    }.tag(url as URL?)
                }.listStyle(.sidebar)
                Divider()
                if let sel = selectedFile {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(sel.lastPathComponent).font(.caption.bold()).lineLimit(1)
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(sel) }.font(.caption2)
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([sel]) }.font(.caption2)
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                        Divider()
                        ScrollView([.horizontal, .vertical]) {
                            Text(fileContent.isEmpty ? "(binary or empty)" : fileContent)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .textSelection(.enabled)
                        }.background(Color(nsColor: .textBackgroundColor))
                    }.frame(minHeight: 180)
                } else {
                    Text("Select a file to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 280)
        }
        .onAppear { refreshFiles(for: liveTask) }
        .onChange(of: liveTask.updatedAt) { refreshFiles(for: liveTask) }
        .onChange(of: selectedFile) { _, new in
            guard let url = new else { fileContent = ""; return }
            if let data = try? Data(contentsOf: url), data.count < 200_000 {
                fileContent = String(decoding: data, as: UTF8.self)
            } else { fileContent = "(too large to preview: \(byteCount(url)))" }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { if let u = try? TaskFolder.ensure(for: liveTask.id) { NSWorkspace.shared.open(u) } } label: { Label("Open in Finder", systemImage: "folder") }
            }
            ToolbarItem {
                Button { let pb = NSPasteboard.general; if let u = try? TaskFolder.ensure(for: liveTask.id) { pb.clearContents(); pb.setString(u.path, forType: .string) } } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            }
        }
    }

    private func header(_ t: HarnessTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(t.tray.title, systemImage: t.tray == .done ? "checkmark.circle.fill" : "circle").font(.headline)
                Spacer()
                Text(t.id.uuidString.prefix(8)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(t.title).font(.title3.bold()).textSelection(.enabled)
            HStack(spacing: 8) {
                if let intent = t.intent { Label(intent.label, systemImage: intent.systemImage).font(.caption).padding(4).background(Capsule().fill(Color.blue.opacity(0.12))) }
                Text("belt \(t.beltId)").font(.caption).foregroundStyle(.secondary)
                Text("\(t.legCount) legs").font(.caption).foregroundStyle(.secondary)
                Text(t.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            if let r = t.intentReason { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            ProgressView(value: t.progress).frame(height: 4)
            HStack {
                Text("\(t.checklist.filter(\.isChecked).count)/\(t.checklist.count) checks").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(t.tray.blurb).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private func checklistSection(_ t: HarnessTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checklist").font(.headline)
            if t.checklist.isEmpty { Text("No checklist yet — run planner leg").foregroundStyle(.secondary).font(.caption) }
            ForEach(t.checklist) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: step.isChecked ? "checkmark.square.fill" : "square").foregroundStyle(step.isChecked ? .green : .secondary)
                        Text(step.description).font(.callout).strikethrough(step.isChecked)
                        Spacer()
                        if step.tries > 0 { Text("\(step.tries)x").font(.caption2).foregroundStyle(.orange).padding(2).background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.12))) }
                    }
                    Text(step.verify).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 22).textSelection(.enabled)
                    if let out = step.lastOutput, !out.isEmpty {
                        DisclosureGroup("last output (\(step.lastExitCode ?? -1))") {
                            Text(out).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).padding(4).background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
                        }.font(.caption2)
                    }
                }.padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func legsSection(_ t: HarnessTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legs — what happened").font(.headline)
            if t.legs.isEmpty { Text("No legs yet").foregroundStyle(.secondary).font(.caption) }
            ForEach(t.legs.reversed()) { leg in
                DisclosureGroup {
                    ScrollView {
                        Text(leg.notes).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }.frame(maxHeight: 240).background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
                } label: {
                    HStack {
                        Text("#\(leg.index)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(leg.verdict).font(.caption.bold()).foregroundStyle(verdictColor(leg.verdict))
                        Text(leg.seat).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(leg.startedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func filesHeader(_ t: HarnessTask) -> some View {
        HStack {
            Label("Files", systemImage: "folder").font(.headline)
            Spacer()
            if let url = try? TaskFolder.ensure(for: t.id) {
                Text(url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Button { refreshFiles(for: t) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }.padding(8)
    }

    private func refreshFiles(for t: HarnessTask) {
        guard let base = try? TaskFolder.ensure(for: t.id) else { fileList = []; return }
        var urls: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator { urls.append(url) }
        }
        fileList = urls.sorted { $0.path < $1.path }
        if selectedFile == nil { selectedFile = fileList.first(where: { !$0.hasDirectoryPath }) }
    }

    private func byteCount(_ url: URL) -> String {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attr[.size] as? Int else { return "" }
        if size < 1024 { return "\(size)B" }
        if size < 1024*1024 { return "\(size/1024)KB" }
        return String(format: "%.1fMB", Double(size)/1024/1024)
    }

    private func verdictColor(_ v: String) -> Color {
        if v.contains("pass") || v.contains("done") || v.contains("approved") { return .green }
        if v.contains("fail") || v.contains("invalid") || v.contains("blocked") || v.contains("dead") { return .red }
        if v.contains("needs") { return .orange }
        return .secondary
    }
}
