import Foundation

/// Runs a `run_shell_script` action the way Shortcuts does: the script is passed to the shell
/// with `-c`, input goes in as `$1`, `$2`, … ("as arguments", one per list item) or on stdin
/// ("to stdin"), and the result is stdout with trailing newlines trimmed.
enum ShellRunner {
    static let timeout: TimeInterval = 30

    static func run(shell: String, script: String, input: [String], passInput: String) async throws -> String {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(box, shell: shell, script: script, input: input, passInput: passInput))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func runBlocking(_ box: ProcessBox, shell: String, script: String, input: [String], passInput: String) throws -> String {
        let process = box.process
        process.executableURL = URL(fileURLWithPath: shell)
        // Apps launched from Finder start in /, so relative paths in commands would point at the disk root.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let viaStdin = passInput.lowercased().contains("stdin")
        // With `-c`, the word after the script becomes $0 and the rest $1, $2, …
        process.arguments = viaStdin ? ["-c", script] : ["-c", script, "cli-tools"] + input

        try box.launch()

        if viaStdin {
            stdin.fileHandleForWriting.write(Data(input.joined(separator: "\n").utf8))
        }
        try? stdin.fileHandleForWriting.close()

        let timedOut = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if box.terminate() { timedOut.set() }
        }

        // Drain stderr on another thread so a chatty script can't fill the pipe and deadlock.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        if timedOut.isSet { throw PipelineError.shellTimedOut }
        if box.wasCancelled { throw CancellationError() }

        guard process.terminationStatus == 0 else {
            throw PipelineError.shellFailed(
                status: process.terminationStatus,
                stderr: String(decoding: errBox.data, as: UTF8.self)
            )
        }
        return String(decoding: outData, as: UTF8.self).trimmingTrailingNewlines()
    }
}

/// Shares one Process between the worker thread, the timeout and the cancellation handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var launched = false
    private(set) var wasCancelled = false

    func launch() throws {
        try lock.withLock {
            if wasCancelled { throw CancellationError() }
            try process.run()
            launched = true
        }
    }

    /// Stops the process if it is still running. Returns whether it did.
    @discardableResult
    func terminate() -> Bool {
        lock.withLock {
            wasCancelled = true
            guard launched, process.isRunning else { return false }
            process.terminate()
            return true
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var s = Substring(self)
        while let last = s.last, last.isNewline { s.removeLast() }
        return String(s)
    }
}
