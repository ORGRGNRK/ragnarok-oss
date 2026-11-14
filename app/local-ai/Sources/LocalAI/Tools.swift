import Foundation
import MLXLMCommon

/// Port of the tool set from the Python CLI (get_time, list_dir, read_file).
///
/// The model never runs anything itself: mlx-swift-lm parses Qwen2.5's
/// `<tool_call>{json}</tool_call>` output into `Generation.toolCall(ToolCall)`
/// events, we run the matching function here, feed the result back as a
/// `role: "tool"` message, and generate again until the model answers in
/// plain text (max `maxRounds` rounds).
enum LocalTools {
    static let maxRounds = 8
    static let maxFileChars = 20_000
    static let maxDirEntries = 200

    /// OpenAI-style function schemas, rendered into the prompt by the model's
    /// chat template and used by mlx-swift-lm to authorize/parse tool calls.
    static let specs: [ToolSpec] = [
        [
            "type": "function",
            "function": [
                "name": "get_time",
                "description": "Get the current local date and time.",
                "parameters": [
                    "type": "object",
                    "properties": [String: any Sendable](),
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        [
            "type": "function",
            "function": [
                "name": "list_dir",
                "description":
                    "List files and folders in a directory. Folders end with '/'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description":
                                "Directory path. Relative paths are inside ~/LocalAI-Workspace; ~ and absolute paths are allowed. Default: the workspace.",
                        ] as [String: any Sendable]
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        [
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read a text file (first \(maxFileChars) characters).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path. Relative paths are inside ~/LocalAI-Workspace; ~ and absolute paths are allowed.",
                        ] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": ["path"] as [any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
    ]

    static let writeFileSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "write_file",
            "description":
                "Create or overwrite a UTF-8 text file inside the workspace folder ~/LocalAI-Workspace. The path must be relative to that folder (no absolute paths, no '..'). Parent folders are created. To read or list workspace files, use read_file / list_dir with paths like '~/LocalAI-Workspace/...'.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path relative to ~/LocalAI-Workspace, e.g. 'notes/todo.md'.",
                    ] as [String: any Sendable],
                    "content": [
                        "type": "string", "description": "Full file contents.",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["path", "content"] as [any Sendable],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    static let runCommandSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "run_command",
            "description":
                "Run a shell command with zsh in the workspace folder ~/LocalAI-Workspace. The user must approve every command first and may deny it. Returns exit code, stdout and stderr. Commands time out.",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string", "description": "The shell command line to run.",
                    ] as [String: any Sendable],
                    "cwd": [
                        "type": "string",
                        "description": "Optional working folder relative to ~/LocalAI-Workspace (default: the workspace root).",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["command"] as [any Sendable],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// Tool list for the current settings.
    static var enabledSpecs: [ToolSpec] {
        var list = specs
        if AppSettings.writeFileEnabled { list.append(writeFileSpec) }
        if AppSettings.runCommandEnabled { list.append(runCommandSpec) }
        return list
    }

    /// Human-readable `name(arg: value, …)` used in the transcript.
    static func describe(_ call: ToolCall) -> String {
        if call.function.name == "write_file" {
            let path = stringArg(call.function.arguments["path"]) ?? "?"
            let n = stringArg(call.function.arguments["content"])?.count ?? 0
            return "write_file(path: \"\(path)\", content: \(n) chars)"
        }
        let args = call.function.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(render($0.value))" }
            .joined(separator: ", ")
        return "\(call.function.name)(\(args))"
    }

    /// Run a tool. Errors are returned as text so the model can recover,
    /// exactly like the Python `_run_tool`.
    static func run(_ call: ToolCall) -> String {
        let args = call.function.arguments
        do {
            switch call.function.name {
            case "write_file":
                guard AppSettings.writeFileEnabled else {
                    return "error: write_file is disabled in Settings"
                }
                guard let path = stringArg(args["path"]) else {
                    return "error: write_file() missing required argument: 'path'"
                }
                return try WorkspaceSandbox.writeFile(path, content: stringArg(args["content"]) ?? "")
            case "run_command":
                return "error: run_command must go through the approval flow"
            case "get_time":
                return getTime()
            case "list_dir":
                return try listDir(stringArg(args["path"]) ?? ".")
            case "read_file":
                guard let path = stringArg(args["path"]) else {
                    return "error: TypeError: read_file() missing required argument: 'path'"
                }
                return try readFile(path)
            default:
                return "error: unknown tool '\(call.function.name)'"
            }
        } catch {
            return "error: \(type(of: error)): \(error.localizedDescription)"
        }
    }

    // MARK: - Implementations

    static func getTime() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func listDir(_ rawPath: String) throws -> String {
        let url = resolve(rawPath)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: url.path).sorted()
        var lines: [String] = []
        for name in entries.prefix(maxDirEntries) {
            var isDir: ObjCBool = false
            let full = url.appendingPathComponent(name).path
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            lines.append(isDir.boolValue ? name + "/" : name)
        }
        if entries.count > maxDirEntries {
            lines.append("... and \(entries.count - maxDirEntries) more")
        }
        return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
    }

    static func readFile(_ rawPath: String) throws -> String {
        let url = resolve(rawPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // UTF-8 is at most 4 bytes per character: this is enough for maxFileChars + 1.
        let data = try handle.read(upToCount: (maxFileChars + 1) * 4) ?? Data()
        let text = String(decoding: data, as: UTF8.self)  // invalid bytes -> U+FFFD
        if text.count > maxFileChars {
            return String(text.prefix(maxFileChars))
                + "\n... (truncated at \(maxFileChars) chars)"
        }
        return text
    }

    // MARK: - Helpers

    /// `~` expansion; relative paths are resolved against the workspace
    /// ~/LocalAI-Workspace (the same folder write_file / run_command use).
    private static func resolve(_ rawPath: String) -> URL {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "." }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            let base = (try? WorkspaceSandbox.ensureRoot().path) ?? WorkspaceSandbox.root.path
            path = (base as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func stringArg(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s
        case .null: return nil
        default: return render(value)
        }
    }

    private static func render(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(render).joined(separator: ", ") + "]"
        case .object(let o):
            return "{"
                + o.sorted { $0.key < $1.key }.map { "\($0.key): \(render($0.value))" }
                    .joined(separator: ", ") + "}"
        }
    }
}
