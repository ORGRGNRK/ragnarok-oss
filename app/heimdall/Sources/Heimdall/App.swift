import AppKit
import Belt
import AlexusKit
import SwiftUI

/// Clicking the Dock icon (or opening the app) while it runs with its window closed must bring a window back.
/// SwiftUI didn't do that here when the app is started by the launcher (seen 2026-11-01 12:54), so do it by hand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openMain: (() -> Void)? {
        didSet {
            if pendingMain, let openMain { pendingMain = false; openMain() }
        }
    }
    @MainActor private static var pendingMain = false
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppDelegate.showMain() } }
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler { exception in AppLog.uncaughtException(exception) }
        // --test-reopen: close the window, send the Dock's "reopen", report whether a window came back (test mode)
        guard CommandLine.arguments.contains("--test-reopen") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let before = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Ragnarok") }.count
            NSApp.windows.filter { $0.title.hasPrefix("Ragnarok") }.forEach { $0.close() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let closed = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Ragnarok") }.count
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let after = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Ragnarok") }.count
            print("reopen test: visible before=\(before) after close=\(closed) after reopen=\(after)")
            exit(after > 0 && closed == 0 && before > 0 ? 0 : 1)
        }
    }

    @MainActor static func showMain() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title.hasPrefix("Ragnarok") }) {
            w.makeKeyAndOrderFront(nil)
        } else if let openMain { openMain() }
        else { pendingMain = true }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keeps SwiftUI's "open a window" action where the delegate can reach it.
private struct CaptureOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }
}

@main
struct HeimdallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var gate = Gate.shared
    @StateObject private var store = Store()
    @StateObject private var editor = Editor()
    @StateObject private var chat = ChatModel()
    @StateObject private var shell = ShellSession()
    @StateObject private var room = RoomModel()
    @StateObject private var hub = HubModel()
    @State private var started = false
    @State private var splash = false
    @State private var feeds: (files: [FileFeed], ssh: [SSHFeed]) = ([], [])

    init() {
        if CommandLine.arguments.contains("--scrub") { Scrub.filterStdin() }
        LoginPath.apply()   // the owner's real PATH (from their zsh) before anything starts a program; see LoginPath.swift
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        if let i = CommandLine.arguments.firstIndex(of: "--ask-alexus"), i + 1 < CommandLine.arguments.count {
            let q = CommandLine.arguments[i + 1]
            let pick = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "settings"
            let backend: WebTools.Backend = pick == "settings" ? AITerminal.localBackend() : pick == "apple" ? .apple(useCase: "general") : .ollama(model: pick)
            setvbuf(stdout, nil, _IOLBF, 0)
            Task.detached {
                // same as the terminal: their notes and past failures go in the prompt first
                async let n = Recall.notes(for: q)
                async let f = Recall.failures(for: q)
                let (notes, fails) = await (n, f)
                print(notes == nil ? "(no notes)" : "📚 notes: \(notes!.count) chars", fails == nil ? "(no failures)" : "⚠️ failures passed")
                let a = await AITerminal.alexusAnswer(AITerminal.prompt(q, history: [], cwd: NSHomeDirectory(), textOnly: true, notes: notes, failures: fails), backend: backend, question: q) { print($0) }
                print(a); exit(0)
            }
            RunLoop.main.run()   // keep the main thread free: Apple's model answers on it
        }
        // --ask-chat "<question>": the Chat tab's Apple path (persona from the chat bridge + web_search tool), test mode
        if let i = CommandLine.arguments.firstIndex(of: "--ask-chat"), i + 1 < CommandLine.arguments.count {
            let q = CommandLine.arguments[i + 1]
            setvbuf(stdout, nil, _IOLBF, 0)
            Task.detached {
                let (code, out, err) = Gate.run("/usr/bin/python3", [ChatModel.bridge, "prep"])
                let d = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
                guard code == 0, let sys = d?["system"] as? String else { print("chat bridge failed: \(err)"); exit(1) }
                let a = await LocalModels.appleReply(history: [["role": "system", "content": sys], ["role": "user", "content": q]],
                                                     useCase: "general", webSearch: true) { _ in }
                print(a); exit(0)
            }
            RunLoop.main.run()
        }
        // --explain <file> [local|claude]: print the "what editing this does" note (test mode; doesn't save it)
        if let i = CommandLine.arguments.firstIndex(of: "--explain"), i + 1 < CommandLine.arguments.count {
            let f = CommandLine.arguments[i + 1]
            let eng = Explainer.Engine(rawValue: CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "local") ?? .local
            setvbuf(stdout, nil, _IOLBF, 0)
            Task.detached {
                let text = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
                let ctx = Explainer.context(f, text: text)
                let (r, by) = await Explainer.ask(eng, prompt: ctx)
                print("== by \(by), risk \(Explainer.risk(in: r)), context \(ctx.count) chars ==\n" + r); exit(0)
            }
            RunLoop.main.run()
        }
        // --fillcheck: fill a test login form with the vault's page script and read it back (test mode)
        if CommandLine.arguments.contains("--fillcheck") { MainActor.assumeIsolated { VaultFillCheck.run() }; RunLoop.main.run() }
        // --webcheck URL: load one page in a real WKWebView (as this app, with its Info.plist) and print what came back (test mode)
        if let i = CommandLine.arguments.firstIndex(of: "--webcheck"), i + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IOLBF, 0)
            let u = CommandLine.arguments[i + 1]
            MainActor.assumeIsolated { WebPanelModel.webcheck(u) }
            RunLoop.main.run()
        }
        // --render-tab belt|agents OUT.png: draw one tab in an off-screen window and save a picture (test mode)
        if let i = CommandLine.arguments.firstIndex(of: "--render-tab"), i + 2 < CommandLine.arguments.count {
            let which = CommandLine.arguments[i + 1], out = CommandLine.arguments[i + 2]
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                let content: AnyView
                if which.hasPrefix("workspace:") {
                    let hub = HubModel()
                    hub.tab = String(which.dropFirst("workspace:".count))
                    content = AnyView(WorkspaceView(hub: hub, store: Store(), editor: Editor(),
                                                     chat: ChatModel(), shell: ShellSession(), room: RoomModel()))
                } else {
                    content = which == "belt" ? AnyView(BeltTab()) : which == "home" ? AnyView(HomeAssistantView()) : AnyView(AgentsView())
                }
                let host = NSHostingView(rootView: content.frame(width: 1200, height: 760)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
                host.appearance = NSAppearance(named: .darkAqua)
                let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = host
                win.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("no image"); exit(1) }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))) != nil
                    print(ok ? "saved \(out)" : "could not save \(out)"); exit(ok ? 0 : 1)
                }
            }
            RunLoop.main.run()
        }
        // --money-repair [--apply]: re-read imported bank files with today's parser (see MoneyStore.repairCLI)
        if CommandLine.arguments.contains("--money-repair") { exit(MoneyStore.repairCLI(apply: CommandLine.arguments.contains("--apply"))) }
        // --hub-history NAME: print one project's history (test mode)
        if let i = CommandLine.arguments.firstIndex(of: "--hub-history"), i + 1 < CommandLine.arguments.count {
            let want = CommandLine.arguments[i + 1]
            let (f, c, _) = HubModel.alexusState()
            let all = HubModel.link(HubModel.discover(), folders: f, containers: c)
            guard let p = all.first(where: { $0.label == want || $0.name == want }) else { print("no project \(want)"); exit(1) }
            let items = HubModel.history(p).sorted { $0.time > $1.time }
            print("\(p.label): \(items.count) items · " + ["commit", "receipt", "failure", "conveyor", "container"].map { k in "\(k) \(items.filter { $0.kind == k }.count)" }.joined(separator: ", "))
            for it in items.prefix(12) { print("\(HubView.when(it.time)) [\(it.kind)] \(it.who): \(it.title.oneLine(110)) | \(it.detail.oneLine(80))") }
            exit(0)
        }
        // --hub-scan: print what the Hub finds (test mode)
        if CommandLine.arguments.contains("--hub-scan") {
            let local = HubModel.discover()
            let (f, c, note) = HubModel.alexusState()
            for p in HubModel.link(local, folders: f, containers: c) {
                print("\(p.label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(p.kinds.joined(separator: ",").padding(toLength: 18, withPad: " ", startingAt: 0)) git:\(p.branch ?? "-") dirty:\(p.dirty) app:\(p.app.map { ($0 as NSString).lastPathComponent } ?? "-") build:\(p.build ?? "-") alexus:\(p.alexusFolder ? "folder" : "-") containers:\(p.containers.map { $0.name + ($0.healthy ? "" : "(!)") }.joined(separator: ","))")
            }
            print(note)
            for s in HubModel.mcpServers() { print("mcp \(s.state.padding(toLength: 5, withPad: " ", startingAt: 0)) \(s.name): \(s.detail)") }
            for j in HubModel.launchJobs() { print("job \(j.label): \(j.pid.map { "running \($0)" } ?? (j.loaded ? "loaded, last exit \(j.lastExit ?? "?")" : "not loaded"))") }
            exit(0)
        }
        // Opened directly (Dock, Finder, Spotlight) instead of through the launcher: hand off to the launcher,
        // which supervises this build (restart on crash, rollback, known-good fallback), and quit this copy.
        // One app since 2026-11-01: this is ~/Applications/Ragnarok.app; the launcher is a hidden helper (no Dock icon).
        let launcher = NSHomeDirectory() + "/Library/Application Support/Heimdall/Ragnarok Launcher.app"
        if ProcessInfo.processInfo.environment["HEIMDALL_LAUNCHER"] != "1",
           ProcessInfo.processInfo.environment["HEIMDALL_NO_HANDOFF"] != "1",
           FileManager.default.fileExists(atPath: launcher + "/Contents/MacOS/heimdall-launcher") {
            let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open"); o.arguments = [launcher]
            try? o.run(); o.waitUntilExit()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Ragnarok", id: "main") {
            Group {
                if gate.unlocked {
                    WorkspaceView(hub: hub, store: store, editor: editor, chat: chat,
                                  shell: shell, room: room)
                        .onAppear { startFeeds() }
                } else {
                    LockView().environmentObject(gate)
                }
            }
            // the opening scene plays over the app after every unlock, then fades away (click or any key skips)
            .overlay {
                if splash {
                    SplashView { withAnimation(.easeOut(duration: 0.3)) { splash = false } }.transition(.opacity)
                }
            }
            .onChange(of: gate.unlocked) { _, now in if now && !CommandLine.arguments.contains("--no-splash") { splash = true } }
            .modifier(CaptureOpenWindow())
            // Links (ragnarok:// or ragnarok-cc://, the Control Center tiles): open · lock · hub · services · room?path=<folder>
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // reuse this window for links, don't open another
            .onOpenURL { url in
                guard url.scheme == "ragnarok" || url.scheme == "ragnarok-cc" else { return }
                if url.host == "lock" { RagnarokControlDispatch.perform(.lock); return }
                if url.host == "services" { hub.tab = "hub"; hub.selected = "services:" }
                if url.host == "hub" { hub.tab = "hub" }
                if url.host == "room" { hub.tab = "room" }   // ?path= used to open a project in the Room's editor (removed 11-02)
                AppDelegate.showMain()
            }
            .frame(minWidth: 1000, minHeight: 640)
        }
        // the chat in its own window (Pop out in the Alexus tab); same ChatModel, so it's the same conversation
        Window("Alexus chat", id: "chat") {
            Group {
                if gate.unlocked { ChatView(poppedOut: true).environmentObject(chat) }
                else { Text("Ragnarok is locked. Unlock it in the main window.").foregroundStyle(.secondary).padding(40) }
            }
            .frame(minWidth: 460, minHeight: 520)
        }
    }

    /// Feeds start after the first unlock and keep running while locked, so nothing is missed;
    /// the window just hides them until the next unlock.
    private func startFeeds() {
        guard !started else { return }
        started = true
        feeds = AllFeeds.make()
        feeds.files.forEach { $0.start(store) }
        feeds.ssh.forEach { $0.start(store) }
        editor.startWatching()
    }
}

struct LockView: View {
    @EnvironmentObject var gate: Gate
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "eye.trianglebadge.exclamationmark").font(.system(size: 56))
            Text("Ragnarok").font(.largeTitle.bold())
            Text(gate.message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button { gate.key() } label: { Label("YubiKey / uTrust", systemImage: "key.horizontal") }
                Button { gate.touchID() } label: { Label("Touch ID", systemImage: "touchid") }
            }
            .controlSize(.large).disabled(gate.busy)
            if gate.busy { ProgressView() }
        }
        .padding(40)
        .onAppear { gate.auto() }
    }
}


/// The window's tabs, in a view that watches the Hub itself: a tab change made from code (Hub → "Open in Room", the
/// ragnarok-cc:// links) redraws here. Bound straight from the App's scene body it could be missed.
struct TabsHost<Content: View>: View {
    @ObservedObject var hub: HubModel
    @ViewBuilder let content: () -> Content
    var body: some View { TabView(selection: $hub.tab) { content() } }
}
