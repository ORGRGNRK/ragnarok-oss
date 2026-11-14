import SwiftUI
import AlexusKit
import Belt

/// Legacy destinations remain the source of truth for Hub buttons and ragnarok:// links.
enum WorkspaceSection: String, CaseIterable, Identifiable {
    case projects, chat, tasks, activity, money, intake, home, browser, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .chat: "bubble.left.and.bubble.right"
        case .tasks: "checklist"
        case .activity: "clock"
        case .money: "dollarsign.circle"
        case .intake: "tray.and.arrow.down"
        case .home: "house"
        case .browser: "globe"
        case .settings: "gearshape"
        }
    }
    var destinations: [(id: String, title: String)] {
        switch self {
        case .projects: [("hub", "My projects"), ("catalog", "Work catalog"), ("shell", "Terminal")]
        case .chat: [("alexus", "Conversation"), ("local-chat", "Local tools"), ("room", "Shared room")]
        case .tasks: [("agents", "Agent runs"), ("deployments", "Step-by-step jobs"), ("belt", "Conveyor")]
        case .activity: [("timeline", "Timeline"), ("repair-history", "Repair history")]
        case .settings: [("devices", "Devices & security"), ("repairs", "Companion repairs"), ("about", "About")]
        case .money: [("money", "Money")]
        case .intake: [("intake", "Intake")]
        case .home: [("home", "Home")]
        case .browser: [("browser", "Browser")]
        }
    }
    static func containing(_ destination: String) -> Self {
        allCases.first { $0.destinations.contains { $0.id == destination } } ?? .projects
    }
}

struct WorkspaceView: View {
    @ObservedObject var hub: HubModel
    let store: Store
    let editor: Editor
    let chat: ChatModel
    let shell: ShellSession
    let room: RoomModel
    @StateObject private var alexus = AlexusWorkspace()
    @State private var remembered: [WorkspaceSection: String] = [:]

    private var selection: Binding<WorkspaceSection> {
        Binding(get: { WorkspaceSection.containing(hub.tab) }, set: { section in
            let previous = WorkspaceSection.containing(hub.tab)
            remembered[previous] = hub.tab
            hub.tab = remembered[section] ?? section.destinations[0].id
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(WorkspaceSection.allCases) { section in
                    Button { selection.wrappedValue = section } label: {
                        Label(section.title, systemImage: section.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(selection.wrappedValue == section ? Color.white : Color.primary)
                            .background(selection.wrappedValue == section ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .accessibilityValue(selection.wrappedValue == section ? "Selected" : "")
                }
            }.padding(10)
            Divider()
            sectionView(selection.wrappedValue)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func destination(for section: WorkspaceSection) -> Binding<String> {
        Binding(get: {
            WorkspaceSection.containing(hub.tab) == section ? hub.tab : remembered[section] ?? section.destinations[0].id
        }, set: { hub.tab = $0; remembered[section] = $0 })
    }
    private func sectionView(_ section: WorkspaceSection) -> some View {
        VStack(spacing: 0) {
            if section.destinations.count > 1 {
                HStack {
                    Text(section.title).font(.headline)
                    Spacer()
                    Picker(section.title, selection: destination(for: section)) {
                        ForEach(section.destinations, id: \.id) { item in Text(item.title).tag(item.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
            }
            panel(destination(for: section).wrappedValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private func panel(_ id: String) -> some View {
        switch id {
        case "hub": HubView().environmentObject(hub).environmentObject(store).environmentObject(room)
        case "catalog": AlexusPanel(.catalog, workspace: alexus)
        case "shell": ShellView().environmentObject(shell)
        case "alexus": ChatView().environmentObject(chat)
        case "local-chat": AlexusPanel(.chat, workspace: alexus)
        case "room": RoomView().environmentObject(room).environmentObject(shell).environmentObject(hub)
        case "agents": AgentsView()
        case "deployments": AlexusPanel(.deployments, workspace: alexus)
        case "belt": BeltTab()
        case "timeline": MainView().environmentObject(store).environmentObject(editor)
        case "repair-history": RepairHistoryView(alexus: alexus)
        case "money": MoneyView()
        case "intake": IntakeView().accessibilityIdentifier(Intake.tabMarker)
        case "home": HomeAssistantView()
        case "browser": BrowserView()
        case "devices": AlexusPanel(.devices, workspace: alexus)
        case "repairs": AlexusPanel(.repairs, workspace: alexus)
        case "about": AlexusPanel(.about, workspace: alexus)
        default: EmptyView()
        }
    }
}
