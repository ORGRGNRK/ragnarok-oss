import AppKit
import Foundation

public struct AgentStep: Identifiable, Equatable {
    public let id = UUID()
    public var step: String
    public var status: String // "pending", "in_progress", "completed", "failed"

    public var isCompleted: Bool { status == "completed" }
    public var isInProgress: Bool { status == "in_progress" }

    public init(step: String, status: String = "pending") {
        self.step = step
        self.status = status
    }
}

public struct AgentAction: Identifiable, Equatable {
    public let id = UUID()
    public var round: Int
    public var tool: String
    public var cmd: String
    public var exitCode: Int
    public var output: String
    public var timestamp: Date = Date()

    public init(round: Int, tool: String, cmd: String, exitCode: Int, output: String) {
        self.round = round
        self.tool = tool
        self.cmd = cmd
        self.exitCode = exitCode
        self.output = output
    }
}

public struct AgentRun: Identifiable, Equatable {
    public var id: String
    public var task: String
    public var status: String // "starting", "planning", "executing", "verifying", "completed"
    public var verdict: String // "in_progress", "proved", "needs_you", "failed"
    public var plan: [AgentStep]
    public var actions: [AgentAction]
    public var rounds: Int
    public var stage: String = ""
    public var evidence: String = ""
    public var bestCheckpoint: String = ""
    public var checkSummary: String = ""
    public var reason: String = ""
    public var sourceHash: String = ""
    public var baselineChecks: String = ""
    public var bestChecks: String = ""
    public var changes: [String] = []
    public var providerModel: String = ""
    public var controllerDecision: String = ""
    public var gateSummary: String = ""
    public var attemptsUsed: Int = 0
    public var created: Date = Date()

    public init(
        id: String = "agent-\(UUID().uuidString.prefix(8).lowercased())",
        task: String,
        status: String = "starting",
        verdict: String = "in_progress",
        plan: [AgentStep] = [],
        actions: [AgentAction] = [],
        rounds: Int = 1
    ) {
        self.id = id
        self.task = task
        self.status = status
        self.verdict = verdict
        self.plan = plan
        self.actions = actions
        self.rounds = rounds
    }

    public static func parse(from rawOutput: String, task: String) -> AgentRun {
        // Structured state comes from the controller, never from decorative success text.
        for line in rawOutput.components(separatedBy: "\n").reversed() where line.hasPrefix("PIPELINE_EVENT ") {
            guard let data = String(line.dropFirst(15)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "agent_state",
                  let state = event["state"] as? [String: Any] else { continue }
            let plan = (state["plan"] as? [[String: Any]] ?? []).map {
                AgentStep(step: $0["step"] as? String ?? "", status: $0["status"] as? String ?? "pending")
            }
            let actions = (state["actions"] as? [[String: Any]] ?? []).map {
                AgentAction(round: $0["round"] as? Int ?? 0, tool: $0["tool"] as? String ?? "",
                    cmd: $0["cmd"] as? String ?? "", exitCode: $0["exit"] as? Int ?? -1,
                    output: $0["out"] as? String ?? "")
            }
            return AgentRun(id: state["id"] as? String ?? "", task: task,
                status: state["status"] as? String ?? "unverified",
                verdict: state["verdict"] as? String ?? "unverified", plan: plan,
                actions: actions, rounds: state["rounds"] as? Int ?? 0)
        }
        var run = AgentRun(task: task)
        var checks: [String: String] = [:]
        for line in rawOutput.components(separatedBy: "\n") where line.hasPrefix("PIPELINE_EVENT ") {
            guard let data = String(line.dropFirst(15)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = event["type"] as? String else { continue }
            run.stage = event["stage"] as? String ?? run.stage
            run.rounds = event["round"] as? Int ?? run.rounds
            if let decision = event["decision"] as? [String: Any] {
                run.setDecision(decision)
            }
            if kind == "check_result", let result = event["result"] as? [String: Any] {
                let name = result["id"] as? String ?? "check"
                let status = result["status"] as? String ?? "unverified"
                checks[name] = status
                run.actions.append(AgentAction(round: run.rounds, tool: "\(run.stage) check: \(name)",
                    cmd: (result["argv"] as? [String] ?? []).joined(separator: " "),
                    exitCode: result["exit"] as? Int ?? -1,
                    output: status + "\n" + (result["stdout"] as? String ?? "") + (result["stderr"] as? String ?? "")))
                run.status = "validating"
            } else if kind == "checkpoint" {
                run.bestCheckpoint = event["best"] as? String ?? ""
                run.sourceHash = event["best_hash"] as? String ?? ""
                if let bestPassed = event["best_passed"] as? [String] {
                    run.bestChecks = bestPassed.isEmpty ? "none" : bestPassed.joined(separator: ", ")
                }
                let passed = (event["passed"] as? [String] ?? []).joined(separator: ", ")
                let summary = passed.isEmpty ? "none" : passed
                if run.stage == "baseline" { run.baselineChecks = summary }
                if event["checkpoint"] as? String == run.bestCheckpoint {
                    run.bestChecks = summary
                    run.sourceHash = event["source_hash"] as? String ?? run.sourceHash
                }
            } else if kind == "patch_proposed" {
                run.changes = event["files"] as? [String] ?? []
            } else if kind == "model_request" {
                run.status = "requesting \(event["provider"] as? String ?? "model")"
                run.providerModel = "\(event["provider"] as? String ?? "") / \(event["model"] as? String ?? "")"
            } else if kind == "finished", let result = event["result"] as? [String: Any] {
                run.status = result["status"] as? String ?? "unverified"
                run.verdict = run.status
                run.reason = result["reason"] as? String ?? ""
                run.evidence = result["evidence"] as? String ?? ""
                run.attemptsUsed = result["attempts_used"] as? Int ?? 0
                if let decision = result["decision"] as? [String: Any] { run.setDecision(decision) }
            }
        }
        run.checkSummary = checks.keys.sorted().map { "\($0): \(checks[$0]!)" }.joined(separator: " · ")

        return run
    }

    private mutating func setDecision(_ decision: [String: Any]) {
        controllerDecision = (decision["outcome"] as? String ?? "unverified") + " · " + (decision["code"] as? String ?? "")
        let gates = decision["gates"] as? [String: Any] ?? [:]
        gateSummary = ["proposal", "acceptance", "non_regression"].map { name in
            let value = gates[name] as? Bool
            return name.replacingOccurrences(of: "_", with: " ") + ": " + (value.map { $0 ? "pass" : "fail" } ?? "not checked")
        }.joined(separator: " · ")
    }
}

public struct MultimodalAttachment: Identifiable, Equatable {
    public let id = UUID()
    public var url: URL
    public var name: String
    public var size: Int64
    public var thumbnail: NSImage?

    public init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let attr = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        self.size = (attr[.size] as? Int64) ?? 0
        if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
            self.thumbnail = img
        }
    }
}
