import CryptoKit
import Foundation

// Receipts + claim check, ported from the ALEXUS conveyor rule:
// "a model's claim never counts as proof; code checks it."
// Every executed tool call leaves a receipt; an assistant reply that says it
// ran / wrote / listed / read something is only supported when a receipt from
// the same user turn shows it.

/// One executed tool call. Written by the app, never by the model.
public struct ToolReceipt: Codable, Equatable, Identifiable {
    public var id: String
    /// The user message id that started this turn.
    public var turn: String
    public var tool: String
    /// Arguments as strings. write_file content is replaced by its length + hash.
    public var args: [String: String]
    public var ok: Bool
    /// run_command only.
    public var exitCode: Int?
    public var outputSHA256: String
    public var outputPreview: String
    public var outputChars: Int
    public var timestamp: Date

    public static let previewLimit = 400

    public init(
        id: String = UUID().uuidString, turn: String, tool: String, args: [String: String],
        output: String, timestamp: Date = Date()
    ) {
        self.id = id
        self.turn = turn
        self.tool = tool
        var safeArgs = args
        if let content = safeArgs["content"], tool == "write_file" {
            safeArgs["content"] = "<\(content.count) chars, sha256 \(Self.sha256(content).prefix(12))>"
        }
        self.args = safeArgs
        let exit = Self.parseExitCode(output)
        self.exitCode = tool == "run_command" ? exit : nil
        let failed = output.hasPrefix("error:") || (tool == "run_command" && (exit ?? -1) != 0)
        self.ok = !failed
        self.outputSHA256 = Self.sha256(output)
        self.outputPreview = String(output.prefix(Self.previewLimit))
        self.outputChars = output.count
        self.timestamp = timestamp
    }

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `exit code: N` line written by CommandRunner.Result.report.
    static func parseExitCode(_ output: String) -> Int? {
        guard let r = output.range(of: #"exit code: (-?\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = output[r].dropFirst("exit code: ".count)
        return Int(digits)
    }

    /// One-line label for the transcript, e.g. `ok · exit 0 · sha 1a2b3c4d`.
    public var badge: String {
        var parts = [ok ? "ok" : "fail"]
        if let exitCode { parts.append("exit \(exitCode)") }
        parts.append("sha \(outputSHA256.prefix(8))")
        return parts.joined(separator: " · ")
    }
}

/// Append-only JSONL log (~/Library/Application Support/LocalAI/receipts.jsonl).
public enum ReceiptLog {
    public static func append(_ receipt: ToolReceipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(receipt)
        line.append(0x0A)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// A sentence in which the assistant says it did something.
public struct ActionClaim: Equatable {
    public enum Kind: String, CaseIterable {
        case run, write, list, read

        public var tools: [String] {
            switch self {
            case .run: return ["run_command"]
            case .write: return ["write_file"]
            case .list: return ["list_dir"]
            case .read: return ["read_file"]
            }
        }

        public static func forTool(_ name: String) -> Kind? {
            allCases.first { $0.tools.contains(name) }
        }
    }

    public var kind: Kind
    /// File names mentioned in the sentence (only checked for write / read).
    public var files: [String]
    /// "successfully ..." needs an ok receipt.
    public var requiresSuccess: Bool
    public var sentence: String

    public var summary: String {
        let s = sentence.count > 160 ? String(sentence.prefix(160)) + "…" : sentence
        return "\(kind.rawValue): \"\(s)\""
    }
}

public enum ClaimChecker {
    public static let nudge =
        "No tool ran this turn; nothing was written or executed. Call the tools now with <tool_call>{...}</tool_call>. Do not report results you have not observed."

    public static let toolReminder =
        "[Reminder: to act, call a tool with <tool_call>{\"name\": ..., \"arguments\": {...}}</tool_call> and wait for its result. Never say you wrote, ran, listed, or read anything unless a tool result in this chat shows it. Never invent file contents or command output.]"

    // MARK: Claim extraction

    private static let verbKinds: [String: ActionClaim.Kind] = [
        "ran": .run, "run": .run, "executed": .run, "printed": .run,
        "created": .write, "wrote": .write, "written": .write, "saved": .write,
        "listed": .list,
        "read": .read,
    ]

    private static let verbAlternation = "ran|run|executed|printed|created|wrote|written|saved|listed|read"
    private static let pastAlternation = "ran|executed|printed|created|wrote|written|saved|listed|read"

    /// "I ran", "I've just executed", "we have created", "I then listed".
    private static let firstPerson = try! NSRegularExpression(
        pattern: #"\b(?:i|i've|i have|i had|we|we've|we have)\s+(?:(?:just|then|also|first|now|already|successfully|have|had)\s+){0,3}("# + pastAlternation + #")\b"#,
        options: [.caseInsensitive])
    /// "I've run" (bare "we run" is present tense, i.e. an explanation).
    private static let perfectRun = try! NSRegularExpression(
        pattern: #"\b(?:i've|i have|we've|we have)\s+(?:just\s+|already\s+|now\s+)?(run)\b"#,
        options: [.caseInsensitive])
    /// "successfully created", "successfully ran".
    private static let successfully = try! NSRegularExpression(
        pattern: #"\bsuccessfully\s+(?:been\s+)?("# + verbAlternation + #")\b"#,
        options: [.caseInsensitive])
    /// "files.txt was created", "the script has been executed".
    private static let passive = try! NSRegularExpression(
        pattern: #"\b(?:was|were|has been|have been|is now|are now)\s+(?:successfully\s+)?("# + verbAlternation + #")\b"#,
        options: [.caseInsensitive])
    /// "using the list_dir function", "with the `write_file` tool", "called run_command".
    private static let usingTool = try! NSRegularExpression(
        pattern: #"\b(?:using|used|use of|called|calling|with|via)\s+(?:the\s+)?`?(read_file|list_dir|write_file|run_command)`?(?:\s+(?:function|tool))?"#,
        options: [.caseInsensitive])
    private static let fileName = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_][A-Za-z0-9_\-./]*\.[A-Za-z][A-Za-z0-9]{0,5}\b"#)
    /// Intent / instructions, not reports of something done.
    private static let notAReport = try! NSRegularExpression(
        pattern: #"\b(?:will|i'll|we'll|going to|let me|let's|you can|you could|you should|if you|need to|i can|would|should)\b"#,
        options: [.caseInsensitive])

    /// Action claims in `text` (fenced code blocks and questions are ignored).
    public static func claims(in text: String) -> [ActionClaim] {
        var out: [ActionClaim] = []
        for sentence in sentences(stripCode(text).replacingOccurrences(of: "\u{2019}", with: "'")) {
            if sentence.hasSuffix("?") { continue }
            let ns = sentence as NSString
            let full = NSRange(location: 0, length: ns.length)
            if notAReport.firstMatch(in: sentence, range: full) != nil { continue }
            let files = fileName.matches(in: sentence, range: full)
                .map { ns.substring(with: $0.range) }
                .filter { !$0.lowercased().hasPrefix("e.g") && !$0.lowercased().hasPrefix("i.e") }
            let success = successfully.firstMatch(in: sentence, range: full) != nil
            var kinds: [ActionClaim.Kind] = []
            for regex in [firstPerson, perfectRun, successfully, passive] {
                for m in regex.matches(in: sentence, range: full) {
                    let verb = ns.substring(with: m.range(at: 1)).lowercased()
                    if let k = verbKinds[verb] { kinds.append(k) }
                }
            }
            for m in usingTool.matches(in: sentence, range: full) {
                if let k = ActionClaim.Kind.forTool(ns.substring(with: m.range(at: 1)).lowercased()) {
                    kinds.append(k)
                }
            }
            var seen = Set<ActionClaim.Kind>()
            for k in kinds where seen.insert(k).inserted {
                out.append(
                    ActionClaim(
                        kind: k,
                        files: (k == .write || k == .read) ? files : [],
                        requiresSuccess: success,
                        sentence: sentence))
            }
        }
        return out
    }

    // MARK: Support check

    /// Claims with no matching receipt in `receipts` (pass only this turn's receipts).
    public static func unsupported(in text: String, receipts: [ToolReceipt]) -> [ActionClaim] {
        claims(in: text).filter { !isSupported($0, by: receipts) }
    }

    public static func isSupported(_ claim: ActionClaim, by receipts: [ToolReceipt]) -> Bool {
        let usable = receipts.filter { !claim.requiresSuccess || $0.ok }
        switch claim.kind {
        case .run:
            return usable.contains { $0.tool == "run_command" }
        case .list:
            return usable.contains { $0.tool == "list_dir" }
        case .read:
            let reads = usable.filter { $0.tool == "read_file" }
            if claim.files.isEmpty { return !reads.isEmpty }
            return reads.contains { r in claim.files.contains { sameFile($0, r.args["path"]) } }
        case .write:
            let writes = usable.filter { $0.tool == "write_file" }
            let runs = usable.filter { $0.tool == "run_command" }
            if claim.files.isEmpty { return !writes.isEmpty || !runs.isEmpty }
            return claim.files.contains { file in
                // write_file of that path, or a script / listing that observably names it.
                writes.contains { sameFile(file, $0.args["path"]) }
                    || (runs + usable.filter { $0.tool == "list_dir" }).contains {
                        mentions($0, file)
                    }
            }
        }
    }

    /// Did the user ask for something to be done (vs. a plain question)?
    public static func userAskedForAction(_ text: String) -> Bool {
        let pattern =
            #"\b(?:create|make|write|save|run|execute|list|read|open|print|generate|build|delete|rename|edit|fix|modify|update|show me (?:the )?(?:files?|output|contents?))\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Helpers

    static func sameFile(_ claimed: String, _ path: String?) -> Bool {
        guard let path else { return false }
        let a = (claimed as NSString).lastPathComponent.lowercased()
        let b = (path as NSString).lastPathComponent.lowercased()
        return !a.isEmpty && a == b
    }

    static func mentions(_ r: ToolReceipt, _ file: String) -> Bool {
        let name = (file as NSString).lastPathComponent.lowercased()
        let hay = (r.args.values.joined(separator: " ") + "\n" + r.outputPreview).lowercased()
        return hay.contains(name)
    }

    static func stripCode(_ text: String) -> String {
        text.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: "\n", options: .regularExpression)
    }

    /// Split at newlines and at . ! ? followed by whitespace (so "files.txt" stays whole).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c.isNewline {
                out.append(current)
                current = ""
                continue
            }
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next.isWhitespace {
                    out.append(current)
                    current = ""
                }
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
