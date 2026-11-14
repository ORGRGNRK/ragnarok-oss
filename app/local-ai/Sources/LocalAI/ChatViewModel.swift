import ToolCallParsing
import AppKit
import Foundation
import MLXLMCommon

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: Conversation.ID?
    @Published var draft: String = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var streamingMessageID: ChatMessage.ID?
    /// Bumped whenever the visible transcript grows, so the view can auto-scroll.
    @Published private(set) var scrollTick = 0
    @Published var saveError: String?
    /// Attachments staged for the next message (shown as chips above the input).
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var attachmentError: String?
    /// A run_command waiting for the user's Approve / Deny (drives a sheet).
    @Published var pendingCommand: PendingCommand?

    struct PendingCommand: Identifiable {
        let id = UUID()
        let command: String
        let cwdDisplay: String
        let timeout: Double
        fileprivate let continuation: CheckedContinuation<Bool, Never>
    }

    let modelManager: ModelManager
    let serverManager: ServerManager

    private let persistence = ChatPersistence()
    private var generationTask: Task<Void, Never>?
    private var generatingConversationID: Conversation.ID?
    private var terminationObserver: NSObjectProtocol?

    /// Rough character budget for history sent to the model (~6–8k tokens), so long
    /// chats don't blow up the KV cache on an 8 GB machine.
    private let historyCharacterBudget = 24_000

    init(modelManager: ModelManager, serverManager: ServerManager) {
        self.modelManager = modelManager
        self.serverManager = serverManager
        conversations = persistence.load().sorted { $0.updatedAt > $1.updatedAt }
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        selectedID = conversations.first?.id

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.generationTask?.cancel()
                self?.save()
            }
        }
    }

    // MARK: - Derived state

    var selectedConversation: Conversation? {
        guard let selectedID else { return nil }
        return conversations.first { $0.id == selectedID }
    }

    /// The selected backend can take a message right now.
    var backendReady: Bool {
        switch AppSettings.backend {
        case .mlx: return modelManager.isReady
        case .server: return serverManager.isReady
        }
    }

    var canSend: Bool {
        !isGenerating && backendReady
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty)
    }

    /// Warning shown next to the attachment chips when images won't be seen.
    var imageWarning: String? {
        guard pendingAttachments.contains(where: { $0.kind == .image }) else { return nil }
        switch AppSettings.backend {
        case .mlx:
            return "The on-device MLX model is text-only — images will be left out. Switch to a model server with a vision model to send images."
        case .server:
            let model = serverManager.selectedModel
            if model.isEmpty { return nil }
            if !serverManager.supportsVision(model) {
                return "\(model) may not support images (no vision capability detected). It may ignore them or the server may reject the request."
            }
            return nil
        }
    }

    // MARK: - Attachments (only files the user explicitly picks / drops / pastes)

    func addAttachments(urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            guard pendingAttachments.count < AttachmentLoader.maxAttachmentsPerMessage else {
                errors.append("At most \(AttachmentLoader.maxAttachmentsPerMessage) attachments per message.")
                break
            }
            do {
                pendingAttachments.append(try AttachmentLoader.load(url: url))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        attachmentError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func addImage(_ image: NSImage, name: String) {
        guard pendingAttachments.count < AttachmentLoader.maxAttachmentsPerMessage else {
            attachmentError = "At most \(AttachmentLoader.maxAttachmentsPerMessage) attachments per message."
            return
        }
        do {
            pendingAttachments.append(try AttachmentLoader.fromImage(image, name: name))
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    func removeAttachment(_ id: ChatAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
        if pendingAttachments.isEmpty { attachmentError = nil }
    }

    // MARK: - Conversations

    func newChat() {
        if let current = selectedConversation, current.messages.isEmpty { return }
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selectedID = empty.id
            return
        }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        draft = ""
        save()
    }

    func delete(_ id: Conversation.ID) {
        if generatingConversationID == id { stop() }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if selectedID == id || selectedConversation == nil {
            selectedID = conversations.first?.id
        }
        save()
    }

    func clearSelected() {
        guard let id = selectedID, let index = indexOfConversation(id) else { return }
        if generatingConversationID == id { stop() }
        conversations[index].messages.removeAll()
        conversations[index].title = Conversation.defaultTitle
        save()
    }

    // MARK: - Generation

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isGenerating else { return }
        let backend = AppSettings.backend
        var container: ModelContainer?
        switch backend {
        case .mlx:
            guard let c = modelManager.container else { return }
            container = c
        case .server:
            guard serverManager.isReady, serverManager.base != nil else { return }
        }

        if selectedConversation == nil { newChat() }
        guard let conversationID = selectedID, let index = indexOfConversation(conversationID)
        else { return }

        draft = ""
        pendingAttachments = []
        attachmentError = nil

        // Append the user's message and an empty assistant message to stream into.
        let userMessage = ChatMessage(
            role: .user, content: text, attachments: attachments.isEmpty ? nil : attachments)
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        conversations[index].messages.append(userMessage)
        if conversations[index].title == Conversation.defaultTitle {
            conversations[index].title = Self.makeTitle(
                from: text.isEmpty ? (attachments.first?.filename ?? "") : text)
        }
        conversations[index].updatedAt = Date()
        let history = conversations[index].messages  // includes the new user message
        let turnID = userMessage.id.uuidString
        let userAsked = ClaimChecker.userAskedForAction(text)
        conversations[index].messages.append(assistantMessage)
        moveConversationToTop(conversationID)
        save()

        isGenerating = true
        streamingMessageID = assistantMessage.id
        generatingConversationID = conversationID
        scrollTick += 1

        if backend == .server, let base = serverManager.base {
            let messages = serverMessages(for: history, reminderFor: userMessage.id)
            let model = serverManager.selectedModel
            generationTask = Task { [weak self] in
                await self?.runServerTurn(
                    base: base, model: model, messages: messages,
                    conversationID: conversationID, messageID: assistantMessage.id,
                    turnID: turnID, userAsked: userAsked)
            }
            return
        }
        guard let container else { return }

        // Build the model input: system prompt + recent (non-error) history.
        // Tool rows are display-only (like the Python CLI, only user prompts and
        // final replies are kept as history).
        var chat: [Chat.Message] = []
        let systemPrompt = AppSettings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            chat.append(.system(systemPrompt))
        }
        for message in trimmedHistory(history) {
            switch message.role {
            case .user:
                let images = (message.attachments ?? []).filter { $0.kind == .image }
                let note =
                    images.isEmpty
                    ? nil
                    : "[\(images.count) image(s) attached (\(images.map(\.filename).joined(separator: ", "))) — not visible to this text-only on-device model.]"
                var prompt = AttachmentLoader.promptText(
                    message.content, attachments: message.attachments ?? [],
                    imagesNote: note)
                // Re-inject the tool reminder on every turn (latest user message only),
                // so later turns of a long chat keep calling tools.
                if message.id == userMessage.id && AppSettings.toolsEnabled {
                    prompt += "\n\n" + ClaimChecker.toolReminder
                }
                chat.append(.user(prompt))
            case .assistant: chat.append(.assistant(message.content))
            case .tool: break
            }
        }

        var parameters = GenerateParameters()
        parameters.temperature = Float(AppSettings.temperature)
        parameters.topP = 0.95
        parameters.maxTokens = AppSettings.maxTokens
        // Smaller prefill chunks lower peak memory on 8 GB machines.
        parameters.prefill.stepSize = 256

        let tools: [ToolSpec]? = AppSettings.toolsEnabled ? LocalTools.enabledSpecs : nil

        generationTask = Task { [weak self] in
            await self?.runTurn(
                container: container,
                chat: chat,
                tools: tools,
                parameters: parameters,
                conversationID: conversationID,
                messageID: assistantMessage.id,
                turnID: turnID,
                userAsked: userAsked)
        }
    }

    /// Cancel the running generation. Cancelling the consuming task terminates the
    /// AsyncStream, which (in mlx-swift-lm) cancels the underlying token loop.
    func stop() {
        resolvePendingCommand(approved: false)
        generationTask?.cancel()
    }

    /// Result of one model call (one "round").
    private struct RoundResult {
        var text = ""
        var toolCalls: [ToolCall] = []
        /// Raw text of tool-call attempts mlx-swift-lm rejected (malformed JSON etc.).
        var rejectedRaw: [String] = []
        var completion: GenerateCompletionInfo?
        var chunkCount = 0
        var firstChunkAt: Date?
        var failure: Error?
    }

    /// One user turn: generate; if the model requested tools (and tools are on),
    /// run them, append the results as `role: tool` messages and generate again —
    /// up to `LocalTools.maxRounds` rounds. Port of the Python CLI's `_tool_loop`.
    private func runTurn(
        container: ModelContainer,
        chat initialChat: [Chat.Message],
        tools: [ToolSpec]?,
        parameters: GenerateParameters,
        conversationID: Conversation.ID,
        messageID: ChatMessage.ID,
        turnID: String,
        userAsked: Bool
    ) async {
        var chat = initialChat
        var turnReceipts: [ToolReceipt] = []
        var nudges = 0
        var totalChunks = 0
        var totalGenerated = 0
        var totalGenerateSeconds = 0.0
        var lastCompletion: GenerateCompletionInfo?
        var lastRound = RoundResult()
        var exhaustedRounds = false
        let maxRounds = tools == nil ? 1 : LocalTools.maxRounds

        var round = 0
        while round < maxRounds {
            defer { round += 1 }
            lastRound = await generateRound(
                container: container, chat: chat, tools: tools, parameters: parameters,
                conversationID: conversationID, messageID: messageID)

            // Usage totals (per conversation), like the Python CLI's _record_usage.
            if let info = lastRound.completion {
                lastCompletion = info
                totalGenerated += info.generationTokenCount
                totalGenerateSeconds += info.generateTime
                recordUsage(
                    conversationID, prompt: info.promptTokenCount,
                    completion: info.generationTokenCount)
            } else if lastRound.chunkCount > 0 {
                recordUsage(conversationID, prompt: 0, completion: lastRound.chunkCount)
            }
            totalChunks += lastRound.chunkCount

            // Small local models (e.g. Qwen2.5-Coder-7B) often write the call as
            // plain JSON / a ```json block / slightly malformed <tool_call>, which
            // mlx-swift-lm doesn't recognize. Recover those from the text.
            if let tools, lastRound.toolCalls.isEmpty, lastRound.failure == nil, !Task.isCancelled {
                let source = ([lastRound.text] + lastRound.rejectedRaw).joined(separator: "\n")
                let recovered = Self.recoverToolCalls(from: source, tools: tools, round: round)
                if !recovered.calls.isEmpty {
                    lastRound.toolCalls = recovered.calls
                    lastRound.text = recovered.text
                }
            }

            if Task.isCancelled || lastRound.failure != nil || tools == nil
                || lastRound.toolCalls.isEmpty
            {
                // Receipts gate: claims of action with zero receipts this turn are
                // discarded and the model is nudged to actually call the tools.
                if tools != nil, !Task.isCancelled, lastRound.failure == nil,
                    let nudge = nudgeMessage(
                        lastRound.text, receipts: turnReceipts, userAsked: userAsked,
                        nudges: nudges, roomLeft: round < maxRounds - 1)
                {
                    nudges += 1
                    chat.append(.user(nudge))
                    updateMessage(conversationID, messageID) { $0.content = "" }
                    scrollTick += 1
                    continue
                }
                break
            }

            // The model asked for tools: record its request, run each call, feed back.
            chat.append(.assistant(lastRound.text, toolCalls: lastRound.toolCalls))
            for call in lastRound.toolCalls {
                let (result, receipt) = await runAndRecord(
                    call, conversationID: conversationID, messageID: messageID, turnID: turnID)
                turnReceipts.append(receipt)
                chat.append(.tool(result, id: call.id, name: call.function.name))
            }
            // Clear the streamed pre-tool text; the next round streams the answer.
            updateMessage(conversationID, messageID) { $0.content = "" }
            scrollTick += 1

            if round == maxRounds - 1 { exhaustedRounds = true }
        }

        let stopped = Task.isCancelled

        // Tokens/sec over the whole turn (all rounds).
        let stats: GenerationStats?
        if let lastCompletion, !stopped || totalGenerated > 0 {
            let tps =
                totalGenerateSeconds > 0
                ? Double(totalGenerated) / totalGenerateSeconds : lastCompletion.tokensPerSecond
            stats = GenerationStats(
                generatedTokens: totalGenerated,
                tokensPerSecond: tps,
                promptTokens: lastCompletion.promptTokenCount,
                promptSeconds: lastCompletion.promptTime,
                stopped: stopped)
        } else if let firstChunkAt = lastRound.firstChunkAt, totalChunks > 0 {
            // Stopped early: the library's summary isn't delivered, so estimate
            // from streamed chunks (≈ one chunk per token).
            let elapsed = Swift.max(Date().timeIntervalSince(firstChunkAt), 0.001)
            stats = GenerationStats(
                generatedTokens: totalChunks,
                tokensPerSecond: Double(lastRound.chunkCount) / elapsed,
                promptTokens: nil, promptSeconds: nil,
                stopped: stopped)
        } else {
            stats = nil
        }

        let rawFinal = Self.cleaned(lastRound.text)
        let finalText = Self.finalDisplay(rawFinal)
        let failure = lastRound.failure
        let unverified = failure == nil ? Self.unverifiedClaims(rawFinal, receipts: turnReceipts) : nil
        updateMessage(conversationID, messageID) { message in
            message.unverifiedClaims = unverified
            if let failure, finalText.isEmpty {
                message.content = "Generation failed: \(failure.localizedDescription)"
                message.isError = true
            } else if exhaustedRounds && !lastRound.toolCalls.isEmpty {
                message.content =
                    "(stopped after \(LocalTools.maxRounds) tool rounds without a final answer)"
                message.stats = stats
            } else if finalText.isEmpty {
                message.content = stopped ? "(stopped)" : "(no output)"
                message.stats = stats
            } else {
                message.content = finalText
                message.stats = stats
            }
        }
        if let index = indexOfConversation(conversationID) {
            conversations[index].updatedAt = Date()
        }

        isGenerating = false
        streamingMessageID = nil
        generatingConversationID = nil
        generationTask = nil
        scrollTick += 1
        save()
    }

    /// Run the model once over `chat`, streaming text into the assistant message.
    private func generateRound(
        container: ModelContainer,
        chat: [Chat.Message],
        tools: [ToolSpec]?,
        parameters: GenerateParameters,
        conversationID: Conversation.ID,
        messageID: ChatMessage.ID
    ) async -> RoundResult {
        // `tools` goes into the prompt (rendered by the chat template) AND into
        // generate(), where mlx-swift-lm uses it to parse/authorize tool calls.
        let userInput = UserInput(chat: chat, tools: tools)
        var result = RoundResult()
        var lastFlush = Date.distantPast

        do {
            // Prepare (apply the tokenizer's chat template) and start streaming inside
            // the container's isolation, as recommended by mlx-swift-lm.
            let stream: AsyncStream<Generation> = try await container.perform(
                nonSendable: userInput
            ) { (context: ModelContext, input: UserInput) async throws -> AsyncStream<Generation> in
                let lmInput = try await context.processor.prepare(input: input)
                return try MLXLMCommon.generate(
                    input: lmInput, parameters: parameters, context: context, tools: tools)
            }

            for await event in stream {
                switch event {
                case .chunk(let text):
                    if result.firstChunkAt == nil { result.firstChunkAt = Date() }
                    result.chunkCount += 1
                    result.text += text
                    // Throttle UI updates (~20 fps) — each update re-renders markdown.
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) > 0.05 {
                        lastFlush = now
                        let display = Self.cleaned(result.text)
                        updateMessage(conversationID, messageID) { $0.content = display }
                        scrollTick += 1
                    }
                case .info(let info):
                    result.completion = info
                case .toolCall(let call):
                    result.toolCalls.append(call)
                case .rejectedToolCall(let rejection):
                    // Malformed / undeclared call: keep the raw text for the fallback parser.
                    result.rejectedRaw.append(rejection.rawTextPreview)
                default:
                    break
                }
            }
        } catch {
            result.failure = error
        }
        return result
    }

    // MARK: - Model server backend (OpenAI-compatible /v1/chat/completions)

    /// Max images sent per request (most recent first) to bound payload size.
    private let maxImagesPerRequest = 4

    /// OpenAI-format messages: system + trimmed history; user turns with images
    /// become content-part arrays (`text` + `image_url` data URIs).
    private func serverMessages(for history: [ChatMessage], reminderFor reminderID: ChatMessage.ID?)
        -> [[String: Any]]
    {
        var out: [[String: Any]] = []
        let systemPrompt = AppSettings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty { out.append(["role": "system", "content": systemPrompt]) }
        let trimmed = trimmedHistory(history)
        var imageBudget = maxImagesPerRequest
        var built: [[String: Any]] = []
        for message in trimmed.reversed() {
            switch message.role {
            case .assistant:
                built.append(["role": "assistant", "content": message.content])
            case .user:
                let attachments = message.attachments ?? []
                let images = attachments.filter { $0.kind == .image }
                var sendable: [ChatAttachment] = []
                for image in images.reversed() where imageBudget > 0 {
                    sendable.insert(image, at: 0)
                    imageBudget -= 1
                }
                let dropped = images.count - sendable.count
                let note =
                    dropped > 0
                    ? "[\(dropped) earlier image(s) omitted to keep the request small.]" : nil
                var text = AttachmentLoader.promptText(
                    message.content, attachments: attachments, imagesNote: note)
                if message.id == reminderID && AppSettings.toolsEnabled {
                    text += "\n\n" + ClaimChecker.toolReminder
                }
                if sendable.isEmpty {
                    built.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    for image in sendable {
                        if let uri = image.dataURI {
                            parts.append(["type": "image_url", "image_url": ["url": uri]])
                        }
                    }
                    built.append(["role": "user", "content": parts])
                }
            case .tool:
                break
            }
        }
        out.append(contentsOf: built.reversed())
        return out
    }

    /// OpenAI-style tool schemas (same tools as the MLX path).
    private static var serverToolSpecs: [[String: Any]] {
        LocalTools.enabledSpecs.map { $0 as [String: Any] }
    }

    private struct PartialToolCall {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private func runServerTurn(
        base: URL, model: String, messages initialMessages: [[String: Any]],
        conversationID: Conversation.ID, messageID: ChatMessage.ID,
        turnID: String, userAsked: Bool
    ) async {
        var messages = initialMessages
        var turnReceipts: [ToolReceipt] = []
        var nudges = 0
        var useTools = AppSettings.toolsEnabled
        var useStreamOptions = true
        let maxRounds = useTools ? LocalTools.maxRounds : 1
        var text = ""
        var failure: Error?
        var exhaustedRounds = false
        var pendingCalls: [Int: PartialToolCall] = [:]
        var totalCompletion = 0
        var lastPrompt: Int?
        var promptSeconds: Double?
        var generatingSeconds = 0.0
        var round = 0
        var retries = 0

        while round < maxRounds {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": true,
                "temperature": AppSettings.temperature,
                "top_p": 0.95,
                "max_tokens": AppSettings.maxTokens,
            ]
            if useStreamOptions { body["stream_options"] = ["include_usage": true] }
            if useTools { body["tools"] = Self.serverToolSpecs }

            text = ""
            pendingCalls = [:]
            failure = nil
            var chunks = 0
            var usage: (Int, Int)?
            let start = Date()
            var firstChunkAt: Date?
            var lastFlush = Date.distantPast

            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                for try await event in ServerAPI.streamChat(base: base, body: data) {
                    if Task.isCancelled { break }
                    switch event {
                    case .content(let piece):
                        if firstChunkAt == nil { firstChunkAt = Date() }
                        chunks += 1
                        text += piece
                        let now = Date()
                        if now.timeIntervalSince(lastFlush) > 0.05 {
                            lastFlush = now
                            let display = Self.cleaned(text)
                            updateMessage(conversationID, messageID) { $0.content = display }
                            scrollTick += 1
                        }
                    case .toolCallDelta(let index, let id, let name, let args):
                        if firstChunkAt == nil { firstChunkAt = Date() }
                        var call = pendingCalls[index] ?? PartialToolCall()
                        if let id, !id.isEmpty { call.id = id }
                        if let name, !name.isEmpty { call.name += name }
                        if let args { call.arguments += args }
                        pendingCalls[index] = call
                    case .usage(let p, let c):
                        usage = (p, c)
                    }
                }
            } catch {
                if !(error is CancellationError) { failure = error }
            }

            // Some servers reject stream_options or tools for certain models: retry once without.
            if case ServerError.http(let code, let msg)? = failure as? ServerError,
                code == 400 || code == 422, retries < 2, text.isEmpty
            {
                let lower = msg.lowercased()
                if useTools && lower.contains("tool") {
                    useTools = false
                    retries += 1
                    continue
                }
                if useStreamOptions {
                    useStreamOptions = false
                    retries += 1
                    continue
                }
            }

            let end = Date()
            if let firstChunkAt {
                if promptSeconds == nil { promptSeconds = firstChunkAt.timeIntervalSince(start) }
                generatingSeconds += end.timeIntervalSince(firstChunkAt)
            }
            let completion = usage?.1 ?? chunks
            totalCompletion += completion
            if let usage { lastPrompt = usage.0 }
            recordUsage(conversationID, prompt: usage?.0 ?? 0, completion: completion)

            if useTools, pendingCalls.isEmpty, failure == nil, !Task.isCancelled {
                let names = Set(LocalTools.enabledSpecs.compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String })
                let parsed = ToolCallTextParser.parse(text, allowedNames: names)
                for (i, c) in parsed.calls.enumerated() {
                    var p = PartialToolCall()
                    p.id = "call_text_\(round)_\(i)"
                    p.name = c.name
                    p.arguments = c.argumentsJSON
                    pendingCalls[i] = p
                }
                if !parsed.calls.isEmpty { text = parsed.remainingText }
            }
            if Task.isCancelled || failure != nil || !useTools || pendingCalls.isEmpty {
                if useTools, !Task.isCancelled, failure == nil,
                    let nudge = nudgeMessage(
                        text, receipts: turnReceipts, userAsked: userAsked,
                        nudges: nudges, roomLeft: round < maxRounds - 1)
                {
                    nudges += 1
                    messages.append(["role": "user", "content": nudge])
                    updateMessage(conversationID, messageID) { $0.content = "" }
                    scrollTick += 1
                    round += 1
                    continue
                }
                break
            }

            // Run requested tools and feed the results back.
            let ordered = pendingCalls.sorted { $0.key < $1.key }.map(\.value)
            var callsJSON: [[String: Any]] = []
            var runnable: [(String, ToolCall)] = []
            for (i, partial) in ordered.enumerated() {
                let callID = partial.id ?? "call_\(round)_\(i)"
                let args =
                    (try? JSONDecoder().decode(
                        [String: JSONValue].self,
                        from: Data((partial.arguments.isEmpty ? "{}" : partial.arguments).utf8)))
                    ?? [:]
                callsJSON.append([
                    "id": callID, "type": "function",
                    "function": ["name": partial.name, "arguments": partial.arguments.isEmpty ? "{}" : partial.arguments],
                ])
                runnable.append(
                    (callID, ToolCall(function: .init(name: partial.name, arguments: args), id: callID)))
            }
            messages.append([
                "role": "assistant", "content": text.isEmpty ? (NSNull() as Any) : (text as Any),
                "tool_calls": callsJSON,
            ])
            for (callID, call) in runnable {
                let (result, receipt) = await runAndRecord(
                    call, conversationID: conversationID, messageID: messageID, turnID: turnID)
                turnReceipts.append(receipt)
                messages.append(["role": "tool", "tool_call_id": callID, "content": result])
            }
            updateMessage(conversationID, messageID) { $0.content = "" }
            scrollTick += 1
            round += 1
            if round == maxRounds { exhaustedRounds = true }
        }

        let stopped = Task.isCancelled
        let stats: GenerationStats? =
            totalCompletion > 0
            ? GenerationStats(
                generatedTokens: totalCompletion,
                tokensPerSecond: Double(totalCompletion) / Swift.max(generatingSeconds, 0.001),
                promptTokens: lastPrompt,
                promptSeconds: lastPrompt == nil ? nil : promptSeconds,
                stopped: stopped)
            : nil

        let rawFinal = Self.cleaned(text)
        let finalText = Self.finalDisplay(rawFinal)
        let unverified = failure == nil ? Self.unverifiedClaims(rawFinal, receipts: turnReceipts) : nil
        updateMessage(conversationID, messageID) { message in
            message.unverifiedClaims = unverified
            if let failure, finalText.isEmpty {
                message.content = "Request to \(model) failed: \(failure.localizedDescription)"
                message.isError = true
            } else if exhaustedRounds {
                message.content =
                    "(stopped after \(LocalTools.maxRounds) tool rounds without a final answer)"
                message.stats = stats
            } else if finalText.isEmpty {
                message.content = stopped ? "(stopped)" : "(no output)"
                message.stats = stats
            } else {
                message.content = finalText
                message.stats = stats
            }
        }
        if failure != nil, case ServerError.offline? = failure as? ServerError {
            Task { await serverManager.refresh() }
        }
        if let index = indexOfConversation(conversationID) {
            conversations[index].updatedAt = Date()
        }
        isGenerating = false
        streamingMessageID = nil
        generatingConversationID = nil
        generationTask = nil
        scrollTick += 1
        save()
    }

    // MARK: - Receipts (shared by both backends)

    /// Discarded-reply nudges per turn before the reply is shown with a badge.
    static let maxNudges = 2

    private var receiptsURL: URL {
        persistence.directoryURL.appendingPathComponent("receipts.jsonl", isDirectory: false)
    }

    /// Execute one call, write its receipt (JSONL + tool row), return the result text.
    private func runAndRecord(
        _ call: ToolCall, conversationID: Conversation.ID, messageID: ChatMessage.ID,
        turnID: String
    ) async -> (String, ToolReceipt) {
        let result = await executeTool(call, conversationID: conversationID)
        var args: [String: String] = [:]
        for (key, value) in call.function.arguments {
            args[key] = LocalTools.stringArg(value) ?? "null"
        }
        let receipt = ToolReceipt(turn: turnID, tool: call.function.name, args: args, output: result)
        do {
            try ReceiptLog.append(receipt, to: receiptsURL)
        } catch {
            NSLog("LocalAI: could not append receipt: \(error)")
        }
        insertToolRow(
            conversationID, before: messageID,
            summary: LocalTools.describe(call), result: result, receipt: receipt)
        return (result, receipt)
    }

    static let snippetNudge =
        "Your last reply was a tool call written as text, so it was NOT executed and nothing ran. Reply with only <tool_call>{\"name\": \"...\", \"arguments\": {...}}</tool_call>."

    static let snippetNotice =
        "Not executed: the reply below is a tool call the app could not run, so nothing ran."

    private static var enabledToolNames: Set<String> {
        Set(LocalTools.enabledSpecs.compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String })
    }

    /// The text to send back instead of accepting this reply, or nil to accept it:
    /// an unexecuted tool-call snippet, or action claims with zero receipts this
    /// turn when the user asked for an action.
    private func nudgeMessage(
        _ text: String, receipts: [ToolReceipt], userAsked: Bool, nudges: Int, roomLeft: Bool
    ) -> String? {
        guard nudges < Self.maxNudges, roomLeft else { return nil }
        if ToolCallTextParser.isOnlyToolSnippet(text, allowedNames: Self.enabledToolNames) {
            return Self.snippetNudge
        }
        guard receipts.isEmpty, userAsked,
            !ClaimChecker.unsupported(in: text, receipts: receipts).isEmpty
        else { return nil }
        return ClaimChecker.nudge
    }

    private static func unverifiedClaims(_ text: String, receipts: [ToolReceipt]) -> [String]? {
        var out = ClaimChecker.unsupported(in: text, receipts: receipts).map(\.summary)
        if ToolCallTextParser.isOnlyToolSnippet(text, allowedNames: enabledToolNames) {
            out.insert("reply is a tool call that was not executed", at: 0)
        }
        return out.isEmpty ? nil : out
    }

    /// A tool-call snippet is never shown as a plain final answer.
    private static func finalDisplay(_ text: String) -> String {
        guard ToolCallTextParser.isOnlyToolSnippet(text, allowedNames: enabledToolNames) else { return text }
        return snippetNotice + "\n\n" + text
    }

    // MARK: - Tool execution (shared by both backends)

    private func executeTool(_ call: ToolCall, conversationID: Conversation.ID) async -> String {
        if call.function.name == "run_command" {
            return await runCommandTool(call)
        }
        return await Task.detached(priority: .userInitiated) { LocalTools.run(call) }.value
    }

    /// Never auto-approves: every command waits for the Approve / Deny sheet.
    private func runCommandTool(_ call: ToolCall) async -> String {
        guard AppSettings.runCommandEnabled else {
            return "error: run_command is disabled in Settings"
        }
        let args = call.function.arguments
        guard let command = LocalTools.stringArg(args["command"]),
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "error: run_command() missing required argument: 'command'" }
        let cwd: URL
        do {
            cwd = try WorkspaceSandbox.resolve(LocalTools.stringArg(args["cwd"]) ?? "", allowRoot: true)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir) || !isDir.boolValue {
                return "error: cwd '\(WorkspaceSandbox.relative(cwd))' is not an existing folder in the workspace"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
        if Task.isCancelled { return "error: cancelled" }
        let timeout = AppSettings.commandTimeout
        let display = "~/LocalAI-Workspace" + (WorkspaceSandbox.relative(cwd) == "." ? "" : "/" + WorkspaceSandbox.relative(cwd))
        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            resolvePendingCommand(approved: false)
            pendingCommand = PendingCommand(
                command: command, cwdDisplay: display, timeout: timeout, continuation: c)
        }
        guard approved, !Task.isCancelled else {
            return "error: the user denied running this command"
        }
        let result = await CommandRunner.run(command, cwd: cwd, timeout: timeout)
        return "$ \(command)\n(cwd: \(display))\n" + result.report
    }

    func resolvePendingCommand(approved: Bool) {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        pending.continuation.resume(returning: approved)
    }

    private func recordUsage(_ conversationID: Conversation.ID, prompt: Int, completion: Int) {
        guard let index = indexOfConversation(conversationID) else { return }
        conversations[index].usage.record(prompt: prompt, completion: completion)
    }

    private func insertToolRow(
        _ conversationID: Conversation.ID, before messageID: ChatMessage.ID,
        summary: String, result: String, receipt: ToolReceipt? = nil
    ) {
        guard let c = indexOfConversation(conversationID) else { return }
        let row = ChatMessage(
            role: .tool, content: result,
            isError: receipt.map { !$0.ok } ?? result.hasPrefix("error:"), toolCallSummary: summary,
            receipt: receipt)
        if let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }) {
            conversations[c].messages.insert(row, at: m)
        } else {
            conversations[c].messages.append(row)
        }
    }

    // MARK: - Helpers

    /// Keep the most recent messages that fit the character budget (always keeping
    /// the latest user message). Error placeholders are never sent to the model.
    private func trimmedHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        let usable = messages.filter {
            $0.role != .tool && !$0.isError
                && (!$0.content.isEmpty || !($0.attachments ?? []).isEmpty)
        }
        var result: [ChatMessage] = []
        var total = 0
        for message in usable.reversed() {
            total += message.content.count
                + (message.attachments ?? []).reduce(0) { $0 + ($1.text?.count ?? 0) }
            if total > historyCharacterBudget && !result.isEmpty { break }
            result.append(message)
        }
        result.reverse()
        // Chat templates expect the conversation to start with a user turn.
        while let first = result.first, first.role != .user {
            result.removeFirst()
        }
        return result
    }

    private func indexOfConversation(_ id: Conversation.ID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    private func updateMessage(
        _ conversationID: Conversation.ID, _ messageID: ChatMessage.ID,
        _ mutate: (inout ChatMessage) -> Void
    ) {
        guard let c = indexOfConversation(conversationID),
            let m = conversations[c].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        mutate(&conversations[c].messages[m])
    }

    private func moveConversationToTop(_ id: Conversation.ID) {
        guard let index = indexOfConversation(id), index != 0 else { return }
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
    }

    /// Text-format tool calls -> `ToolCall`s, restricted to the declared tools.
    static func recoverToolCalls(from text: String, tools: [ToolSpec], round: Int)
        -> (calls: [ToolCall], text: String)
    {
        let names = Set(tools.compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String })
        let parsed = ToolCallTextParser.parse(text, allowedNames: names)
        let calls = parsed.calls.enumerated().map { (i, c) -> ToolCall in
            let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(c.argumentsJSON.utf8))) ?? [:]
            return ToolCall(function: .init(name: c.name, arguments: args), id: "call_text_\(round)_\(i)")
        }
        return (calls, parsed.remainingText)
    }

    private static func cleaned(_ text: String) -> String {
        String(text.drop(while: { $0.isWhitespace }))
    }

    private static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 48 { return trimmed.isEmpty ? Conversation.defaultTitle : trimmed }
        return String(trimmed.prefix(48)) + "…"
    }

    func save() {
        do {
            try persistence.save(conversations)
            saveError = nil
        } catch {
            saveError = "Could not save chats: \(error.localizedDescription)"
            NSLog("LocalAI: \(saveError ?? "")")
        }
    }

    var chatsFilePath: String { persistence.fileURL.path }
}
