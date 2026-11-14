#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// Debug builds only: `-snapshot <dir>` saves PNGs of the app's windows, so the UI can be checked
/// without Screen Recording permission. Add `-demo-query "<text>"` to also run the pipeline:
/// it answers the first question with that text, captures the Run a Command / Done menu, picks
/// Done, and captures the History window. History is in memory for snapshots, so no real
/// records are written. The app quits when done.
///
/// The macOS 26 glass sidebar is composited by the window server and comes out blank when a
/// window draws itself, so the sidebars in these images are the same row views rendered
/// separately with ImageRenderer and drawn into the sidebar area.
@MainActor
enum DebugSnapshot {
    static let openHistory = Notification.Name("DebugSnapshot.openHistory")

    static func startIfRequested(engine: PipelineEngine, history: HistoryStore) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshot") else { return }
        let query = UserDefaults.standard.string(forKey: "demo-query")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            capture(title: "CLI Tools", to: dir, name: "1-idle", sidebar: StepSidebar(engine: engine))
            guard let query else { NSApp.terminate(nil); return }

            engine.run()
            var answered = false
            for _ in 0..<1200 {
                if let i = engine.interaction {
                    if case .text(_, let suggestion, _) = i.kind {
                        if !answered {
                            try? await Task.sleep(for: .seconds(0.5))
                            capture(title: "CLI Tools", to: dir, name: "2-ask", sidebar: StepSidebar(engine: engine))
                            engine.respond(to: i, with: query)
                            answered = true
                        } else {
                            // Accept the suggested command, minus any <placeholder> arguments.
                            let words = suggestion.split(separator: " ").filter { !$0.contains("<") }
                            engine.respond(to: i, with: words.joined(separator: " "))
                        }
                    } else if case .menu(_, let items) = i.kind {
                        engine.selectedStepID = "a6r"
                        try? await Task.sleep(for: .seconds(0.5))
                        capture(title: "CLI Tools", to: dir, name: "3-menu", sidebar: StepSidebar(engine: engine))
                        engine.respond(to: i, with: items.first ?? "Done")
                    } else if case .alert = i.kind {
                        engine.respond(to: i, with: "OK")
                    }
                }
                if !engine.isRunning, engine.runSummary != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            NotificationCenter.default.post(name: openHistory, object: nil)
            try? await Task.sleep(for: .seconds(1.5))
            let lookups = (try? history.container.mainContext.fetch(FetchDescriptor<Lookup>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
            capture(title: "History", to: dir, name: "4-history", sidebar: HistorySidebar(lookups: lookups))
            NSApp.terminate(nil)
        }
    }

    private static func capture(title: String, to dir: String, name: String, sidebar: some View) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let windowImage = rep.cgImage else { return }

        let scale = window.backingScaleFactor
        // History's sidebar starts below its search field.
        let sidebarWidth: CGFloat = title == "History" ? 300 : 280, toolbarHeight: CGFloat = title == "History" ? 100 : 52
        let width = windowImage.width, height = windowImage.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(windowImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sidebarHeight = CGFloat(height) / scale - toolbarHeight
        let renderer = ImageRenderer(content: sidebar.frame(width: sidebarWidth, height: sidebarHeight, alignment: .top))
        renderer.scale = scale
        if let image = renderer.cgImage {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }

        guard let image = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The pipeline step rows outside of List, for snapshots only.
private struct StepSidebar: View {
    let engine: PipelineEngine

    var body: some View {
        SnapshotColumn {
            ForEach(engine.rows) { row in
                Group {
                    if let action = row.action {
                        StepRowView(action: action, status: engine.statuses[action.id] ?? .pending).frame(height: 38)
                    } else if let label = row.branchLabel {
                        Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(height: 32)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 12 + 10)
                .modifier(SnapshotSelection(selected: row.id == engine.selectedStepID))
            }
        }
    }
}

/// The history rows outside of List, for snapshots only.
private struct HistorySidebar: View {
    let lookups: [Lookup]

    var body: some View {
        SnapshotColumn {
            ForEach(Array(lookups.enumerated()), id: \.offset) { index, lookup in
                HistoryRow(lookup: lookup)
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .modifier(SnapshotSelection(selected: index == 0))
            }
        }
    }
}

private struct SnapshotColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct SnapshotSelection: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 8)
                }
            }
    }
}
#endif
