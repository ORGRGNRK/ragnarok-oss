import SwiftUI

/// Live progress for a running Resume or "Change it", right under its button: which stage it's in, how long it has been
/// going, when it last printed something, and the latest thing the AI did. The scripts print "▸ stage: <key>" lines
/// (heimdall-edit, ragnarok-heal, ragnarok-resume); the AI's own steps arrive as "· reading X" lines from bin/claude-live.
extension HubModel {
    nonisolated static let stages: [(key: String, label: String)] = [
        ("packet", "Read packet"), ("ai", "AI working"), ("build", "Build"), ("test", "Test"), ("install", "Install"), ("save", "New packet")]

    /// The last "▸ stage:" marker in the output (nil before the first one).
    nonisolated static func stage(in output: String) -> String? {
        var last: String?
        for line in output.split(separator: "\n") where line.hasPrefix("▸ stage: ") {
            last = line.dropFirst("▸ stage: ".count).trimmingCharacters(in: .whitespaces)
        }
        return last
    }

    /// "round 2/3" from ragnarok-resume's "=== round 2/3 · …" lines (nil if there are none).
    nonisolated static func round(in output: String) -> String? {
        var last: String?
        for line in output.split(separator: "\n") where line.hasPrefix("=== round ") {
            last = line.dropFirst(4).split(separator: " ").prefix(2).joined(separator: " ")
        }
        return last
    }

    /// The newest line worth showing: skips blanks, stage markers and the "[exit …]" footer.
    nonisolated static func lastActivity(in output: String) -> String {
        for line in output.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.hasPrefix("▸ stage:"), !t.hasPrefix("[exit") { return String(t.prefix(160)) }
        }
        return ""
    }
}

struct RunProgress: View {
    @EnvironmentObject var hub: HubModel
    /// "resume" shows the packet stages too; "heal" shows only AI → build → test → install.
    var kind: String

    var body: some View {
        if hub.running != nil, hub.runKind == kind, let start = hub.runStarted {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let st = HubModel.stage(in: hub.output)
                let steps = HubModel.stages.filter { kind == "resume" || ($0.key != "packet" && $0.key != "save") }
                let cur = steps.firstIndex { $0.key == st } ?? 0
                let quiet = max(0, Int(ctx.date.timeIntervalSince(hub.lastOutputAt ?? start)))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 3) {
                                if i < cur { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else if i == cur { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "circle").foregroundStyle(.secondary) }
                                Text(s.label).font(.caption).fontWeight(i == cur ? .semibold : .regular)
                                    .foregroundStyle(i <= cur ? .primary : .secondary)
                            }
                            if i < steps.count - 1 {
                                Rectangle().fill(i < cur ? Color.green : Color.secondary.opacity(0.3)).frame(width: 12, height: 2)
                            }
                        }
                    }
                    ProgressView(value: Double(cur) + 0.5, total: Double(steps.count))
                    Text([HubModel.round(in: hub.output), Self.dur(ctx.date.timeIntervalSince(start)) + " so far",
                          quiet < 5 ? "working" : "last output \(Self.dur(Double(quiet))) ago",
                          st == "ai" && quiet >= 60 ? "the AI is thinking; long quiet spells are normal" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    let last = HubModel.lastActivity(in: hub.output)
                    if !last.isEmpty {
                        Text(last).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    }
                }
                .padding(8).background(Color.accentColor.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    nonisolated static func dur(_ s: Double) -> String { let n = Int(s); return n < 60 ? "\(n)s" : "\(n / 60)m \(n % 60)s" }
}
