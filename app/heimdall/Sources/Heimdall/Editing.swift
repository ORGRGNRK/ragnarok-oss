import CoreGraphics
import Foundation
import SwiftUI

/// Runs bin/heimdall-edit for the owner's instruction and watches for a newly installed build.
/// The edit happens in a staging copy; this app keeps running the whole time.
@MainActor
final class Editor: ObservableObject {
    @Published var running = false
    @Published var lastResult = ""
    @Published var updateReady: String?          // "abc1234 — what changed", when a new build is installed

    nonisolated static let repo = AppPaths.heimdallRepo
    nonisolated static let support = ("~/Library/Application Support/Heimdall" as NSString).expandingTildeInPath
    static let underLauncher = ProcessInfo.processInfo.environment["HEIMDALL_LAUNCHER"] == "1"
    // The picker shows the ones that are used: the edit log (11-02) has only manual and claude; grok is new. bin/heimdall-edit
    // still takes codex and api:* from the command line.
    static let providers = ["claude", "grok"]

    private var timer: Timer?

    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkUpdate() }
        }
        checkUpdate()
    }

    private func checkUpdate() {
        let f = Self.support + "/update-ready"
        if let s = try? String(contentsOfFile: f, encoding: .utf8) {
            let lines = s.split(separator: "\n", maxSplits: 1).map(String.init)
            updateReady = lines.joined(separator: " — ")
            readyCommit = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        } else { updateReady = nil; readyCommit = "" }
        autoRestartIfIdle()
    }

    // Auto-restart (owner, 2026-11-13: "build the auto restart"). A new build loads by itself once nobody has touched the
    // Mac's keyboard or mouse for autoRestartIdle seconds, so it never cuts off typing mid-sentence. Only under the
    // launcher (exit 75 = start the new build), never during an edit, and only if the ready build isn't the one running
    // (the launcher clears update-ready on restart; this is the second guard against a restart loop).
    nonisolated static let autoRestartIdle: Double = 30
    /// The commit this copy started from. Read once at launch: the installed bundle is replaced in place by an install.
    nonisolated static let runningCommit: String = (try? String(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/commit",
                                                                 encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    private var readyCommit = ""
    var autoRestartOn: Bool { UserDefaults.standard.object(forKey: "autoRestart") as? Bool ?? true }

    nonisolated static func shouldAutoRestart(readyCommit: String, runningCommit: String, idleSeconds: Double,
                                              editing: Bool, underLauncher: Bool, enabled: Bool) -> Bool {
        enabled && underLauncher && !editing && !readyCommit.isEmpty && readyCommit != runningCommit && idleSeconds >= autoRestartIdle
    }

    /// One line in the launcher's log (~/.ragnarok/heimdall-edits.jsonl), next to its start/restart lines.
    nonisolated static func logRestart(_ detail: String) {
        let row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "edit": "launcher", "who": "app",
                                  "by": NSUserName(), "step": "auto-restart", "ok": true, "detail": detail]
        guard var d = try? JSONSerialization.data(withJSONObject: row) else { return }
        d.append(0x0A)
        let path = NSHomeDirectory() + "/.ragnarok/heimdall-edits.jsonl"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
    }

    /// Seconds since the last keyboard/mouse/trackpad event anywhere on the Mac.
    nonisolated static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func autoRestartIfIdle() {
        guard Self.shouldAutoRestart(readyCommit: readyCommit, runningCommit: Self.runningCommit, idleSeconds: Self.idleSeconds(),
                                     editing: running, underLauncher: Self.underLauncher, enabled: autoRestartOn) else { return }
        Self.logRestart("loading build \(readyCommit) after \(Int(Self.autoRestartIdle)) s idle (was \(Self.runningCommit))")
        restart()
    }

    /// who = provider name, or "manual" for the owner's own uncommitted edits.
    func edit(who: String, instruction: String) {
        guard !running else { return }
        running = true; lastResult = "\(who) is editing a staging copy… (watch the timeline)"
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: AppPaths.repoBin("heimdall-edit"))
            // the instruction goes on stdin ("-"), so long or multi-line text never hits argument limits (report A8)
            p.arguments = [who] + (instruction.isEmpty ? [] : ["-"])
            let inPipe = Pipe(); p.standardInput = instruction.isEmpty ? FileHandle.nullDevice : inPipe
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "HEIMDALL_LAUNCHER")
            p.environment = env
            let err = Pipe(); p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            let result: String
            do {
                try p.run()
                if !instruction.isEmpty {
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(String(instruction.prefix(100_000)).utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                result = p.terminationStatus == 0 ? "Installed. Click Restart when you're ready." : e.oneLine(300)
            } catch { AppLog.error("edit-runner", error); result = "could not start heimdall-edit: \(error.localizedDescription)" }
            await MainActor.run { self.running = false; self.lastResult = result; self.checkUpdate() }
        }
    }

    /// Exit code 75 tells the launcher to start the newly installed build.
    func restart() { exit(75) }
}

struct EditBar: View {
    @EnvironmentObject var editor: Editor
    @State private var who = "claude"
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let u = editor.updateReady {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green)
                    Text("New build ready: \(u)").lineLimit(1).truncationMode(.tail)
                    Spacer()
                    if Editor.underLauncher {
                        if editor.autoRestartOn { Text("loads by itself after \(Int(Editor.autoRestartIdle)) s idle").foregroundStyle(.secondary) }
                        Button("Restart") { editor.restart() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    else { Text("open Ragnarok from the Dock to use it").foregroundStyle(.secondary) }
                }
                .padding(6).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Picker("", selection: $who) { ForEach(Editor.providers, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 130)
                TextField("Change Ragnarok: tell an AI what to change…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("Edit", action: run).disabled(editor.running || text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Install my edits") { editor.edit(who: "manual", instruction: "") }
                    .disabled(editor.running)
                    .help("Takes your own uncommitted changes in ~/Developer/heimdall through build + self-test, then installs them")
                if editor.running { ProgressView().controlSize(.small) }
            }
            if !editor.lastResult.isEmpty { Text(editor.lastResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(8)
    }

    private func run() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !editor.running else { return }
        editor.edit(who: who, instruction: t); text = ""
    }
}
