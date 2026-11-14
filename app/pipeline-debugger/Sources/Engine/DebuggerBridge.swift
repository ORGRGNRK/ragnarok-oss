import Foundation

public final class DebuggerBridge {
    public static let shared = DebuggerBridge()

    private let pythonPath: String
    private let scriptPath: String

    public init() {
        self.pythonPath = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/python3"
        let home = NSHomeDirectory()
        let candidate = "\(home)/Developer/ragnarok/app/heimdall/bin/heimdall-debugger.py"
        if let bundled = Bundle.main.url(forResource: "heimdall-debugger", withExtension: "py") {
            self.scriptPath = bundled.path
        } else if FileManager.default.fileExists(atPath: candidate) {
            self.scriptPath = candidate
        } else {
            self.scriptPath = "\(home)/.local/bin/heimdall-debug"
        }
    }

    private var commandEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", env["PATH"] ?? "/usr/bin:/bin"]
        env["PATH"] = paths.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        return env
    }

    public func scrub(_ input: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "scrub"]
        let incoming = Pipe(), outgoing = Pipe()
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = Pipe()
        do {
            try process.run()
            incoming.fileHandleForWriting.write(Data(input.utf8))
            try? incoming.fileHandleForWriting.close()
            let data = outgoing.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "[Scrubber unavailable]" }
            return String(data: data, encoding: .utf8) ?? "[Scrubber unavailable]"
        } catch { return "[Scrubber unavailable]" }
    }

    public struct ModelDiscovery {
        public var models: [String]
        public var endpoint: String
        public var error: String
    }

    public func discoverLocalModels(endpoint: String = "") -> ModelDiscovery {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "models", "--provider", "ollama", "--no-color"] + (endpoint.isEmpty ? [] : ["--ollama-url", endpoint])
        process.environment = commandEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ModelDiscovery(models: [], endpoint: endpoint, error: "Model discovery returned an invalid response")
            }
            return ModelDiscovery(models: result["models"] as? [String] ?? [],
                endpoint: result["endpoint"] as? String ?? endpoint,
                error: result["error"] as? String ?? (process.terminationStatus == 0 ? "" : "Model discovery failed"))
        } catch {
            return ModelDiscovery(models: [], endpoint: endpoint, error: scrub(error.localizedDescription))
        }
    }

    public func localModels(endpoint: String = "") -> [String] {
        discoverLocalModels(endpoint: endpoint).models
    }

    public func fetchRecentCommands(limit: Int = 50) -> [ShellCommand] {
        let home = NSHomeDirectory()
        let path = "\(home)/.ragnarok/heimdall-shell.jsonl"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        var commands: [ShellCommand] = []
        let lines = scrub(content).components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let cmd = ShellCommand.fromJSONLine(trimmed) {
                // Shell mistakes can be standalone credentials with no key prefix.
                let word = cmd.cmd
                if word.count >= 10 && !word.contains(where: { $0.isWhitespace }) &&
                    word.contains(where: { $0.isUppercase }) && word.contains(where: { $0.isLowercase }) &&
                    word.contains(where: { $0.isNumber }) && word.contains(where: { "!@#$%^&*".contains($0) }) {
                    continue
                }
                commands.append(cmd)
                if commands.count >= limit { break }
            }
        }
        return commands
    }

    public func fetchRecentOutput(maxLines: Int = 100) -> String {
        let home = NSHomeDirectory()
        let path = "\(home)/.ragnarok/heimdall-shell-output.log"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        let lines = scrub(content).components(separatedBy: "\n")
        let slice = lines.suffix(maxLines)
        return slice.joined(separator: "\n")
    }

    public func runPipeline(
        command: String,
        cwd: String = NSHomeDirectory(),
        ollamaURL: String = "",
        images: [URL] = [],
        provider: String = "",
        model: String = "",
        onOutput: @escaping (String) -> Void,
        onFinished: @escaping (Int, String) -> Void
    ) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)

        var args = [scriptPath, "run", command]
        if !provider.isEmpty {
            args.append(contentsOf: ["--provider", provider])
        }
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        for img in images {
            args.append(contentsOf: ["--image", img.path])
        }
        if !ollamaURL.isEmpty { args.append(contentsOf: ["--ollama-url", ollamaURL]) }
        p.arguments = args
        p.environment = commandEnvironment
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = commandEnvironment
        env["TERM"] = "xterm-256color"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let fileHandle = pipe.fileHandleForReading
        var fullOutput = ""
        let outputLock = NSLock()

        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputLock.lock()
            fullOutput += text
            outputLock.unlock()
            DispatchQueue.main.async { onOutput(text) }
        }

        p.terminationHandler = { proc in
            fileHandle.readabilityHandler = nil
            let remaining = fileHandle.readDataToEndOfFile()
            if let remText = String(data: remaining, encoding: .utf8), !remText.isEmpty {
                outputLock.lock()
                fullOutput += remText
                outputLock.unlock()
            }
            outputLock.lock()
            let completedOutput = fullOutput
            outputLock.unlock()
            DispatchQueue.main.async {
                onFinished(Int(proc.terminationStatus), completedOutput)
            }
        }

        do {
            try p.run()
            return p
        } catch {
            DispatchQueue.main.async {
                let err = "Failed to launch pipeline: \(error.localizedDescription)"
                onOutput(err)
                onFinished(1, err)
            }
            return nil
        }
    }

    public func debugLast(
        selectedFailure: ShellCommand? = nil,
        cwd: String = NSHomeDirectory(),
        ollamaURL: String = "",
        images: [URL] = [],
        provider: String = "",
        model: String = "",
        onOutput: @escaping (String) -> Void,
        onFinished: @escaping (String) -> Void
    ) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)

        var args = [scriptPath, "last"]
        if let failure = selectedFailure {
            args.append(contentsOf: ["--failure-command", failure.cmd, "--failure-exit", String(failure.exitCode)])
        }
        if !provider.isEmpty {
            args.append(contentsOf: ["--provider", provider])
        }
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        for img in images {
            args.append(contentsOf: ["--image", img.path])
        }
        if !ollamaURL.isEmpty { args.append(contentsOf: ["--ollama-url", ollamaURL]) }
        p.arguments = args
        p.environment = commandEnvironment
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let fileHandle = pipe.fileHandleForReading
        var fullOutput = ""
        let outputLock = NSLock()

        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputLock.lock()
            fullOutput += text
            outputLock.unlock()
            DispatchQueue.main.async { onOutput(text) }
        }

        p.terminationHandler = { _ in
            fileHandle.readabilityHandler = nil
            let remaining = fileHandle.readDataToEndOfFile()
            if let remText = String(data: remaining, encoding: .utf8), !remText.isEmpty {
                outputLock.lock()
                fullOutput += remText
                outputLock.unlock()
            }
            outputLock.lock()
            let completedOutput = fullOutput
            outputLock.unlock()
            DispatchQueue.main.async { onFinished(completedOutput) }
        }

        do {
            try p.run()
            return p
        } catch {
            DispatchQueue.main.async {
                let err = "Failed to launch debugger: \(error.localizedDescription)"
                onOutput(err)
                onFinished(err)
            }
            return nil
        }
    }

    public func runAgent(
        task: String,
        cwd: String = NSHomeDirectory(),
        ollamaURL: String = "",
        images: [URL] = [],
        provider: String = "",
        model: String = "",
        rounds: Int = 3,
        acceptance: String = "",
        cloudProvider: String = "",
        cloudModel: String = "",
        onOutput: @escaping (String) -> Void,
        onFinished: @escaping (Int, String) -> Void
    ) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)

        var args = [scriptPath, "repair", task, "--rounds", String(rounds), "--cwd", cwd, "--acceptance", acceptance]
        if !cloudProvider.isEmpty {
            args.append(contentsOf: ["--cloud-provider", cloudProvider, "--cloud-model", cloudModel])
        }
        if !provider.isEmpty {
            args.append(contentsOf: ["--provider", provider])
        }
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        for img in images {
            args.append(contentsOf: ["--image", img.path])
        }
        if !ollamaURL.isEmpty { args.append(contentsOf: ["--ollama-url", ollamaURL]) }
        p.arguments = args
        p.environment = commandEnvironment
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = commandEnvironment
        env["TERM"] = "xterm-256color"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let fileHandle = pipe.fileHandleForReading
        var fullOutput = ""
        let outputLock = NSLock()

        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputLock.lock()
            fullOutput += text
            outputLock.unlock()
            DispatchQueue.main.async { onOutput(text) }
        }

        p.terminationHandler = { proc in
            fileHandle.readabilityHandler = nil
            let remaining = fileHandle.readDataToEndOfFile()
            if let remText = String(data: remaining, encoding: .utf8), !remText.isEmpty {
                outputLock.lock()
                fullOutput += remText
                outputLock.unlock()
            }
            outputLock.lock()
            let completedOutput = fullOutput
            outputLock.unlock()
            DispatchQueue.main.async {
                onFinished(Int(proc.terminationStatus), completedOutput)
            }
        }

        do {
            try p.run()
            return p
        } catch {
            DispatchQueue.main.async {
                let err = "Failed to launch autonomous agent: \(error.localizedDescription)"
                onOutput(err)
                onFinished(1, err)
            }
            return nil
        }
    }
}
