import SwiftUI
#if os(macOS)
import AppKit
#endif
import PhoneGraderCore

#if os(macOS)
struct PhoneGraderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()
    @StateObject private var rig = RigSession()

    var body: some Scene {
        WindowGroup("PhoneGrader") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.history)
                .environmentObject(rig)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Phone") { state.newSession() }.keyboardShortcut("n")
            }
        }
        Settings {
            SettingsView().environmentObject(state).frame(width: 640, height: 640)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

enum Tab: String, CaseIterable, Identifiable {
    case rig = "Rig", grade = "Grade", price = "Price", comps = "Comps", listing = "Listing", history = "History", parts = "Parts", settings = "Settings"
    var id: String { rawValue }
    /// iPhone/iPad tab order: the first four sit in the tab bar on iPhone, the rest under More.
    static let iOSOrder: [Tab] = [.grade, .price, .listing, .history, .parts, .comps, .rig, .settings]
    var icon: String {
        switch self {
        case .rig: return "rotate.3d"
        case .grade: return "camera.viewfinder"
        case .price: return "dollarsign.circle"
        case .comps: return "chart.bar.xaxis"
        case .listing: return "text.bubble"
        case .history: return "clock.arrow.circlepath"
        case .parts: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .grade
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iOSBody
        #endif
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var iOSSelection = Tab.grade.rawValue
    @State private var morePath: [Tab] = []
    static let moreTag = "More"
    /// iPhone: four tabs + our own More list (one navigation stack, no nested bars). iPad: every tab.
    var primaryTabs: [Tab] { hSize == .compact ? Array(Tab.iOSOrder.prefix(4)) : Tab.iOSOrder }
    var moreTabs: [Tab] { hSize == .compact ? Array(Tab.iOSOrder.dropFirst(4)) : [] }

    var iOSBody: some View {
        TabView(selection: $iOSSelection) {
            ForEach(primaryTabs) { t in
                NavigationStack { chrome(t) }
                    .tabItem { Label(t.rawValue, systemImage: t.icon) }
                    .tag(t.rawValue)
            }
            if !moreTabs.isEmpty {
                NavigationStack(path: $morePath) {
                    List(moreTabs) { t in NavigationLink(value: t) { Label(t.rawValue, systemImage: t.icon) } }
                        .navigationTitle("More")
                        .navigationDestination(for: Tab.self) { t in chrome(t) }
                }
                .tabItem { Label(Self.moreTag, systemImage: "ellipsis.circle") }
                .tag(Self.moreTag)
            }
        }
        .onAppear {
            go(UserDefaults.standard.string(forKey: "PGStartTab").flatMap { n in Tab.allCases.first { $0.rawValue.lowercased() == n.lowercased() } } ?? .grade)
        }
    }

    /// One tab's page with the shared banner and toolbar.
    func chrome(_ t: Tab) -> some View {
        VStack(spacing: 0) {
            StaleBanner()
            page(t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { state.newSession(); go(.grade) } label: { Label("New Phone", systemImage: "plus") }
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() } }
        }
    }
    #endif

    /// Switch tabs (used by "Price it →", "Open in Grade", the rig, …).
    func go(_ t: Tab) {
        tab = t
        #if os(iOS)
        if primaryTabs.contains(t) { iOSSelection = t.rawValue }
        else { iOSSelection = Self.moreTag; morePath = [t] }
        #endif
    }

    @ViewBuilder func page(_ t: Tab) -> some View {
        switch t {
        case .rig: RigView(goTo: { go($0) })
        case .grade: GradeView(goTo: { go($0) })
        case .price: PriceView()
        case .comps: CompsView()
        case .listing: ListingView()
        case .history: HistoryView(goTo: { go($0) })
        case .parts: PartsLogView()
        case .settings: SettingsView()
        }
    }

    #if os(macOS)
    var macBody: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            columns = .all
            // `open PhoneGrader.app --args -PGStartTab Settings` opens on that tab (used for screenshots).
            tab = UserDefaults.standard.string(forKey: "PGStartTab").flatMap { n in Tab.allCases.first { $0.rawValue.lowercased() == n.lowercased() } } ?? .grade
        }
        .onChange(of: columns) { _, v in if v != .all { columns = .all } }   // sidebar can't be lost
    }

    /// Plain buttons rather than List(selection:), so a nil/restored selection can never
    /// leave the sidebar or detail empty.
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Color.accentColor.opacity(0.25) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
    }

    var detail: some View {
        VStack(spacing: 0) {
            StaleBanner()
            Group {
                page(tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 600)
        .toolbar {
            ToolbarItem { Button { state.newSession(); tab = .grade } label: { Label("New Phone", systemImage: "plus") } }
        }
    }
    #endif
}

/// Always-visible warning while the Atlas ladder is past its delivery Friday.
struct StaleBanner: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let err = state.loadError {
            banner("Price list failed to load: \(err)", .red)
        } else if let s = state.ladderStatus, !s.quotable {
            banner("ATLAS LADDER STALE — priced items delivered by \(s.deliveryFriday) (\(s.daysPastDelivery) days ago). Ladder numbers are reference only: no max buy from them. Import a fresh price list or add a buyer quote (Price tab).", .orange)
        }
    }
    func banner(_ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .font(.callout.weight(.semibold))
                #else
                .font(.footnote.weight(.semibold))
                #endif
            Spacer()
        }
        .padding(10).background(color.opacity(0.18)).foregroundStyle(color == .orange ? Color.primary : color)
    }
}

// MARK: shared bits
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

func gradeColor(_ g: String) -> Color {
    switch g { case "A": return .green; case "B": return .mint; case "C": return .yellow; case "D": return .orange; default: return .red }
}

// copyToPasteboard(_:) lives in Platform.swift (NSPasteboard on the Mac, UIPasteboard on iOS).

func bullets(_ items: [String], color: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, s in
            HStack(alignment: .top, spacing: 6) { Text("•"); Text(s).foregroundStyle(color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
