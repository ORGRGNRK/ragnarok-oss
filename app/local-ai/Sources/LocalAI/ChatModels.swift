import Foundation
import ToolCallParsing

struct GenerationStats: Codable, Equatable {
    var generatedTokens: Int
    var tokensPerSecond: Double
    var promptTokens: Int?
    var promptSeconds: Double?
    var stopped: Bool

    var summary: String {
        var parts: [String] = []
        parts.append("\(generatedTokens) tokens")
        parts.append(String(format: "%.1f tok/s", tokensPerSecond))
        if let promptTokens, let promptSeconds, promptSeconds > 0 {
            parts.append(String(format: "prompt %d tok in %.2fs", promptTokens, promptSeconds))
        }
        if stopped { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        /// A tool call + its result, shown as a collapsible row. Display-only:
        /// like the Python CLI, only user prompts and final replies are sent
        /// back to the model as history.
        case tool
    }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var stats: GenerationStats?
    var isError: Bool
    /// For `.tool` rows: `name(arg: value)` of the call; `content` holds the result.
    var toolCallSummary: String?
    /// Files / images the user attached (user messages only).
    var attachments: [ChatAttachment]?
    /// For `.tool` rows: the app-written receipt of this executed call.
    var receipt: ToolReceipt?
    /// For assistant replies: action claims with no receipt in the same turn.
    var unverifiedClaims: [String]?

    init(
        id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date(),
        stats: GenerationStats? = nil, isError: Bool = false, toolCallSummary: String? = nil,
        attachments: [ChatAttachment]? = nil, receipt: ToolReceipt? = nil,
        unverifiedClaims: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.stats = stats
        self.isError = isError
        self.toolCallSummary = toolCallSummary
        self.attachments = attachments
        self.receipt = receipt
        self.unverifiedClaims = unverifiedClaims
    }

    // Tolerant decoding so older / hand-edited files still load.
    enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, stats, isError, toolCallSummary, attachments
        case receipt, unverifiedClaims
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        stats = try c.decodeIfPresent(GenerationStats.self, forKey: .stats)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        toolCallSummary = try c.decodeIfPresent(String.self, forKey: .toolCallSummary)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments)
        receipt = try? c.decodeIfPresent(ToolReceipt.self, forKey: .receipt)
        unverifiedClaims = try c.decodeIfPresent([String].self, forKey: .unverifiedClaims)
    }
}

/// Per-conversation token usage (port of the Python CLI's usage_totals).
/// Local inference costs nothing, so there is no cost column.
struct UsageTotals: Codable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0

    var totalTokens: Int { promptTokens + completionTokens }

    mutating func record(prompt: Int, completion: Int) {
        promptTokens += prompt
        completionTokens += completion
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    static let defaultTitle = "New Chat"

    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var usage: UsageTotals

    init(
        id: UUID = UUID(), title: String = Conversation.defaultTitle, createdAt: Date = Date(),
        updatedAt: Date = Date(), messages: [ChatMessage] = [], usage: UsageTotals = UsageTotals()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Conversation.defaultTitle
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        usage = try c.decodeIfPresent(UsageTotals.self, forKey: .usage) ?? UsageTotals()
    }
}

/// On-disk format of ~/Library/Application Support/LocalAI/chats.json
struct ChatArchive: Codable {
    var version: Int
    var conversations: [Conversation]
}

struct ChatPersistence {
    let directoryURL: URL
    let fileURL: URL

    init() {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        directoryURL = base.appendingPathComponent("LocalAI", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("chats.json", isDirectory: false)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try makeDecoder().decode(ChatArchive.self, from: data).conversations
        } catch {
            // Keep the unreadable file around instead of silently overwriting it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directoryURL.appendingPathComponent("chats.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("LocalAI: could not read chats.json (\(error)); moved to \(backup.path)")
            return []
        }
    }

    func save(_ conversations: [Conversation]) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        let data = try makeEncoder().encode(ChatArchive(version: 1, conversations: conversations))
        try data.write(to: fileURL, options: .atomic)
    }
}
