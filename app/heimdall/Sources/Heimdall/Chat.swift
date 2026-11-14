import Foundation
import SwiftUI

/// Alexus chat, same as `alexus chat` in alexus-core: persona + silent boot context (bin/alexus-chat-bridge.py prep),
/// streaming replies from Ollama on Alexus, and a Switch Packet when the owner ends the session (… seal).
/// Every message is appended to ~/.ragnarok/heimdall-chat.jsonl, which the timeline shows.
@MainActor
final class ChatModel: ObservableObject {
    struct Msg: Identifiable { let id = UUID(); let role: String; var content: String }

    @Published var msgs: [Msg] = []          // shown (no system prompt)
    @Published var status = "Chat not started"
    @Published var busy = false
    @Published var started = false
    private var system = ""
    private var session = ""

    // report item 9: a malformed OLLAMA_HOST falls back to Alexus instead of crashing
    nonisolated static let ollama: URL = {
        var h = (ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "").trimmingCharacters(in: .whitespaces)
        if !h.isEmpty && !h.contains("://") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        if let u = URL(string: h + "/api/chat"), u.host != nil, ["http", "https"].contains(u.scheme ?? "") { return u }
        return URL(string: LocalConfig.current.ollama + "/api/chat") ?? URL(string: "http://localhost:11434/api/chat")!
    }()
    /// Model used for replies; picked in the chat header, remembered between launches.
    @Published var model: String = UserDefaults.standard.string(forKey: "chatModel") ?? "llama3.2:3b" {
        didSet { UserDefaults.standard.set(model, forKey: "chatModel") }
    }
    /// Where replies come from: "alexus" (Ollama on Alexus), "lmstudio" (LM Studio on this Mac), "apple" (Apple's on-device model).
    @Published var provider: String = UserDefaults.standard.string(forKey: "chatProvider") ?? "alexus" {
        didSet { UserDefaults.standard.set(provider, forKey: "chatProvider") }
    }
    @Published var lmModel: String = UserDefaults.standard.string(forKey: "chatLMModel") ?? "" {
        didSet { UserDefaults.standard.set(lmModel, forKey: "chatLMModel") }
    }
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "chatServerURL") ?? LocalModels.lmStudio {
        didSet { UserDefaults.standard.set(serverURL, forKey: "chatServerURL") }
    }
    @Published var appleModel: String = UserDefaults.standard.string(forKey: "chatAppleModel") ?? "general" {
        didSet { UserDefaults.standard.set(appleModel, forKey: "chatAppleModel") }
    }
    /// Cloud provider (CloudChat) and the model picked for it; each provider remembers its own model.
    @Published var cloudProvider: String = UserDefaults.standard.string(forKey: "chatCloudProvider") ?? "anthropic" {
        didSet { UserDefaults.standard.set(cloudProvider, forKey: "chatCloudProvider"); cloudModel = Self.savedModel(cloudProvider) }
    }
    @Published var cloudModel: String = ChatModel.savedModel(UserDefaults.standard.string(forKey: "chatCloudProvider") ?? "anthropic") {
        didSet { UserDefaults.standard.set(cloudModel, forKey: "chatCloudModel." + cloudProvider) }
    }
    nonisolated static func savedModel(_ id: String) -> String {
        UserDefaults.standard.string(forKey: "chatCloudModel." + id) ?? CloudChat.provider(id).suggested.first ?? ""
    }
    /// Converse-style recall (Recall.swift: nomic-embed-text on Alexus over the owner's own files) before every reply.
    @Published var useNotes: Bool = UserDefaults.standard.object(forKey: "chatUseNotes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useNotes, forKey: "chatUseNotes") }
    }
    @Published var notesStatus = ""
    /// The chat is showing in its own window (the tab then points there).
    @Published var poppedOut = false
    nonisolated static let bridge = AppPaths.bundledBin("alexus-chat-bridge.py")
    nonisolated static let log = ("~/.ragnarok/heimdall-chat.jsonl" as NSString).expandingTildeInPath

    func start() {
        guard !started, !busy else { return }
        busy = true; status = "Connecting to Alexus and loading what she knows about your projects…"
        session = "chat-" + ISO8601DateFormatter().string(from: Date())
        Task.detached {
            let (code, out, err) = Gate.run("/usr/bin/python3", [Self.bridge, "prep"])
            let d = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            await MainActor.run {
                guard code == 0, let sys = d?["system"] as? String else {
                    AppLog.error("alexus-chat-start", message: err.isEmpty ? "chat bridge returned no system prompt" : err, code: Int(code))
                    self.busy = false; self.status = "Boot failed: \(err.oneLine(200))"; return
                }
                self.system = sys; self.started = true
                self.status = "Connected to Alexus"
                self.busy = false
                self.reply(extra: "Say a short, in-character one-line hello. Say you are ready to help.")
            }
        }
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, started, !busy else { return }
        msgs.append(Msg(role: "user", content: t)); Self.write(session, "user", t)
        reply(extra: nil)
    }

    /// Stream one assistant reply. `extra` is a hidden one-off user prompt (the opening greeting).
    private func reply(extra: String?) {
        var history: [[String: String]] = [["role": "system", "content": system]]
        history += msgs.map { ["role": $0.role, "content": $0.content] }
        if let extra { history.append(["role": "user", "content": extra]) }
        let question = extra == nil ? (msgs.last(where: { $0.role == "user" })?.content ?? "") : ""
        msgs.append(Msg(role: "assistant", content: "")); busy = true
        let idx = msgs.count - 1
        let session = self.session
        let base = history
        Task {
            // converse: the parts of their own files that match this message, by meaning, in front of the model
            var history = base
            if useNotes, !question.isEmpty {
                notesStatus = "Looking through your files…"
                let small = provider == "apple"
                if let n = await Recall.notes(for: question, perHit: small ? 400 : 1200, k: small ? 3 : 6) {
                    history[0]["content"] = (history[0]["content"] ?? "") + "\n\n" + n
                    notesStatus = "Used \(n.components(separatedBy: "\n\n---\n\n").count) notes from your files"
                } else {
                    notesStatus = Recall.ready ? "No notes matched (or Alexus didn't answer in 15 s)" : "Notes index isn't built on this Mac yet"
                }
            } else if !useNotes { notesStatus = "" }
            switch provider {
            case "lmstudio": streamLMStudio(history, idx, session)
            case "apple": streamApple(history, idx, session)
            case "cloud": streamCloud(history, idx, session)
            default: streamOllama(history, idx, session)
            }
        }
    }

    /// A cloud model over HTTPS (CloudChat), streamed. The key stays in the keychain.
    private func streamCloud(_ history: [[String: String]], _ idx: Int, _ session: String) {
        let p = CloudChat.provider(cloudProvider), m = cloudModel
        Task {
            if let e = await CloudChat.stream(p, model: m, history: history, onText: { self.msgs[idx].content += $0 }) {
                msgs[idx].content += (msgs[idx].content.isEmpty ? "" : "\n") + "[\(e)]"
            }
            finish(idx, session)
        }
    }

    /// Ollama on Alexus, streamed.
    private func streamOllama(_ history: [[String: String]], _ idx: Int, _ session: String) {
        let model = self.model
        Task {
            // curl as a child process: the app's own URLSession got "offline" for this LAN address (2026-10-31),
            // while child processes (ssh, python) reach Alexus fine.
            let body = (try? JSONSerialization.data(withJSONObject: ["model": model, "messages": history, "stream": true])) ?? Data()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sS", "-N", "--max-time", "300", "-H", "Content-Type: application/json", "--data-binary", "@-", Self.ollama.absoluteString]
            let i = Pipe(), o = Pipe(), e = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = e
            do {
                try p.run()
                i.fileHandleForWriting.write(body); try? i.fileHandleForWriting.close()
                for await line in FileHandleLines.lines(from: o.fileHandleForReading) {
                    guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let piece = (d["message"] as? [String: Any])?["content"] as? String { msgs[idx].content += piece }
                    if let err = d["error"] as? String { AppLog.error("alexus-chat-ollama", message: err); msgs[idx].content += "\n[Ollama error: \(err)]" }
                }
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let err = String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    AppLog.error("alexus-chat-ollama", message: err.isEmpty ? "curl exited \(p.terminationStatus)" : err, code: Int(p.terminationStatus))
                    msgs[idx].content += "\n[Can't reach Alexus (curl exit \(p.terminationStatus)): \(err.oneLine(200))]"
                }
            } catch { AppLog.error("alexus-chat-ollama", error); msgs[idx].content += "\n[Couldn't get a reply: \(error.localizedDescription)]" }
            msgs[idx].content = msgs[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.write(session, "assistant", msgs[idx].content)
            busy = false
        }
    }

    private func finish(_ idx: Int, _ session: String) {
        msgs[idx].content = msgs[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.write(session, "assistant", msgs[idx].content)
        busy = false
    }

    /// LM Studio's local server (OpenAI-style, http://localhost:1234), streamed.
    private func streamLMStudio(_ history: [[String: String]], _ idx: Int, _ session: String) {
        Task {
            guard !lmModel.isEmpty else {
                msgs[idx].content = "[Pick a model on the server first.]"; finish(idx, session); return
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["model": lmModel, "messages": history, "stream": true])) ?? Data()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sS", "-N", "--max-time", "600", "-H", "Content-Type: application/json", "--data-binary", "@-", LocalModels.base(serverURL) + "/v1/chat/completions"]
            let i = Pipe(), o = Pipe(), e = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = e
            do {
                try p.run()
                i.fileHandleForWriting.write(body); try? i.fileHandleForWriting.close()
                for await line in FileHandleLines.lines(from: o.fileHandleForReading) {
                    guard line.hasPrefix("data: "), line != "data: [DONE]",
                          let d = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else {
                        if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let err = d["error"] {
                            AppLog.error("alexus-chat-lmstudio", message: String(describing: err)); msgs[idx].content += "\n[Server error: \(err)]"
                        }
                        continue
                    }
                    if let piece = ((d["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String {
                        msgs[idx].content += piece
                    }
                }
                p.waitUntilExit()
                if p.terminationStatus != 0 { AppLog.error("alexus-chat-lmstudio", message: "curl exited \(p.terminationStatus)", code: Int(p.terminationStatus)); msgs[idx].content += "\n[Can't reach the server at \(LocalModels.base(serverURL)).]" }
            } catch { AppLog.error("alexus-chat-lmstudio", error); msgs[idx].content += "\n[Couldn't get a reply: \(error.localizedDescription)]" }
            finish(idx, session)
        }
    }

    /// Apple's on-device model (Apple Intelligence), streamed. Runs on this Mac; nothing leaves it.
    private func streamApple(_ history: [[String: String]], _ idx: Int, _ session: String) {
        Task {
            msgs[idx].content = await LocalModels.appleReply(history: history, useCase: appleModel, webSearch: true) { text in
                self.msgs[idx].content = text
            }
            finish(idx, session)
        }
    }

    /// /switch + /end: write the Switch Packet and transcript receipt, then reset.
    func seal() {
        guard started, !busy else { return }
        busy = true; status = "Saving a summary of this chat…"
        var all: [[String: String]] = [["role": "system", "content": system]]
        all += msgs.map { ["role": $0.role, "content": $0.content] }
        let input = (try? JSONSerialization.data(withJSONObject: all)) ?? Data("[]".utf8)
        let session = self.session
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [Self.bridge, "seal"]
            let i = Pipe(), o = Pipe(), e = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = e
            let result: String
            var saved = false
            do {
                try p.run(); i.fileHandleForWriting.write(input); try? i.fileHandleForWriting.close()
                let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let d = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
                if p.terminationStatus == 0, let id = d?["packet_id"] as? String {
                    let ok = d?["read_back"] as? Bool == true
                    result = ok ? "Chat summary saved (\(id))" : "Chat summary sent (\(id)) but couldn't confirm it was saved"
                    saved = true
                } else if let s = d?["skipped"] as? String { result = "Nothing to save: \(s)"; saved = true }
                else { result = "Seal failed: \(String(decoding: err, as: UTF8.self).oneLine(200))" }
            } catch { AppLog.error("alexus-chat-seal", error); result = "Seal failed: \(error.localizedDescription)" }
            Self.write(session, "seal", result)
            let keep = saved
            await MainActor.run {
                // report item 8: the chat is only cleared once it was really saved; on failure it stays so you can retry
                self.busy = false; self.status = keep ? result : result + " — the chat is kept; try /end again."
                if keep { self.started = false; self.msgs = []; self.system = "" }
            }
        }
    }

    nonisolated static func write(_ session: String, _ role: String, _ content: String) {
        let rec: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "session": session, "role": role, "content": content]
        guard let d = try? JSONSerialization.data(withJSONObject: rec), let line = String(data: d, encoding: .utf8) else { return }
        appendLine(log, Data((line + "\n").utf8))
    }
}

struct ChatView: View {
    @EnvironmentObject var chat: ChatModel
    /// true in the pop-out window, false in the tab
    var poppedOut = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var models = Models()
    @StateObject private var local = LocalModels()
    @State private var text = ""
    @State private var cloudList: [String] = []
    @State private var hasKey = false
    @State private var askKey = false
    @State private var keyText = ""
    @State private var cloudNote = ""

    var body: some View {
        if chat.poppedOut && !poppedOut {
            VStack(spacing: 12) {
                Image(systemName: "macwindow.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("The chat is open in its own window.").font(.headline)
                HStack {
                    Button("Show that window") { openWindow(id: "chat") }
                    Button("Bring it back here") { dismissWindow(id: "chat"); chat.poppedOut = false }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .onDisappear { if poppedOut { chat.poppedOut = false } }
                .sheet(isPresented: $askKey) { keySheet }
        }
    }

    private var provider: CloudChat.Provider { CloudChat.provider(chat.cloudProvider) }

    private func refreshCloud() {
        hasKey = CloudChat.key(chat.cloudProvider) != nil
        cloudList = []; cloudNote = ""
    }

    private var keySheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(provider.name) API key").font(.headline)
            Text("Get one at \(provider.keyHelp). It is kept in this Mac's keychain and only sent to \(provider.name).")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Paste the key", text: $keyText).textFieldStyle(.roundedBorder).frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { keyText = ""; askKey = false }
                Button("Save") {
                    let ok = CloudChat.setKey(chat.cloudProvider, keyText)
                    keyText = ""; askKey = false; refreshCloud()
                    cloudNote = ok ? "Key saved." : "Couldn't save the key."
                }.keyboardShortcut(.defaultAction).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(chat.started ? .green : .secondary).frame(width: 8, height: 8)
                Text(chat.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !poppedOut {
                    Button { chat.poppedOut = true; openWindow(id: "chat") } label: { Label("Pop out", systemImage: "rectangle.portrait.and.arrow.right") }
                        .help("Open the chat in its own window (same conversation)")
                }
                if chat.started { Button("End chat and save summary") { chat.seal() }.disabled(chat.busy).help("Saves a short summary of this chat to your RAGNAROK database so Alexus remembers it next time") }
                else { Button("Start chat") { chat.start() }.disabled(chat.busy) }
            }
            .padding(8)
            Picker("Run on", selection: $chat.provider) {
                Text("Alexus").tag("alexus"); Text("Other server").tag("lmstudio"); Text("Apple (this Mac)").tag("apple"); Text("Cloud").tag("cloud")
            }
            .pickerStyle(.segmented).frame(maxWidth: 520).padding(.horizontal, 8)
            .help("Switch any time, even mid-chat: the conversation so far goes to the new one")
            if chat.provider == "cloud" {
                HStack(spacing: 8) {
                    Picker("Provider", selection: $chat.cloudProvider) {
                        ForEach(CloudChat.providers) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 280)
                    Button(hasKey ? "Change key…" : "Set key…") { askKey = true }
                    if hasKey { Button("Remove key") { CloudChat.removeKey(chat.cloudProvider); refreshCloud(); cloudNote = "Key removed." } }
                    Spacer()
                }
                .padding(.horizontal, 8)
                HStack(spacing: 8) {
                    let options = Array(Set(cloudList + provider.suggested + [chat.cloudModel].filter { !$0.isEmpty })).sorted()
                    Picker("Model", selection: $chat.cloudModel) {
                        if chat.cloudModel.isEmpty { Text("Pick a model").tag("") }
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    TextField("or type a model id", text: $chat.cloudModel).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Button("Load models") {
                        Task { let l = await CloudChat.models(provider); cloudList = l; cloudNote = l.isEmpty ? "Couldn't load the list (key set?)." : "\(l.count) models." }
                    }.disabled(!hasKey)
                    Spacer()
                }
                .padding(.horizontal, 8)
                Text((cloudNote.isEmpty ? "" : cloudNote + " ") + "Cloud: your messages, Alexus's boot notes and any matching notes from your files go to \(provider.name).")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 6)
            } else if chat.provider == "lmstudio" {
                HStack(spacing: 8) {
                    TextField("Server address", text: $chat.serverURL).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .onSubmit { local.refresh(server: chat.serverURL) }
                    Button("LM Studio") { chat.serverURL = "http://127.0.0.1:1234"; local.refresh(server: chat.serverURL) }
                    Button("Ollama (this Mac)") { chat.serverURL = "http://127.0.0.1:11434"; local.refresh(server: chat.serverURL) }
                    Button("Alexus") { chat.serverURL = LocalConfig.current.ollama; local.refresh(server: chat.serverURL) }
                    Spacer()
                }
                .padding(.horizontal, 8)
                HStack(spacing: 8) {
                    Picker("Model", selection: $chat.lmModel) {
                        if chat.lmModel.isEmpty { Text("Pick a model").tag("") }
                        ForEach(local.lmModels, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 420)
                    Button { local.refresh(server: chat.serverURL) } label: { Image(systemName: "arrow.clockwise") }.help("Check the server again")
                    Spacer()
                }
                .padding(.horizontal, 8)
                Text(local.lmStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 6)
            } else if chat.provider == "apple" {
                HStack(spacing: 8) {
                    Picker("Apple model", selection: $chat.appleModel) {
                        ForEach(LocalModels.appleModels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                }
                .padding(.horizontal, 8)
                Text(local.appleStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 6)
            } else {
            HStack(spacing: 8) {
                Picker("AI model", selection: $chat.model) {
                    ForEach(models.local, id: \.name) { m in Text("\(m.name)  (\(Models.gb(m.size)))").tag(m.name) }
                    if !models.local.contains(where: { $0.name == chat.model }) { Text(chat.model).tag(chat.model) }
                }
                .frame(maxWidth: 320)
                Menu("Download a model that fits") {
                    if models.candidates.isEmpty { Text(models.budget == 0 ? "Checking…" : "No new models fit") }
                    ForEach(models.candidates, id: \.name) { c in
                        Button("\(c.name)  —  \(Models.gb(c.size))") { models.pull(c.name) }
                    }
                }
                .frame(maxWidth: 200).disabled(models.pulling != nil)
                Button { models.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Check again for models and the graphics card")
                if models.pulling != nil { ProgressView().controlSize(.small); Text(models.progress).font(.caption).lineLimit(1) }
                else if !models.progress.isEmpty { Text(models.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }
            .padding(.horizontal, 8)
            Text(models.hardware).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 6)
            }
            HStack(spacing: 8) {
                Toggle("Use my notes", isOn: $chat.useNotes).toggleStyle(.switch).controlSize(.small)
                    .help("Before each reply, find the parts of your own files that match your message by meaning (nomic-embed-text on Alexus) and give them to the model, like converse")
                Text(chat.notesStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.msgs) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.role == "user" ? "\(LocalConfig.owner)" : "Alexus").font(.caption.bold())
                                    .foregroundStyle(m.role == "user" ? Palette.color("owner") : Palette.color("alexus"))
                                Text(m.content.isEmpty ? "…" : m.content).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(m.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chat.msgs.last?.content) { if let id = chat.msgs.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            HStack {
                TextField(chat.started ? "Talk to Alexus…" : "Click Start chat first", text: $text)
                    .textFieldStyle(.roundedBorder).onSubmit(send).disabled(!chat.started)
                Button("Send", action: send).disabled(!chat.started || chat.busy || text.isEmpty)
                if chat.busy { ProgressView().controlSize(.small) }
            }
            .padding(8)
        }
        .onAppear { if models.local.isEmpty { models.refresh() }; local.refresh(server: chat.serverURL); refreshCloud() }
        .onChange(of: chat.cloudProvider) { refreshCloud() }
    }

    private func send() { guard !chat.busy else { return }; chat.send(text); text = "" }
}
