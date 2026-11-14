import AppKit
import SwiftUI

@main
struct CLIToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CLI Tools", id: "main") {
            ContentView(engine: appDelegate.engine)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Pipeline") {
                Button("Run") { appDelegate.engine.run() }
                    .keyboardShortcut("r")
                    .disabled(appDelegate.engine.pipeline == nil)
                Button("Stop") { appDelegate.engine.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!appDelegate.engine.isRunning)
                Divider()
                Button("Reload Bundled Pipeline") { appDelegate.engine.reloadBundled() }
            }
        }

        Window("History", id: "history") {
            HistoryView()
                .frame(minWidth: 760, minHeight: 460)
        }
        .modelContainer(appDelegate.history.container)
        .keyboardShortcut("y")
    }
}

/// Owns the engine and history, and serves the "Find CLI Tool" service, the app's version of
/// the pipeline's `receive_input` from Quick Actions: selected text becomes Shortcut Input.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Debug snapshots use a throwaway in-memory history so they never write real records.
    @MainActor let history = HistoryStore(inMemory: UserDefaults.standard.string(forKey: "snapshot") != nil)
    @MainActor lazy var engine = PipelineEngine(records: history)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        #if DEBUG
        MainActor.assumeIsolated { DebugSnapshot.startIfRequested(engine: engine, history: history) }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor @objc func findCLITool(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        NSApp.activate()
        engine.run(shortcutInput: text)
    }
}
