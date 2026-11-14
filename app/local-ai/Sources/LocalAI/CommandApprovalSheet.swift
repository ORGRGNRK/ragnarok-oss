import SwiftUI

/// Approve / Deny for a model-requested run_command. Nothing runs without Approve.
struct CommandApprovalSheet: View {
    @EnvironmentObject private var chat: ChatViewModel
    let pending: ChatViewModel.PendingCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The model wants to run a command", systemImage: "terminal")
                .font(.headline)
            Text("Runs with /bin/zsh -lc in \(pending.cwdDisplay) · timeout \(Int(pending.timeout))s")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(pending.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Commands run as you, with your permissions. Only the working folder is limited to the workspace; the command itself can reach anything you can.")
                .font(.caption)
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { chat.resolvePendingCommand(approved: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Approve & Run") { chat.resolvePendingCommand(approved: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
