import Foundation

/// UserDefaults keys shared by `@AppStorage` in views and by the view models.
enum SettingsKey {
    static let modelPath = "modelPath"
    static let systemPrompt = "systemPrompt"
    static let temperature = "temperature"
    static let maxTokens = "maxTokens"
    static let toolsEnabled = "toolsEnabled"
    static let backend = "backend"
    static let writeFileEnabled = "writeFileEnabled"
    static let runCommandEnabled = "runCommandEnabled"
    static let commandTimeout = "commandTimeout"
    static let serverURL = "serverURL"
    static let serverAPIKind = "serverAPIKind"
    static let serverModel = "serverModel"
}

/// Where replies come from: the original on-device MLX engine, or a local
/// OpenAI-compatible / Ollama model server.
enum ChatBackend: String, CaseIterable, Identifiable {
    case mlx
    case server

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mlx: return "On-device (MLX)"
        case .server: return "Model server"
        }
    }
}

enum AppSettings {
    static let defaultModelPath =
        "~/.lmstudio/models/lmstudio-community/Qwen2.5-Coder-7B-Instruct-MLX-4bit"

    /// Used when the user hasn't saved their own prompt (editable in Settings).
    static let defaultSystemPrompt = """
        You are ALEXUS, a local agent running on the owner's Mac. You are not a chatbot: you act by calling tools, not by describing steps.

        Workspace: ~/LocalAI-Workspace. Only write files there.

        Tools:
        - list_dir(path): see what files exist.
        - read_file(path): read a file before changing it.
        - write_file(path, content): create or overwrite a file. Always write the full file.
        - run_command(command): run a shell command (zsh). Use python3 for Python.

        How to work:
        1. If the task involves existing files, list_dir and read_file first.
        2. Write the script with write_file.
        3. Run it with run_command.
        4. Read the output. If there is an error, fix the file and run again. Stop after 3 failed tries and explain what's wrong.
        5. When it works, reply with a short summary: what you made, where it is, and the result.

        Rules:
        - Never guess file contents; read them.
        - Never say you wrote, ran, listed, or read anything unless a tool result in this chat shows it. Never invent file contents or command output.
        - Keep scripts small and simple.
        - If something is unknown (a path, a value, what the user wants), say UNKNOWN and ask instead of making it up.
        - Be direct and brief. No "as an AI" talk.

        To call a tool, reply with only: <tool_call>{"name": "write_file", "arguments": {"path": "count.py", "content": "..."}}</tool_call>
        """

    /// The ALEXUS default before the receipts rule; a stored copy is upgraded.
    static let previousDefaultSystemPrompt = """
        You are ALEXUS, a local agent running on the owner's Mac. You are not a chatbot: you act by calling tools, not by describing steps.

        Workspace: ~/LocalAI-Workspace. Only write files there.

        Tools:
        - list_dir(path): see what files exist.
        - read_file(path): read a file before changing it.
        - write_file(path, content): create or overwrite a file. Always write the full file.
        - run_command(command): run a shell command (zsh). Use python3 for Python.

        How to work:
        1. If the task involves existing files, list_dir and read_file first.
        2. Write the script with write_file.
        3. Run it with run_command.
        4. Read the output. If there is an error, fix the file and run again. Stop after 3 failed tries and explain what's wrong.
        5. When it works, reply with a short summary: what you made, where it is, and the result.

        Rules:
        - Never guess file contents; read them.
        - Keep scripts small and simple.
        - If something is unknown (a path, a value, what the user wants), say UNKNOWN and ask instead of making it up.
        - Be direct and brief. No "as an AI" talk.

        To call a tool, reply with only: <tool_call>{"name": "write_file", "arguments": {"path": "count.py", "content": "..."}}</tool_call>
        """

    /// The previous built-in default; a stored copy of it is upgraded to the new default.
    static let legacyDefaultSystemPrompt = """
        You are LocalAI, a helpful coding assistant running entirely on the user's Mac. \
        Answer clearly and concisely. When you write code, put it in fenced Markdown code \
        blocks with the language name (for example ```swift). Prefer correct, idiomatic, \
        working code and briefly explain non-obvious parts.
        """

    static let defaultTemperature: Double = 0.7
    static let defaultMaxTokens: Int = 2048
    /// Tool calling (get_time / list_dir / read_file) is opt-in.
    static let defaultToolsEnabled = false
    static let defaultBackend = ChatBackend.mlx.rawValue
    /// LM Studio's default. Ollama is http://127.0.0.1:11434.
    static let defaultServerURL = "http://127.0.0.1:1234"
    static let defaultServerAPIKind = ServerAPIKind.auto.rawValue

    /// Register defaults so `UserDefaults` reads match the `@AppStorage` defaults
    /// even before the user has opened Settings.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.modelPath: defaultModelPath,
            SettingsKey.systemPrompt: defaultSystemPrompt,
            SettingsKey.temperature: defaultTemperature,
            SettingsKey.maxTokens: defaultMaxTokens,
            SettingsKey.toolsEnabled: defaultToolsEnabled,
            SettingsKey.backend: defaultBackend,
            SettingsKey.writeFileEnabled: true,
            SettingsKey.runCommandEnabled: false,
            SettingsKey.commandTimeout: 60.0,
            SettingsKey.serverURL: defaultServerURL,
            SettingsKey.serverAPIKind: defaultServerAPIKind,
            SettingsKey.serverModel: "",
        ])
        upgradeStoredSystemPrompt()
    }

    /// A saved prompt that is just an earlier built-in default (not user-edited).
    static func isOldDefault(_ prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == legacyDefaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            || t == previousDefaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace a stored prompt only if it equals a previous default (so Settings shows the new one).
    static func upgradeStoredSystemPrompt() {
        guard let stored = UserDefaults.standard.string(forKey: SettingsKey.systemPrompt),
            isOldDefault(stored)
        else { return }
        UserDefaults.standard.set(defaultSystemPrompt, forKey: SettingsKey.systemPrompt)
    }

    static var modelPath: String {
        UserDefaults.standard.string(forKey: SettingsKey.modelPath) ?? defaultModelPath
    }

    /// Custom prompt if the user saved one; otherwise (unset, blank, or the old
    /// built-in default) the ALEXUS default.
    static var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.systemPrompt) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isOldDefault(trimmed) { return defaultSystemPrompt }
        return stored
    }

    static var temperature: Double {
        let value = UserDefaults.standard.double(forKey: SettingsKey.temperature)
        return value.isFinite ? Swift.min(Swift.max(value, 0), 2) : defaultTemperature
    }

    static var maxTokens: Int {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.maxTokens)
        return value > 0 ? value : defaultMaxTokens
    }

    static var toolsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.toolsEnabled)
    }

    static var writeFileEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.writeFileEnabled) }
    static var runCommandEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.runCommandEnabled) }
    static var commandTimeout: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKey.commandTimeout)
        return v >= 1 ? Swift.min(v, 3600) : 60
    }

    static var backend: ChatBackend {
        ChatBackend(rawValue: UserDefaults.standard.string(forKey: SettingsKey.backend) ?? "")
            ?? .mlx
    }

    static var serverURL: String {
        UserDefaults.standard.string(forKey: SettingsKey.serverURL) ?? defaultServerURL
    }

    static var serverAPIKind: ServerAPIKind {
        ServerAPIKind(
            rawValue: UserDefaults.standard.string(forKey: SettingsKey.serverAPIKind) ?? "")
            ?? .auto
    }

    static var serverModel: String {
        get { UserDefaults.standard.string(forKey: SettingsKey.serverModel) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.serverModel) }
    }

    /// Expand `~`, `$HOME` and relative bits into an absolute file URL.
    ///
    /// The app is intentionally NOT sandboxed, so `NSHomeDirectory()` /
    /// `expandingTildeInPath` resolve to the real `/Users/<name>` home and
    /// `~/.lmstudio/...` points at the actual LM Studio model folder.
    static func resolvedURL(forPath rawPath: String) -> URL {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow pasting a file:// URL.
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("$HOME") {
            path = home + path.dropFirst("$HOME".count)
        }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (home as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Inverse of `resolvedURL`: show paths under the home folder as `~/...`.
    static func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
