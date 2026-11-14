import SwiftUI

struct StepList: View {
    @Bindable var engine: PipelineEngine

    var body: some View {
        List(selection: $engine.selectedStepID) {
            ForEach(engine.rows) { row in
                if let action = row.action {
                    StepRowView(action: action, status: engine.statuses[action.id] ?? .pending)
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .tag(action.id)
                } else if let label = row.branchLabel {
                    Text(label.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct StepRowView: View {
    let action: Action
    let status: StepStatus

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: status)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .lineLimit(1)
                Text(action.type)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(status == .skipped ? 0.45 : 1)
    }
}

struct StatusIcon: View {
    let status: StepStatus

    var body: some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        }
    }
}
