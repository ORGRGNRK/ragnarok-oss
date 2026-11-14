import SwiftUI

@main
struct PipelineDebuggerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Pipeline Debugger", id: "main") {
            MainSplitView()
                .environmentObject(state)
                .frame(minWidth: 950, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
