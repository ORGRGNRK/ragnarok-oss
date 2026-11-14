import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LocalAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var modelManager: ModelManager
    @StateObject private var chat: ChatViewModel
    @StateObject private var serverManager: ServerManager
    @StateObject private var taskStore: TaskStore
    @StateObject private var seatRegistry: SeatRegistry

    init() {
        AppSettings.registerDefaults()
        ModelManager.configureMLX()
        let manager = ModelManager()
        let server = ServerManager()
        let store = TaskStore()
        let seats = SeatRegistry()
        _modelManager = StateObject(wrappedValue: manager)
        _serverManager = StateObject(wrappedValue: server)
        _taskStore = StateObject(wrappedValue: store)
        _seatRegistry = StateObject(wrappedValue: seats)
        _chat = StateObject(wrappedValue: ChatViewModel(modelManager: manager, serverManager: server))
    }

    var body: some Scene {
        Window("LocalAI", id: "main") {
            ContentView()
                .environmentObject(modelManager)
                .environmentObject(chat)
                .environmentObject(serverManager)
                .environmentObject(taskStore)
                .environmentObject(seatRegistry)
                .frame(minWidth: 780, minHeight: 520)
                .task {
                    seatRegistry.configure(modelManager: modelManager, serverManager: serverManager)
                }
                .onChange(of: serverManager.selectedModel) {
                    seatRegistry.configure(modelManager: modelManager, serverManager: serverManager)
                }
                .onChange(of: modelManager.loadedModelURL) {
                    seatRegistry.configure(modelManager: modelManager, serverManager: serverManager)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { chat.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Chat") {
                Button("Stop Generating") { chat.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!chat.isGenerating)
                Button("Clear Conversation") { chat.clearSelected() }
                    .disabled(chat.isGenerating)
                Divider()
                Button("Attach Files…") { AttachmentPicker.present(chat: chat) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(chat.isGenerating)
                Divider()
                Button("Reload Model") {
                    chat.stop()
                    modelManager.load(path: AppSettings.modelPath)
                }
                .disabled(modelManager.state.isLoading || chat.isGenerating)
                Button("Refresh Server Models") {
                    Task { await serverManager.refresh() }
                }
            }
            CommandMenu("Tasks") {
                Button("Run Next Leg (conveyor)") {
                    Task {
                        let runner = HarnessRunner()
                        _ = try? await runner.runNextLeg(in: taskStore, registry: seatRegistry)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(modelManager)
                .environmentObject(chat)
                .environmentObject(serverManager)
        }
    }
}
