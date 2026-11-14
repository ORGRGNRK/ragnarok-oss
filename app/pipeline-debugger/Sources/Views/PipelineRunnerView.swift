import SwiftUI

public struct PipelineRunnerView: View {
    @EnvironmentObject var state: AppState

    public var body: some View {
        HStack(spacing: 10) {
            // Command input box
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)
                TextField("Enter build, test, or pipeline command...", text: $state.commandInput)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        if !state.commandInput.isEmpty {
                            state.runPipeline(cmd: state.commandInput)
                        }
                    }
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            // Provider Picker
            Picker("", selection: $state.selectedProvider) {
                Text("Ollama").tag("ollama")
                Text("Claude Code").tag("claude")
                Text("OpenAI Codex").tag("codex")
                Text("Antigravity").tag("agy")
                Text("xAI Grok").tag("grok")
                Text("Gemini API").tag("gemini")
                Text("OpenAI API").tag("openai")
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            if state.selectedProvider == "ollama" && !state.localModels.isEmpty {
                Menu("Models") {
                    ForEach(state.localModels, id: \.self) { model in
                        Button(model) { state.selectedModel = model }
                    }
                }
            }
            TextField("Model (provider default if blank)", text: $state.selectedModel)
                .frame(width: 160)
            TextField("Project folder", text: $state.projectDirectory)
                .frame(minWidth: 120)

            // Run Button
            Button {
                state.runPipeline(cmd: state.commandInput)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(state.isRunning || state.isAgentRunning || state.commandInput.isEmpty)

            // Debug Last Error Button
            Button {
                state.debugLast()
            } label: {
                Label("Debug Error", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(state.isRunning || state.isAnalyzing || state.isAgentRunning)

            // Autonomous Agent Button
            Button {
                state.launchAutonomousAgent()
            } label: {
                Label("AI Agent", systemImage: "figure.run")
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(state.isRunning || state.isAnalyzing || state.isAgentRunning)
            .help("Repair a disposable copy using outside checks; configure in the Agent tab")

            if state.isRunning || state.isAnalyzing || state.isAgentRunning {
                Button {
                    state.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Stop active process")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
