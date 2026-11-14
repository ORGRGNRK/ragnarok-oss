import SwiftUI

public struct TerminalView: View {
    @EnvironmentObject var state: AppState

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isRunning ? Color.green : (state.isAnalyzing ? Color.orange : Color.secondary))
                        .frame(width: 8, height: 8)
                    Text(state.isRunning ? "Pipeline Running..." : (state.isAnalyzing ? "AI Analyzing..." : "Console Idle"))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.terminalOutput, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Console Output")

                Button {
                    state.terminalOutput = ""
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Console")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Console text area
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.terminalOutput.isEmpty ? "(Execute a pipeline or click 'Debug Last Error' to inspect logs)" : state.terminalOutput)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color(NSColor.textColor))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottomID")
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: state.terminalOutput) { _, _ in
                    proxy.scrollTo("bottomID", anchor: .bottom)
                }
            }
        }
    }
}
