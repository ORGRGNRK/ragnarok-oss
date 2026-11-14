import Foundation

// MARK: - Check executor (structured JSON version of conveyor-check)

struct CheckResult: Codable, Hashable {
    var stepId: UUID
    var passed: Bool
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var expectMatched: Bool?
}

enum CheckError: LocalizedError {
    case timeout(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let cmd): return "Check timed out: \(cmd)"
        case .launchFailed(let msg): return "Failed to run check: \(msg)"
        }
    }
}

enum HarnessCheckExecutor {

    static let timeoutSeconds: TimeInterval = 120

    /// Run a single verify command in the task's folder (or workspace as fallback)
    /// Returns stdout truncated to 12k like run_command does
    static func run(step: ChecklistStep, taskFolder: URL? = nil) -> CheckResult {
        let cwd = taskFolder ?? WorkspaceSandbox.root
        let command = step.verify

        // HUMAN steps never auto-pass
        if step.isHuman {
            return CheckResult(
                stepId: step.id,
                passed: false,
                exitCode: -1,
                stdout: "",
                stderr: "HUMAN step — needs human approval",
                expectMatched: nil
            )
        }

        // Do-nothing guard — belt rejects these before they run, but keep safety
        if step.isDoNothing || step.isEmptyCheck {
            return CheckResult(
                stepId: step.id,
                passed: false,
                exitCode: -1,
                stdout: "",
                stderr: "Invalid check: empty or do-nothing (\(command))",
                expectMatched: nil
            )
        }

        let (code, out, err) = runShell(command, cwd: cwd)

        var passed = (code == 0)
        var expectMatched: Bool? = nil

        if let expect = step.expect, !expect.isEmpty {
            let combined = out + "\n" + err
            do {
                let regex = try NSRegularExpression(pattern: expect, options: [.anchorsMatchLines])
                let range = NSRange(combined.startIndex..., in: combined)
                let matched = regex.firstMatch(in: combined, range: range) != nil
                expectMatched = matched
                passed = passed && matched
            } catch {
                // bad regex = fail the step, surface error
                return CheckResult(
                    stepId: step.id,
                    passed: false,
                    exitCode: code,
                    stdout: out,
                    stderr: err + "\n[expect regex invalid: \(error.localizedDescription)]",
                    expectMatched: false
                )
            }
        }

        return CheckResult(
            stepId: step.id,
            passed: passed,
            exitCode: code,
            stdout: out.truncated(to: 12000),
            stderr: err.truncated(to: 12000),
            expectMatched: expectMatched
        )
    }

    static func runAll(checklist: [ChecklistStep], taskFolder: URL? = nil) -> [CheckResult] {
        checklist.map { run(step: $0, taskFolder: taskFolder) }
    }

    // MARK: - Shell

    private static func runShell(_ command: String, cwd: URL) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

        // Env similar to conveyor: expose task outputs
        var env = ProcessInfo.processInfo.environment
        env["CONVEYOR_OUTPUTS"] = cwd.appendingPathComponent("outputs").path
        env["LOCALAI_WORKSPACE"] = WorkspaceSandbox.root.path
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (-1, "", "launch failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { process.interrupt() }
            return (124, "", "timeout after \(Int(timeoutSeconds))s: \(command)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        return (process.terminationStatus, out, err)
    }
}

private extension String {
    func truncated(to max: Int) -> String {
        guard count > max else { return self }
        return String(prefix(max)) + "\n... (truncated at \(max) chars)"
    }
}

// MARK: - Task folder (per-task container folder, like conveyor's task folder)

enum TaskFolder {
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalAI")
            .appendingPathComponent("Tasks", isDirectory: true)
    }

    static func url(for taskId: UUID) -> URL {
        base.appendingPathComponent(taskId.uuidString, isDirectory: true)
    }

    static func outputs(for taskId: UUID) -> URL {
        url(for: taskId).appendingPathComponent("outputs", isDirectory: true)
    }

    static func ensure(for taskId: UUID) throws -> URL {
        let folder = url(for: taskId)
        let outputs = folder.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        return folder
    }
}
