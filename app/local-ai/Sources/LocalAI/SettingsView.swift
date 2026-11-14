import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var chat: ChatViewModel

    @AppStorage(SettingsKey.modelPath) private var modelPath = AppSettings.defaultModelPath
    @AppStorage(SettingsKey.systemPrompt) private var systemPrompt = AppSettings.defaultSystemPrompt
    @AppStorage(SettingsKey.temperature) private var temperature = AppSettings.defaultTemperature
    @AppStorage(SettingsKey.maxTokens) private var maxTokens = AppSettings.defaultMaxTokens
    @AppStorage(SettingsKey.toolsEnabled) private var toolsEnabled = AppSettings.defaultToolsEnabled
    @AppStorage(SettingsKey.writeFileEnabled) private var writeFileEnabled = true
    @AppStorage(SettingsKey.runCommandEnabled) private var runCommandEnabled = false
    @AppStorage(SettingsKey.commandTimeout) private var commandTimeout = 60.0
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend
    @AppStorage(SettingsKey.serverURL) private var serverURL = AppSettings.defaultServerURL
    @AppStorage(SettingsKey.serverAPIKind) private var serverAPIKind = AppSettings.defaultServerAPIKind
    @EnvironmentObject private var server: ServerManager
    @State private var localModels: [String] = []
    @State private var pullName = ""

    var body: some View {
        Form {
            Section {
                Picker("Reply with", selection: $backend) {
                    ForEach(ChatBackend.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(
                    backend == ChatBackend.mlx.rawValue
                        ? "Runs the MLX model below inside this app on the GPU. Text only."
                        : "Sends chats to a local OpenAI-compatible server (LM Studio, llama.cpp…) or Ollama. Supports images with vision models. The on-device model is not loaded in this mode."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Backend")
            }

            if backend == ChatBackend.server.rawValue {
                serverSection
            }

            Section {
                Picker("Installed MLX models", selection: $modelPath) {
                    if !localModels.contains(modelPath) {
                        Text(modelPath).tag(modelPath)
                    }
                    ForEach(localModels, id: \.self) { path in
                        Text((path as NSString).lastPathComponent).tag(path)
                    }
                }
                .onAppear { localModels = ModelManager.discoverLocalModels() }
                HStack {
                    Spacer()
                    Button {
                        localModels = ModelManager.discoverLocalModels()
                    } label: {
                        Label("Refresh list", systemImage: "arrow.clockwise")
                    }
                }
                TextField("Model directory", text: $modelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Resolves to: \(AppSettings.resolvedURL(forPath: modelPath).path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose…") { chooseDirectory() }
                    Button("Use Default") { modelPath = AppSettings.defaultModelPath }
                    Spacer()
                    Button(modelManager.isReady ? "Reload Model" : "Load Model") {
                        chat.stop()
                        modelManager.load(path: modelPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(modelManager.state.isLoading || chat.isGenerating)
                }
                statusLine
            } header: {
                Text("Model (MLX format, loaded from disk — no network)")
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                HStack {
                    Spacer()
                    Button("Reset to Default") { systemPrompt = AppSettings.defaultSystemPrompt }
                }
            } header: {
                Text("System Prompt")
            }

            Section {
                HStack {
                    Text("Temperature")
                    Slider(value: $temperature, in: 0...2, step: 0.05)
                    Text(String(format: "%.2f", temperature))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Max tokens")
                    Spacer()
                    TextField("", value: $maxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Stepper("", value: $maxTokens, in: 16...32_768, step: 256)
                        .labelsHidden()
                }
                Text("Temperature 0 = deterministic. Changes apply to the next message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Generation")
            }

            Section {
                Toggle("Let the model call tools", isOn: $toolsEnabled)
                Text(
                    "get_time, list_dir and read_file (read-only; files capped at \(LocalTools.maxFileChars) chars, folders at \(LocalTools.maxDirEntries) entries; up to \(LocalTools.maxRounds) tool rounds per reply). Relative paths resolve against your home folder."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("write_file — create/overwrite files in ~/LocalAI-Workspace", isOn: $writeFileEnabled)
                    .disabled(!toolsEnabled)
                Toggle("run_command — run shell commands (you approve each one)", isOn: $runCommandEnabled)
                    .disabled(!toolsEnabled)
                HStack {
                    Text("Command timeout (seconds)")
                    Spacer()
                    TextField("", value: $commandTimeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Stepper("", value: $commandTimeout, in: 5...3600, step: 15).labelsHidden()
                }
                .disabled(!toolsEnabled || !runCommandEnabled)
                HStack {
                    Text("Workspace: ~/LocalAI-Workspace").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        if let url = try? WorkspaceSandbox.ensureRoot() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Tools")
            }

            Section {
                Text(chat.chatsFilePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Chat history file")
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 780)
        .onChange(of: maxTokens) {
            if maxTokens < 16 { maxTokens = 16 }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("Server URL", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("LM Studio (1234)") { serverURL = "http://127.0.0.1:1234" }
                Button("Ollama (11434)") { serverURL = "http://127.0.0.1:11434" }
                Spacer()
            }
            .controlSize(.small)
            Picker("API", selection: $serverAPIKind) {
                ForEach(ServerAPIKind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                serverStatusLine
                Spacer()
                Button {
                    Task { await server.refresh() }
                } label: {
                    Label("Connect / Refresh Models", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.status == .checking)
            }
            if !server.models.isEmpty {
                LabeledContent("Model") {
                    ServerModelPicker()
                }
                if !server.selectedModel.isEmpty {
                    Text(
                        server.supportsVision(server.selectedModel)
                            ? "Vision: likely supported — images are sent as image_url data URIs."
                            : "Vision: not detected — images may be ignored or rejected."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if server.detectedKind == .ollama {
                HStack {
                    TextField("Pull a model by name (e.g. qwen2.5-coder:7b, llava)", text: $pullName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { server.pull(pullName) }
                    if server.isPulling {
                        Button("Cancel") { server.cancelPull() }
                    } else {
                        Button("Pull") { server.pull(pullName) }
                            .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let status = server.pullStatus {
                    if server.isPulling, let fraction = server.pullFraction {
                        ProgressView(value: fraction) {
                            Text(status).font(.caption).lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 6) {
                            if server.isPulling { ProgressView().controlSize(.small) }
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Model server")
        } footer: {
            Text(
                "Models come from GET /v1/models (OpenAI-compatible) or GET /api/tags (Ollama); chat uses POST /v1/chat/completions (streamed). The selected model is remembered."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: serverURL) { Task { await server.refresh() } }
        .onChange(of: serverAPIKind) { Task { await server.refresh() } }
    }

    @ViewBuilder
    private var serverStatusLine: some View {
        switch server.status {
        case .unknown:
            Text("Not checked yet").font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption)
            }
        case .online(let kind):
            Text("Connected · \(kind.label) · \(server.models.count) model(s)")
                .font(.caption).foregroundStyle(.green)
        case .offline(let message):
            Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch modelManager.state {
        case .idle:
            Text("Not loaded").font(.caption).foregroundStyle(.secondary)
        case .loading(let stage, let fraction):
            ProgressView(value: fraction) {
                Text(stage).font(.caption)
            }
        case .loaded(let name, let detail):
            Text("Loaded \(name) — \(detail)").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true  // ~/.lmstudio is a hidden folder
        panel.prompt = "Use This Model"
        panel.message = "Choose an MLX model folder (contains config.json and *.safetensors)"
        let current = AppSettings.resolvedURL(forPath: modelPath)
        panel.directoryURL =
            FileManager.default.fileExists(atPath: current.path)
            ? current : current.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            modelPath = AppSettings.abbreviatedPath(url)
        }
    }
}

/// Compact "switch model" menu in the MLX status bar, listing discovered local folders.
struct LocalModelMenu: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var chat: ChatViewModel
    @AppStorage(SettingsKey.modelPath) private var modelPath = AppSettings.defaultModelPath
    @State private var models: [String] = []

    var body: some View {
        Menu {
            ForEach(models, id: \.self) { path in
                Button {
                    modelPath = path
                    chat.stop()
                    modelManager.load(path: path)
                } label: {
                    if path == modelPath {
                        Label((path as NSString).lastPathComponent, systemImage: "checkmark")
                    } else {
                        Text((path as NSString).lastPathComponent)
                    }
                }
            }
            if models.isEmpty { Text("No MLX models found in ~/.lmstudio/models") }
            Divider()
            Button("Refresh List") { models = ModelManager.discoverLocalModels() }
        } label: {
            Label("Model", systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .disabled(chat.isGenerating || modelManager.state.isLoading)
        .onAppear { models = ModelManager.discoverLocalModels() }
    }
}
