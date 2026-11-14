import AppKit
import SwiftUI

public struct CommandInspectorCard: View {
    @EnvironmentObject var state: AppState
    let cmd: ShellCommand

    @State private var copied: Bool = false
    @State private var copiedPath: Bool = false

    public init(cmd: ShellCommand) {
        self.cmd = cmd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header Row: Status & Timestamp
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: cmd.isFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(cmd.isFailed ? .red : .green)
                    Text(cmd.isFailed ? "Failed (Exit \(cmd.exitCode))" : "Success (Exit 0)")
                        .font(.caption.bold())
                        .foregroundStyle(cmd.isFailed ? .red : .green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((cmd.isFailed ? Color.red : Color.green).opacity(0.12))
                .clipShape(Capsule())

                Text(cmd.src)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Spacer()

                if !cmd.formattedTime.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(cmd.formattedTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(cmd.ts)
                }
            }

            // Command Box with Copy Button
            HStack(alignment: .top, spacing: 8) {
                Text(cmd.cmd)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd.cmd, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Copy command to clipboard")
            }

            // Directory Row
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(cmd.cwd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd.cwd, forType: .string)
                    copiedPath = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedPath = false
                    }
                } label: {
                    Image(systemName: copiedPath ? "checkmark" : "doc.on.clipboard")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Copy folder path")

                if FileManager.default.fileExists(atPath: (cmd.cwd as NSString).expandingTildeInPath) {
                    Button {
                        let path = (cmd.cwd as NSString).expandingTildeInPath
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal folder in Finder")
                }

                Spacer()

                // Actions for this selected command
                HStack(spacing: 8) {
                    Button {
                        state.commandInput = cmd.cmd
                    } label: {
                        Label("Load into Input", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("Populate top input box with this command")

                    Button {
                        state.runPipeline(cmd: cmd.cmd)
                    } label: {
                        Label("Run in Pipeline", systemImage: "play.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(state.isRunning || state.isAgentRunning)
                    .help("Execute command through Heimdall pipeline runner")

                    if cmd.isFailed {
                        Button {
                            state.debugLast()
                        } label: {
                            Label("Debug Error", systemImage: "sparkles")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(state.isRunning || state.isAnalyzing || state.isAgentRunning)
                        .help("Diagnose root cause and suggest code fix")
                    }

                    Button {
                        state.launchAutonomousAgent(task: "Fix failure for command '\(cmd.cmd)' in directory '\(cmd.cwd)'")
                    } label: {
                        Label("AI Agent Repair", systemImage: "figure.run")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .disabled(state.isRunning || state.isAnalyzing || state.isAgentRunning)
                    .help("Repair a disposable copy with frozen outside checks")
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cmd.isFailed ? Color.red.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
