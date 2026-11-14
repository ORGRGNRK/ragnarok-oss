import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var server: ServerManager
    @AppStorage(SettingsKey.modelPath) private var modelPath = AppSettings.defaultModelPath
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend
    @State private var showingTasks = false

    var body: some View {
        NavigationSplitView {
            if showingTasks {
                TaskBoardView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
            } else {
                ConversationListView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
            }
        } detail: {
            ChatView()
        }
        .navigationTitle(chat.selectedConversation?.title ?? "LocalAI")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingTasks.toggle()
                } label: {
                    Label("Tasks", systemImage: "checklist")
                }
                .help("Show tasks")

                Button {
                    chat.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(item: $chat.pendingCommand) { pending in
            CommandApprovalSheet(pending: pending)
                .interactiveDismissDisabled()
        }
        .task(id: backend) {
            // Only load the ~4 GB MLX model when the on-device backend is selected.
            if AppSettings.backend == .mlx {
                modelManager.loadIfNeeded(path: modelPath)
            } else {
                await server.refresh()
            }
        }
    }
}

// MARK: - Sidebar

struct ConversationListView: View {
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        List(selection: $chat.selectedID) {
            ForEach(chat.conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    Text(conversation.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(conversation.id)
                .contextMenu {
                    Button("Delete Chat", role: .destructive) {
                        chat.delete(conversation.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var modelManager: ModelManager

    private let bottomID = "bottom-anchor"
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ModelStatusBar()
            Divider()
            UsageBar()
            transcript
            Divider()
            InputBar()
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            AttachmentPicker.handleDrop(providers, chat: chat)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let messages = chat.selectedConversation?.messages ?? []
                    if messages.isEmpty {
                        EmptyChatView()
                    }
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            isStreaming: chat.streamingMessageID == message.id)
                        .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.scrollTick) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: chat.selectedID) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

struct EmptyChatView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var server: ServerManager
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Start a conversation")
                .font(.title3)
            Text(emptyHint)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyHint: String {
        if backend == ChatBackend.server.rawValue {
            return chat.backendReady
                ? "Chatting with \(server.selectedModel) on your model server. Attach files with the paperclip, drag & drop, or ⌘V."
                : "Connect to a model server and pick a model to start."
        }
        return modelManager.isReady
            ? "Everything runs on this Mac — nothing leaves your machine."
            : "The model needs to finish loading before you can chat."
    }
}

// MARK: - Model status

struct ModelStatusBar: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var chat: ChatViewModel
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend

    var body: some View {
        Group {
            if backend == ChatBackend.server.rawValue {
                ServerStatusBar()
            } else {
                mlxStatus
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var mlxStatus: some View {
            switch modelManager.state {
            case .idle:
                HStack {
                    Image(systemName: "cpu")
                    Text("Model not loaded")
                    Spacer()
                    Button("Load Model") { modelManager.load(path: AppSettings.modelPath) }
                }
            case .loading(let stage, let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(stage).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: fraction)
                }
            case .loaded(let name, let detail):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(name).fontWeight(.medium).lineLimit(1)
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    LocalModelMenu()
                    Button("Reload") {
                        chat.stop()
                        modelManager.load(path: AppSettings.modelPath)
                    }
                    .disabled(chat.isGenerating)
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        SettingsLink { Text("Open Settings…") }
                        Button("Retry") { modelManager.load(path: AppSettings.modelPath) }
                    }
                }
            }
    }
}

// MARK: - Usage

/// Per-conversation token usage totals (port of the Python CLI's usage_totals).
struct UsageBar: View {
    @EnvironmentObject private var chat: ChatViewModel
    @AppStorage(SettingsKey.toolsEnabled) private var toolsEnabled = AppSettings.defaultToolsEnabled

    var body: some View {
        let usage = chat.selectedConversation?.usage ?? UsageTotals()
        HStack(spacing: 12) {
            Label("Session usage", systemImage: "chart.bar")
            Text("prompt \(usage.promptTokens.formatted())")
            Text("completion \(usage.completionTokens.formatted())")
            Text("total \(usage.totalTokens.formatted()) tokens")
                .fontWeight(.medium)
            Spacer()
            if toolsEnabled {
                Label("Tools on", systemImage: "wrench.and.screwdriver")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Input

struct InputBar: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var server: ServerManager
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend
    @FocusState private var focused: Bool
    @State private var pasteMonitor = PasteMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AttachmentChipsView()
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    AttachmentPicker.present(chat: chat)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .padding(.bottom, 8)
                .disabled(chat.isGenerating)
                .help("Attach files or images (⇧⌘O). You can also drag & drop or paste (⌘V).")

                TextField(placeholder, text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3))
                    )

                if chat.isGenerating {
                    Button(role: .cancel) {
                        chat.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .help("Stop generating (⌘.)")
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend)
                    .help("Send (Return or ⌘Return). Option-Return inserts a new line.")
                }
            }
            if let error = chat.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .onAppear {
            focused = true
            pasteMonitor.install(chat: chat)
        }
        .onDisappear { pasteMonitor.remove() }
    }

    private var placeholder: String {
        if chat.backendReady { return "Message LocalAI…" }
        return backend == ChatBackend.server.rawValue
            ? "Connect to a model server and choose a model…" : "Waiting for the model to load…"
    }
}
