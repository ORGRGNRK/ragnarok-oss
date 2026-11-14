import Foundation

// MARK: - Intent router (leg 0 — before planner writes checklist)

struct RouterResult: Codable, Hashable {
    var intent: TaskIntent
    var reason: String
    var rawOutput: String
}

enum HarnessRouter {

    /// Runs the router seat on the task title (fast/cheap model — qwen, ollama local)
    /// Returns intent: script | code | message | unknown
    static func route(task: HarnessTask, using seat: any HarnessSeat) async throws -> RouterResult {
        let prompt = buildPrompt(task: task)
        let system = """
        You are the CONVEYOR ROUTER. Classify intent in one line.
        You MUST output exactly 2 lines:
        intent: <script|code|message|unknown>
        reason: <short 1-line why>

        Definitions (use these exactly):
        - script: task needs to RUN something — shell command, build, test, lint, process CSV, check files exist, run a binary. Tools: run_command, list_dir, read_file
        - code: task needs to CREATE or EDIT code/files — write a file, implement function, fix bug, scaffold project. Tools: write_file, read_file
        - message: task needs ONLY a chat answer — explain, summarize, answer question, no file writes, no commands. Tools: none
        - unknown: not enough info to decide

        Examples:
        "run the tests and report failures" -> intent: script
        "implement TaskStore with structured json" -> intent: code
        "what does conveyor-check do?" -> intent: message
        "build the app" -> intent: script
        "add router at 1 using intent" -> intent: code
        "summarize the task board logic" -> intent: message

        Be precise. If the title mentions a file path, code, or implementation, it's code. If it mentions running, checking, building, testing, it's script.
        """

        let raw = try await seat.generate(prompt: prompt, systemPrompt: system)

        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var intent: TaskIntent = .unknown
        var reason = ""

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("intent:") {
                let value = line.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.contains("script") { intent = .script }
                else if value.contains("code") { intent = .code }
                else if value.contains("message") { intent = .message }
                else { intent = .unknown }
            } else if lower.hasPrefix("reason:") {
                reason = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }

        if intent == .unknown && reason.isEmpty {
            let titleLower = task.title.lowercased()
            if titleLower.contains("run") || titleLower.contains("test") || titleLower.contains("build") || titleLower.contains("check") || titleLower.contains("script") || titleLower.contains("process") {
                intent = .script
                reason = "heuristic: title mentions run/build/test"
            } else if titleLower.contains("create") || titleLower.contains("write") || titleLower.contains("implement") || titleLower.contains("add") || titleLower.contains("fix") || titleLower.contains("refactor") {
                intent = .code
                reason = "heuristic: title mentions create/write/implement"
            } else if titleLower.contains("what") || titleLower.contains("why") || titleLower.contains("explain") || titleLower.contains("summarize") || titleLower.contains("how does") {
                intent = .message
                reason = "heuristic: question/explain"
            }
        }

        if reason.isEmpty {
            reason = String(raw.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return RouterResult(intent: intent, reason: reason, rawOutput: raw)
    }

    private static func buildPrompt(task: HarnessTask) -> String {
        """
        Task: \(task.title)
        Belt: \(task.beltId)
        Existing checklist: \(task.checklist.isEmpty ? "(none yet)" : "\(task.checklist.count) steps")

        Classify this task.
        """
    }
}
