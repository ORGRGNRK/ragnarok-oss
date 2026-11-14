#if os(macOS)
import SwiftUI

/// One owner/repair state shared by all of Ragnarok's companion panels.
@MainActor public final class AlexusWorkspace: ObservableObject {
    let model = AppModel()
    private var refreshed = false
    public init() {}
    func start() async {
        guard !refreshed else { return }
        refreshed = true
        await model.refresh()
    }
}

public enum AlexusSection: String, CaseIterable {
    case catalog, chat, deployments, receipts, repairs, devices, about
}

public struct AlexusPanel: View {
    @ObservedObject private var workspace: AlexusWorkspace
    private let section: AlexusSection
    public init(_ section: AlexusSection, workspace: AlexusWorkspace) {
        self.section = section
        self.workspace = workspace
    }
    public var body: some View {
        Group {
            switch section {
            case .catalog: ProjectsView()
            case .chat: ChatView()
            case .deployments: DeploymentsView()
            case .receipts: RepairReceiptsView()
            case .repairs:
                VStack(spacing: 0) {
                    Text("Companion repairs change ALEXUS and its iOS app. They do not update Ragnarok. Both hardware proofs are still required.")
                        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                    RepairsView()
                }
            case .devices: SecurityView()
            case .about: OriginView()
            }
        }
        .environmentObject(workspace.model)
        .environment(\.colorScheme, .dark)
        .task { await workspace.start() }
        .overlay(alignment: .bottom) {
            AlexusMessage(model: workspace.model)
        }
    }
}

private struct AlexusMessage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.message.isEmpty {
            HStack {
                Text(model.message).font(.callout)
                Spacer()
                Button("Dismiss") { model.message = "" }
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
        }
    }
}

/// Ragnarok already supplies the timeline and live agent list. Only companion receipts are added here.
private struct RepairReceiptsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "Repair history") {
            Button("Refresh repair history") { Task { await model.refresh() } }
            Text("Chain integrity: " + (model.host?.receipt_integrity ?? "Unverified"))
            ForEach((model.host?.receipts ?? []).reversed()) { receipt in
                Panel {
                    Text("\(receipt.sequence) · \(receipt.action)").font(.headline)
                    Text(receipt.timestamp).font(.caption.monospaced())
                    Text(receipt.hash).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
            if model.host?.receipts.isEmpty != false {
                Text("No companion repair receipts loaded.").foregroundStyle(.secondary)
            }
        }
    }
}
#endif
