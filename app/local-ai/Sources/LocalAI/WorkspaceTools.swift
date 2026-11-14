import Foundation

/// The only folder write_file / run_command may touch: ~/LocalAI-Workspace.
enum WorkspaceSandbox {
    static let maxWriteBytes = 1_000_000

    enum SandboxError: LocalizedError {
        case absolutePath(String)
        case escapes(String)
        case emptyPath
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .absolutePath(let p):
                return "absolute paths are not allowed ('\(p)'); use a path relative to ~/LocalAI-Workspace"
            case .escapes(let p): return "path '\(p)' escapes ~/LocalAI-Workspace"
            case .emptyPath: return "path is empty"
            case .tooLarge(let n): return "content too large (\(n) bytes; limit \(maxWriteBytes))"
            }
        }
    }

    /// Overridable for tests.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LocalAI-Workspace", isDirectory: true)
    }

    @discardableResult
    static func ensureRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolve a workspace-relative path. Rejects absolute / `~` paths, `..` escapes,
    /// and symlinks that point outside the workspace.
    static func resolve(_ raw: String, allowRoot: Bool = false) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models often repeat the workspace prefix ("~/LocalAI-Workspace/x.py" or the
        // absolute path); treat that as relative to the workspace.
        let rootPath = root.standardizedFileURL.path
        for prefix in ["~/LocalAI-Workspace", rootPath, "./"] {
            if path == prefix { path = "."; break }
            let p = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path.hasPrefix(p) { path = String(path.dropFirst(p.count)); break }
        }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "." {
            if allowRoot { return try ensureRoot() }
            throw SandboxError.emptyPath
        }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("$") {
            throw SandboxError.absolutePath(path)
        }
        let rootURL = try ensureRoot()
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        // Resolve symlinks on the deepest existing ancestor, then re-append the rest.
        var existing = candidate
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in tail { resolved.appendPathComponent(part) }
        let r = rootURL.path
        guard resolved.path == r || resolved.path.hasPrefix(r + "/") else {
            throw SandboxError.escapes(path)
        }
        if resolved.path == r && !allowRoot { throw SandboxError.escapes(path) }
        return resolved
    }

    static func writeFile(_ path: String, content: String) throws -> String {
        let data = Data(content.utf8)
        if data.count > maxWriteBytes { throw SandboxError.tooLarge(data.count) }
        let url = try resolve(path)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        MacReceipt.log(action: existed ? "Updated" : "Created", command: "write_file \(url.path) (contents not logged)", ref: url.path)
        return "wrote \(data.count) bytes to ~/LocalAI-Workspace/\(relative(url))"
    }

    static func relative(_ url: URL) -> String {
        let r = (try? ensureRoot().path) ?? root.path
        return url.path == r ? "." : String(url.path.dropFirst(r.count + 1))
    }
}

/// Mac receipts (ragnarok connector/ygg-business/hooks/mac-receipts), the same log Claude Code, Gemini CLI,
/// Grok CLI and Antigravity write to. File writes are sent here; commands are receipted by the zsh hook, which
/// sees AI_AGENT=LocalAI (set in CommandRunner). Fail-open: never blocks, never throws, nothing if node is missing.
enum MacReceipt {
    static func log(action: String, command: String, ref: String) {
        let home = NSHomeDirectory()
        let node = home + "/.local/node/bin/node"
        let js = home + "/Developer/ygg-mcp-business/hooks/mac-receipts/receipt.mjs"
        guard FileManager.default.isExecutableFile(atPath: node), FileManager.default.fileExists(atPath: js) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [js, "log", "--actor", "LocalAI", "--cmd", command, "--action", action, "--ref", ref]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Runs a shell command with /bin/zsh -lc inside the workspace, with a timeout.
enum CommandRunner {
    static let maxOutputChars = 12_000

    struct Result {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
        var seconds: Double

        var report: String {
            var s = "exit code: \(exitCode)\(timedOut ? " (killed: timed out)" : "")"
            s += String(format: " · %.1fs", seconds)
            s += "\n--- stdout ---\n" + (stdout.isEmpty ? "(empty)" : stdout)
            s += "\n--- stderr ---\n" + (stderr.isEmpty ? "(empty)" : stderr)
            return s
        }
    }

    static func truncate(_ s: String) -> String {
        guard s.count > maxOutputChars else { return s }
        return String(s.prefix(maxOutputChars))
            + "\n... (truncated; \(s.count - maxOutputChars) more chars)"
    }

    static func run(_ command: String, cwd: URL, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(command, cwd: cwd, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ command: String, cwd: URL, timeout: TimeInterval) -> Result {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["AI_AGENT"] = "LocalAI"   // the Mac receipts zsh hook logs this command as LocalAI
        process.environment = env
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain pipes concurrently so a chatty command can't deadlock on a full pipe.
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ d: Data) {
                lock.lock()
                if data.count < 4 * 1024 * 1024 { data.append(d) }
                lock.unlock()
            }
        }
        let outSink = Sink()
        let errSink = Sink()
        out.fileHandleForReading.readabilityHandler = { h in outSink.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errSink.append(h.availableData) }

        do {
            try process.run()
        } catch {
            return Result(
                stdout: "", stderr: "failed to start: \(error.localizedDescription)",
                exitCode: -1, timedOut: false, seconds: 0)
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()  // SIGTERM
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        if timedOut {
            // Also stop anything the shell left running in the background.
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-KILL", "-P", String(process.processIdentifier)]
            try? pkill.run()
        }
        // Let the readability handlers drain the last bytes. Don't block on EOF:
        // a background grandchild could keep the pipe open forever.
        Thread.sleep(forTimeInterval: 0.15)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        return Result(
            stdout: truncate(String(decoding: outSink.data, as: UTF8.self)),
            stderr: truncate(String(decoding: errSink.data, as: UTF8.self)),
            exitCode: process.isRunning ? -9 : process.terminationStatus,
            timedOut: timedOut,
            seconds: Date().timeIntervalSince(start))
    }
}
