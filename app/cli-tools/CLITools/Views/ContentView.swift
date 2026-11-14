import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var engine: PipelineEngine
    @State private var importing = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            StepList(engine: engine)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                banners
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let interaction = engine.interaction, !interaction.isAlert {
                            InteractionCard(interaction: interaction) { engine.respond(to: interaction, with: $0) }
                                .id(interaction.id)
                        }
                        if let id = engine.selectedStepID, let action = engine.action(withID: id) {
                            StepDetailView(engine: engine, action: action)
                        } else {
                            PipelineOverview(engine: engine)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let summary = engine.runSummary {
                    Divider()
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(engine.pipeline?.shortcut.name ?? "CLI Tools")
        .navigationSubtitle(engine.pipelineSource)
        .toolbar {
            ToolbarItemGroup {
                Button("History", systemImage: "clock.arrow.circlepath") { openWindow(id: "history") }
                    .help("Every saved lookup and command run (⌘Y)")
                Button("Open Pipeline…", systemImage: "doc.badge.gearshape") { importing = true }
                    .help("Run a different pipeline JSON file")
                if engine.isRunning {
                    Button("Stop", systemImage: "stop.fill") { engine.cancel() }
                } else {
                    Button("Run", systemImage: "play.fill") { engine.run() }
                        .disabled(engine.pipeline == nil)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { engine.open(url: url) }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.openHistory)) { _ in openWindow(id: "history") }
        #endif
        .alert(
            engine.interaction?.alertTitle ?? "",
            isPresented: Binding(
                get: { engine.interaction?.isAlert == true },
                set: { if !$0, let i = engine.interaction, i.isAlert { engine.respond(to: i, with: "OK") } }
            ),
            presenting: engine.interaction
        ) { interaction in
            Button("OK") { engine.respond(to: interaction, with: "OK") }
        } message: { interaction in
            Text(interaction.alertMessage)
        }
    }

    @ViewBuilder private var banners: some View {
        if let error = engine.loadError {
            Banner(systemImage: "exclamationmark.triangle.fill", text: error, tint: .red)
        }
        if let reason = OnDeviceModel.availabilityNote {
            Banner(systemImage: "apple.intelligence", text: "On-device model unavailable: \(reason)", tint: .orange)
        }
    }
}

private struct Banner: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12))
    }
}

extension Interaction {
    var isAlert: Bool { if case .alert = kind { true } else { false } }
    var alertTitle: String { if case .alert(let title, _) = kind { title } else { "" } }
    var alertMessage: String { if case .alert(_, let message) = kind { message } else { "" } }
}

extension PipelineEngine {
    func action(withID id: String) -> Action? {
        rows.first { $0.id == id }?.action
    }
}
