import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Conveyor belt as a tab in Ragnarok (merged from app/belt-ui 2026-11-02; was its own Conveyor.app).
/// The old Settings window (AI providers) is the "AI providers" button on the board.
public struct BeltTab: View {
    @StateObject private var store = BeltStore()
    public init() {}
    public var body: some View {
        ContentView().environmentObject(store)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: BeltStore
    @State private var adding = false
    @State private var providers = false
    @State private var connecting = false
    @State private var open: BeltTask?

    var body: some View {
        Group {
            if store.root == nil {
                Welcome(connecting: $connecting)
            } else {
                VStack(spacing: 0) {
                    if let err = store.syncError {
                        Text(err).font(.callout).foregroundStyle(.white).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange)
                    }
                    board
                }
            }
        }
        .sheet(isPresented: $connecting) { ConnectRemote() }
        .sheet(isPresented: $adding) { AddTask() }
        .sheet(isPresented: $providers) { Providers(inSheet: true) }
        .sheet(item: $open) { TaskDetail(task: $0) }
    }

    private var board: some View {
        VSplitView {
            HStack(alignment: .top, spacing: 10) {
                // Planning shows only where the belt has it (or something is in it).
                ForEach(Tray.allCases.filter { $0 != .plan || store.planAvailable || !(store.tasks[.plan] ?? []).isEmpty }) { tray in
                    Column(tray: tray, tasks: store.tasks[tray] ?? []) { open = $0 }
                }
            }
            .padding(12)
            .frame(minHeight: 260)
            ActivityPanel()
                .frame(minHeight: 160, idealHeight: 260)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    if let remote = store.remote {
                        Image(systemName: store.syncError == nil ? "network" : "exclamationmark.triangle.fill")
                            .foregroundStyle(store.syncError == nil ? Color.secondary : Color.orange)
                        Text(remote.label).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(store.root?.path ?? "").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .help(store.syncError ?? "")
            }
            ToolbarItem {
                Menu {
                    Button("Use a folder on this Mac…") { pickFolder(store) }
                    Button("Connect to a belt on another computer…") { connecting = true }
                } label: { Label("Change belt", systemImage: "folder") }
            }
            ToolbarItem {
                Button { providers = true } label: {
                    // A remote belt's seats are set on that computer; naming
                    // this Mac's choice here would suggest it applies there.
                    Label(store.remote == nil ? "AI providers: \(store.workerSeat.name) / \(store.checkerSeat.name)" : "AI providers",
                          systemImage: "cpu")
                }
                .help(store.remote == nil ? "Choose which AI does the work and which one checks it"
                                          : "This belt's AI providers are set on the other computer. Check setup shows which.")
            }
            ToolbarItem {
                Button { adding = true } label: { Label("Add task", systemImage: "plus") }
                    .keyboardShortcut("n")
            }
            ToolbarItem {
                // Labeled and filled: as a bare toolbar icon it read as disabled.
                if store.remote != nil {
                    Label("Runs on its own there", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon).font(.callout).foregroundStyle(.secondary)
                        .help("This belt runs on a timer on the other computer, as its own user.")
                } else if store.running {
                    Button { store.stopRun() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Stop the conveyor and the AI it started")
                } else {
                    Button { store.startRun() } label: { Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r")
                        .help("Work the queue until it's empty, stuck, or 6 steps")
                }
            }
        }
    }
}

struct Column: View {
    let tray: Tray
    let tasks: [BeltTask]
    let onOpen: (BeltTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tray.title).font(.headline)
                Spacer()
                Text("\(tasks.count)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(tray.blurb).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        Card(task: task).onTapGesture { onOpen(task) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tray == .human && !tasks.isEmpty ? Color.orange.opacity(0.12) : Color.gray.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Card: View {
    let task: BeltTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(.body.weight(.medium)).lineLimit(3)
            if let last = task.lastEntry {
                Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(task.modified, style: .relative).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

struct TaskDetail: View {
    let task: BeltTask
    @EnvironmentObject var store: BeltStore
    @Environment(\.dismiss) private var dismiss
    @State private var approveError: String?
    @State private var approving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(task.title).font(.title2.weight(.semibold))
                Spacer()
                Text(task.tray.title).foregroundStyle(.secondary)
            }
            let text = (try? String(contentsOf: task.url, encoding: .utf8)) ?? "Could not read the task file."
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TaskFilesPanel(text: text)
            if let approveError {
                Text(approveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if store.remote == nil {
                    Button("Show file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([task.url]) }
                }
                Spacer()
                if task.tray == .human && store.remote == nil && text.contains("\n## Plan needs you") {
                    Button("Plan again") {
                        approveError = store.replan(task)
                        if approveError == nil { dismiss() }
                    }
                    .help("Edit the request at the top of the file first, then send it back to the planner for a fresh start.")
                }
                if task.tray == .human {
                    Button(approving ? "Approving…" : "Approve plan") {
                        approving = true
                        Task {
                            approveError = await store.approve(task)
                            approving = false
                            if approveError == nil { dismiss() }
                        }
                    }
                    .disabled(approving)
                    .help(store.remote == nil
                          ? "Tick your step and put the task back in the queue. Then press Run."
                          : "Tick your step and put the task back in the queue. The belt picks it up on its next run.")
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
    }
}

/// A task's attachments and output files, under its text. Local belt: click a
/// file to open it, or open the folder in Finder. Remote belt: the files live
/// on the other computer, so the outputs are listed over SSH and "Download
/// outputs" copies them to ~/Downloads/Conveyor/<task-id>/.
struct TaskFilesPanel: View {
    let text: String
    @EnvironmentObject var store: BeltStore
    @State private var remoteOutputs: [String] = []
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        let parsed = TaskFiles.parse(text)
        if !parsed.attachments.isEmpty || parsed.outputs != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !parsed.attachments.isEmpty {
                        Text("Attachments (inputs)").font(.headline)
                        ForEach(parsed.attachments, id: \.self) { p in
                            row(p, label: (p as NSString).lastPathComponent)
                        }
                    }
                    if let out = parsed.outputs {
                        HStack {
                            Text("Outputs").font(.headline)
                            Spacer()
                            if store.remote == nil {
                                Button("Open in Finder") { openFolder(out) }
                            } else {
                                Button(busy ? "Downloading…" : "Download outputs") { download(out) }
                                    .disabled(busy || remoteOutputs.isEmpty)
                            }
                        }
                        let names = store.remote == nil ? TaskFiles.list(URL(fileURLWithPath: out)) : remoteOutputs
                        if names.isEmpty {
                            Text("No files in \(out) yet.").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ForEach(names, id: \.self) { n in row(out + "/" + n, label: n) }
                    }
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .task(id: parsed.outputs) {
                guard let remote = store.remote, let out = parsed.outputs else { return }
                let r = await remote.listOutputs(out)
                remoteOutputs = r.files
                if let e = r.error { note = e }
            }
        }
    }

    @ViewBuilder private func row(_ path: String, label: String) -> some View {
        if store.remote == nil {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                Button(label) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link)
                    .help("Open \(path)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(label).help("On the other computer: \(path)")
            }
        }
    }

    private func openFolder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func download(_ out: String) {
        guard let remote = store.remote else { return }
        busy = true
        note = nil
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conveyor")
        let id = (out as NSString).lastPathComponent
        var dest = base.appendingPathComponent(id)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = base.appendingPathComponent("\(id) (\(n))")
            n += 1
        }
        Task {
            if let err = await remote.downloadOutputs(out, to: dest) {
                note = err
            } else {
                note = "Saved to \(dest.path)"
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
            busy = false
        }
    }
}

struct AddTask: View {
    @EnvironmentObject var store: BeltStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var want = ""
    @State private var error: String?
    @State private var busy = false
    @State private var files: [URL] = []
    @State private var plan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a task").font(.title2.weight(.semibold))
            TextField("Short title, e.g. Count the TODOs", text: $title)
            Text("What do you want? Say it in your own words. Leave the checklist out and the conveyor writes one, then waits for you to approve it.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $want)
                .font(.body)
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            FileDrop(files: $files)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Plan it first", isOn: $plan)
                    .disabled(!store.planAvailable)
                Text(store.planAvailable
                     ? "\(store.plannerSeat.name) writes small checked steps, \(store.criticSeat.name) looks for problems, and only an agreed plan gets built. Uses a little of both, saves building the wrong thing."
                     : (store.remote != nil ? "Planning first only works on a belt on this Mac for now."
                                            : "This belt is older than planning first."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(plan ? "Add to planning" : "Add to queue") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || want.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func submit() {
        busy = true
        let body = "Want: " + want.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            error = await store.add(title: title.trimmingCharacters(in: .whitespaces), body: body, files: files,
                                    plan: plan && store.planAvailable)
            busy = false
            if error == nil { dismiss() }
        }
    }
}

struct ActivityPanel: View {
    @EnvironmentObject var store: BeltStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.activity?.events ?? []) { e in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: e.icon).foregroundStyle(.secondary).frame(width: 16)
                                    Text(e.text).font(.callout).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(e.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: store.activity?.events.count) { _, _ in
                        if let last = store.activity?.events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                if !store.runOutput.isEmpty {
                    Divider()
                    Text(store.runOutput.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(8).joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("History").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.receipts) { r in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(r.time)  \(Logs.stepName(r.step).components(separatedBy: ":").first ?? r.step)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text("\(r.task): \(r.verdict)").font(.caption).lineLimit(2)
                            }
                        }
                        if store.receipts.isEmpty {
                            Text("Nothing has run yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
        .background(Color.gray.opacity(0.05))
    }

    @ViewBuilder private var header: some View {
        if let a = store.activity, a.live {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(a.step).font(.headline)
                Text("· \(a.taskTitle) · \(a.seat)").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(a.started, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else if let a = store.activity {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Nothing running").font(.headline)
                Text("· last step: \(a.step), \(a.taskTitle)").foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text("Nothing running").font(.headline)
        }
    }
}

/// Files of any kind for the task: dropped in or chosen. Images show as
/// thumbnails, everything else with its Finder icon and name.
struct FileDrop: View {
    @Binding var files: [URL]
    @State private var hovering = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(files.isEmpty ? "Drop files here (PDF, spreadsheet, image, zip, code…), if the task needs them"
                                   : "\(files.count) file\(files.count == 1 ? "" : "s") attached")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Choose files…") { choose() }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(files, id: \.self) { url in
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 2) {
                                    Group {
                                        if Self.isImage(url), let img = NSImage(contentsOf: url) {
                                            Image(nsImage: img).resizable().scaledToFill()
                                        } else {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                                        }
                                    }
                                    .frame(width: 72, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                                        .frame(width: 80)
                                }
                                .help(url.path)
                                Button { files.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                            }
                        }
                    }
                }
                .frame(height: 80)
            }
        }
        .padding(10)
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(hovering ? Color.accentColor : Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .dropDestination(for: URL.self) { urls, _ in
            take(urls.filter(\.isFileURL))
            return true
        } isTargeted: { hovering = $0 }
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }

    /// Folders and oversize files are turned away here, with the reason.
    private func take(_ urls: [URL]) {
        let fresh = urls.filter { !files.contains($0) }
        var ok: [URL] = []
        problem = nil
        for u in fresh {
            if let why = TaskFiles.problem(with: [u]) { problem = why } else { ok.append(u) }
        }
        files += ok
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        take(panel.urls)
    }
}

struct Providers: View {
    let inSheet: Bool
    @EnvironmentObject var store: BeltStore
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI providers").font(.title2.weight(.semibold))
            Text("Each one is that company's own program, logged in with your own account. The conveyor never sees a password or key.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let remote = store.remote {
                Label("The belt on \(remote.host) uses the AI providers set on that computer. These choices only apply to a belt on this Mac, so they are greyed out. Check setup shows what that belt uses.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Does the work").font(.headline)
                    seatPicker($store.workerSeat)
                }
                GridRow {
                    Text("")
                    Text("Also turns a plain request into a checklist.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Checks the work").font(.headline)
                    seatPicker($store.checkerSeat)
                }
                GridRow {
                    Text("")
                    Text(store.workerSeat == store.checkerSeat
                         ? "Same AI for both works. A different one is harder to fool."
                         : "A fresh AI, with no memory of the work, tries to prove it wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Plans the work").font(.headline)
                    seatPicker($store.plannerSeat)
                }
                GridRow {
                    Text("Reviews the plan").font(.headline)
                    seatPicker($store.criticSeat)
                }
                GridRow {
                    Text("")
                    Text(store.plannerSeat == store.criticSeat
                         ? "Only for tasks added with Plan it first. A different AI from the planner catches more."
                         : "Only for tasks added with Plan it first. It lists problems or approves; two rounds, then it asks you.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("If a step keeps failing").font(.headline)
                    Picker("", selection: $store.escalateSeat) {
                        Text("Ask me").tag(Seat?.none)
                        ForEach(Seat.allCases) { seat in
                            Text(seat.programs.allSatisfy { which($0) != nil } ? "Hand it to \(seat.name)" : "Hand it to \(seat.name) (not installed)")
                                .tag(Seat?.some(seat))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                GridRow {
                    Text("")
                    Text("Planned tasks only: after 3 failed tries at one step, that step gets one go on this AI, then comes to you.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if [store.workerSeat, store.checkerSeat, store.plannerSeat, store.criticSeat].contains(.local) || store.escalateSeat == .local {
                    GridRow {
                        Text("Local model").font(.headline)
                        TextField("Model name, as the server lists it", text: $store.localModel).frame(width: 260)
                    }
                    GridRow {
                        Text("Server address").font(.headline)
                        TextField("http://127.0.0.1:1234/v1", text: $store.localBaseURL).frame(width: 260)
                    }
                    GridRow {
                        Text("")
                        Text("Any OpenAI-compatible server (LM Studio, Ollama, llama.cpp), on this Mac or another computer, e.g. http://192.168.1.50:11434/v1. The model has to make real tool calls. If the server needs a key, set CONVEYOR_LOCAL_API_KEY; the app never stores it.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(store.remote != nil)

            Divider()
            Text("On this Mac").font(.headline)
            ForEach(Seat.allCases) { seat in
                HStack(alignment: .firstTextBaseline) {
                    let missing = seat.programs.filter { which($0) == nil }
                    Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(missing.isEmpty ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(seat.name)  ").font(.body.weight(.medium))
                            + Text(seat.maker).font(.caption).foregroundStyle(.secondary)
                        Text(missing.isEmpty ? seat.programs.compactMap(which).joined(separator: ", ")
                                             : "Not installed: \(missing.joined(separator: ", "))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !missing.isEmpty { Link("How to install", destination: seat.installURL).font(.caption) }
                }
            }
            Text("After installing, open Terminal once and run the program to log in.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            HStack {
                Button(checking ? "Checking…" : "Check setup") {
                    checking = true
                    Task { report = await store.doctor(); checking = false }
                }
                .disabled(checking)
                Spacer()
                if inSheet { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            if let report {
                ScrollView {
                    Text(report).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func seatPicker(_ binding: Binding<Seat>) -> some View {
        Picker("", selection: binding) {
            ForEach(Seat.allCases) { seat in
                Text(seat.programs.allSatisfy { which($0) != nil } ? seat.name : "\(seat.name) (not installed)")
                    .tag(seat)
            }
        }
        .labelsHidden()
        .frame(width: 260)
    }
}

struct ConnectRemote: View {
    @EnvironmentObject var store: BeltStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = UserDefaults.standard.string(forKey: "remoteHost") ?? ""
    @State private var path = UserDefaults.standard.string(forKey: "remotePath") ?? ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a belt on another computer").font(.title2.weight(.semibold))
            Text("Uses SSH, with the keys already set up on this Mac. The app shows that belt and can approve and add tasks on it. The belt keeps running on its own there.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Login, e.g. claude@192.168.1.50", text: $host)
            TextField("Belt folder there, e.g. /srv/…/conveyor", text: $path)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Connecting…" : "Connect") {
                    busy = true
                    error = nil
                    Task {
                        error = await store.connect(host: host, path: path)
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || host.isEmpty || path.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct Welcome: View {
    @EnvironmentObject var store: BeltStore
    @Binding var connecting: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Conveyor").font(.largeTitle.weight(.semibold))
            Text("An AI task queue that only marks work done when it's proven.")
                .foregroundStyle(.secondary)
            Text("Choose the folder where you installed the conveyor.")
            Button("Choose folder…") { pickFolder(store) }.keyboardShortcut(.defaultAction)
            Button("Connect to a belt on another computer…") { connecting = true }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
func pickFolder(_ store: BeltStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Use this folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if !store.choose(url) {
        let alert = NSAlert()
        alert.messageText = "That folder isn't a conveyor install"
        alert.informativeText = "Pick the folder that has the `conveyor` file and the queue folder in it."
        alert.runModal()
    }
}
